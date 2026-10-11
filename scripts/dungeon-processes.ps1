# Lifecycle identity checks apply equally to the Next.js server and private edge.
function Get-DungeonTcpListeners([int]$LocalPort, [string]$LocalAddress = '') {
    $netstat = Join-Path $env:SystemRoot 'System32/netstat.exe'
    $lines = & $netstat -ano -p tcp 2>$null
    foreach ($line in $lines) {
        if ($line -match '^\s*TCP\s+(?<address>\[[^\]]+\]|[^:\s]+):(?<port>\d+)\s+\S+\s+LISTENING\s+(?<pid>\d+)\s*$' -and
            [int]$Matches.port -eq $LocalPort -and (-not $LocalAddress -or $Matches.address.Trim('[',']') -eq $LocalAddress)) {
            $address = ([string]$Matches.address).TrimStart('[').TrimEnd(']')
            [pscustomobject]@{ LocalAddress = $address; LocalPort = [int]$Matches.port; State = 'Listen'; OwningProcess = [int]$Matches.pid }
        }
    }
}

function Get-DungeonOwnedProcess([string]$StatePath) {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($state.ProcessId -notmatch '^\d+$' -or [long]$state.ProcessId -le 0) { throw 'Invalid saved process identity.' }
    $process = Get-Process -Id ([int]$state.ProcessId) -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    # A PID is accepted only when both its precise start time and full executable
    # path still match the identity saved at launch. Do not use process-name or
    # port ownership guesses when stopping user processes.
    $created = if ($state.Created -is [DateTime]) { $state.Created.ToUniversalTime().ToString('o') } else { [string]$state.Created }
    $actualCreated = $process.StartTime.ToUniversalTime().ToString('o')
    $actualPath = $process.Path
    if ($actualCreated -ne $created -or $actualPath -ne $state.ExecutablePath) {
        throw 'The saved PID now belongs to a different process. It will not be stopped.'
    }
    $process | Add-Member -NotePropertyName ProcessId -NotePropertyValue $process.Id -Force
    $process
}

function Save-DungeonOwnedProcess($Child, [string]$StatePath, [string]$CommandLine = '') {
    try {
        $identity = Get-Process -Id $Child.Id -ErrorAction Stop
        if (-not $identity) { throw 'The application process exited before it could be registered.' }
        if (-not $CommandLine) { $CommandLine = @($Child.StartInfo.FileName, $Child.StartInfo.Arguments) -join ' ' }
        @{ ProcessId = $Child.Id; Created = $identity.StartTime.ToUniversalTime().ToString('o'); CommandLine = $CommandLine; ExecutablePath = $identity.Path } |
            ConvertTo-Json | Set-Content -LiteralPath $StatePath
    } catch {
        # This is the just-created process object, never a port-based guess.
        if (-not $Child.HasExited) { $Child.Kill() }
        throw
    }
}

function Stop-DungeonOwnedProcesses([string[]]$StatePaths, [switch]$Force) {
    # Validate every identity before stopping anything.
    $processes = @($StatePaths | ForEach-Object { Get-DungeonOwnedProcess $_ } | Where-Object { $_ })
    foreach ($process in $processes) {
        if ($Force) { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop }
        else { Stop-Process -Id $process.ProcessId -ErrorAction Stop }
    }
    foreach ($path in $StatePaths) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
}

function Test-DungeonOllamaRunnerIdentity($Current, $Snapshot, [string]$RunnerPath) {
    if (-not $Current -or
        [string]::IsNullOrWhiteSpace([string]$Current.ExecutablePath) -or
        [string]::IsNullOrWhiteSpace([string]$Current.CommandLine) -or
        -not $Current.CreationDate) { return $false }
    try {
        $currentPath = [IO.Path]::GetFullPath([string]$Current.ExecutablePath)
        $samePath = $currentPath -ieq $RunnerPath
        $sameCommand = [string]$Current.CommandLine -ceq [string]$Snapshot.CommandLine
        $sameCreation = ([datetime]$Current.CreationDate).ToUniversalTime() -eq ([datetime]$Snapshot.CreationDate).ToUniversalTime()
        return ($samePath -and $sameCommand -and $sameCreation)
    } catch {
        # CIM may return a partial row while a process is exiting. An incomplete
        # row cannot authorize a stop or prove that the original process remains.
        return $false
    }
}

function Stop-DungeonOllamaRunnerProcesses([string]$OllamaPath) {
    if (-not $OllamaPath) { return 0 }
    $ollamaRoot = Split-Path -Parent $OllamaPath
    $runnerPath = [IO.Path]::GetFullPath((Join-Path $ollamaRoot 'lib/ollama/llama-server.exe'))
    $runners = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath([string]$_.ExecutablePath) -ieq $runnerPath -and
        $_.CommandLine -match '(?i)(^|\s)--model\s'
    })
    $stopping = @()
    foreach ($runner in $runners) {
        # Re-read identity just before stopping so PID reuse cannot target an
        # unrelated process. A missing or replaced PID means this snapshot's
        # runner has already exited; it is not a shutdown failure.
        $current = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$runner.ProcessId)" -ErrorAction SilentlyContinue
        if (-not (Test-DungeonOllamaRunnerIdentity $current $runner $runnerPath)) { continue }
        Stop-Process -Id ([int]$runner.ProcessId) -Force -ErrorAction Stop
        $stopping += $runner
    }
    foreach ($runner in $stopping) {
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        do {
            $current = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$runner.ProcessId)" -ErrorAction SilentlyContinue
            if (-not $current) { break }
            if (-not (Test-DungeonOllamaRunnerIdentity $current $runner $runnerPath)) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if (Test-DungeonOllamaRunnerIdentity $current $runner $runnerPath) {
            throw "Ollama model runner PID $($runner.ProcessId) is still running with the same process identity after shutdown."
        }
    }
    $stopping.Count
}

function Stop-DungeonOllamaServer([string]$BaseUrl, [string]$StatePath, [switch]$Force, [switch]$RequireListener) {
    $uri = [uri]$BaseUrl
    if ($uri.Host -notin @('127.0.0.1', 'localhost', '::1')) {
        throw 'Dungeon can only manage its local Ollama server; the configured Ollama URL is remote.'
    }

    $owned = Get-DungeonOwnedProcess $StatePath
    $pids = @()
    if ($owned) { $pids += [int]$owned.Id }
    foreach ($listener in @(Get-DungeonTcpListeners -LocalPort $uri.Port)) {
        if ([int]$listener.OwningProcess -notin $pids) { $pids += [int]$listener.OwningProcess }
    }

    if ($pids.Count -eq 0 -and $RequireListener) { throw "Ollama responds on port $($uri.Port), but its listener process could not be identified. No process was started or stopped." }

    $ollamaCommand = Get-Command ollama.exe -ErrorAction SilentlyContinue
    $ollamaPath = if ($ollamaCommand) { $ollamaCommand.Source } else { $null }
    $processes = @()
    foreach ($processId in $pids) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        if ($process.ProcessName -ne 'ollama' -or $process.Path -ne $ollamaPath) {
            throw "Port $($uri.Port) belongs to a process other than the verified Ollama executable. It was left untouched."
        }
        $processes += $process
    }

    # Ollama's API server owns llama-server model workers. Stop those workers
    # first; killing only ollama.exe can orphan them and leave VRAM allocated.
    $stoppedRunners = Stop-DungeonOllamaRunnerProcesses $ollamaPath
    foreach ($process in $processes) {
        if ($Force) { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
        else { Stop-Process -Id $process.Id -ErrorAction Stop }
    }
    foreach ($process in $processes) {
        try { Wait-Process -Id $process.Id -Timeout 2 -ErrorAction Stop } catch { }
    }
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    return ($processes.Count -gt 0 -or $stoppedRunners -gt 0)
}
