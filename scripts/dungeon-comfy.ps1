param(
    [ValidateSet('Start', 'Stop', 'Status')]
    [string]$Action = 'Status',
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtime = Join-Path $root 'runtime\flux2-klein'
$comfy = Join-Path $runtime 'ComfyUI'
$python = Join-Path $runtime 'venv312\Scripts\python.exe'
$stateDir = Join-Path $runtime 'state'
$stateFile = Join-Path $stateDir 'comfyui-owner.json'
$logDir = Join-Path $runtime 'logs'
$baseUrl = 'http://127.0.0.1:18188'

function Read-Owner {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try { return Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json }
    catch { throw "Invalid Dungeon ComfyUI ownership file: $stateFile" }
}

function Get-OwnedProcess($owner) {
    if (-not $owner) { return $null }
    $process = Get-Process -Id ([int]$owner.pid) -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    if ($process.StartTime.ToUniversalTime().ToString('o') -ne $owner.startedUtc) {
        throw "PID $($owner.pid) has been reused; refusing to manage it. Remove the stale owner record only after inspection."
    }
    if (-not $process.Path -or [IO.Path]::GetFullPath($process.Path) -ne [IO.Path]::GetFullPath($python)) {
        throw "PID $($owner.pid) no longer points at Dungeon's private runtime Python; refusing to manage it."
    }
    return $process
}

switch ($Action) {
    'Status' {
        $owner = Read-Owner
        $process = Get-OwnedProcess $owner
        $ready = $false
        try { $null = Invoke-RestMethod "$baseUrl/system_stats" -TimeoutSec 2; $ready = $true } catch {}
        [pscustomobject]@{ Owned = [bool]$process; Ready = $ready; Pid = if ($process) { $process.Id } else { $null }; Url = $baseUrl; Log = Join-Path $logDir 'comfyui.log' } | ConvertTo-Json -Compress
    }
    'Start' {
        if (-not (Test-Path -LiteralPath $python) -or -not (Test-Path -LiteralPath $comfy)) { throw "Private ComfyUI runtime is not installed. Run scripts\benchmark-flux2-klein.ps1 -Install first." }
        $owner = Read-Owner
        if (Get-OwnedProcess $owner) {
            $null = Invoke-RestMethod "$baseUrl/system_stats" -TimeoutSec 3
            Write-Output "Already running under Dungeon ownership (PID $($owner.pid))."
            break
        }
        $listener = Get-NetTCPConnection -LocalPort 18188 -State Listen -ErrorAction SilentlyContinue
        if ($listener) { throw "Port 18188 is already occupied by PID $($listener[0].OwningProcess); refusing to attach or stop it." }
        New-Item -ItemType Directory -Force -Path $stateDir,$logDir | Out-Null
        $log = Join-Path $logDir 'comfyui.log'
        $arguments = @('-E', '-s', 'main.py', '--listen', '127.0.0.1', '--port', '18188', '--disable-auto-launch', '--disable-metadata')
        $proc = Start-Process -FilePath $python -ArgumentList $arguments -WorkingDirectory $comfy -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError (Join-Path $logDir 'comfyui-error.log')
        $created = $proc.StartTime.ToUniversalTime().ToString('o')
        $record = [pscustomobject]@{ pid = $proc.Id; startedUtc = $created; executable = $python; workingDirectory = $comfy; url = $baseUrl }
        $record | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt 240) {
            if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { throw "ComfyUI exited during startup. See $log and comfyui-error.log." }
            try {
                $null = Invoke-RestMethod "$baseUrl/system_stats" -TimeoutSec 2
                $watch.Stop()
                Write-Output (ConvertTo-Json -Compress @{ Ready = $true; StartupSeconds = [math]::Round($watch.Elapsed.TotalSeconds,2); Pid = $proc.Id; Url = $baseUrl })
                break
            } catch { Start-Sleep -Milliseconds 500 }
        }
        if ($watch.IsRunning) { $watch.Stop(); & $PSScriptRoot\dungeon-comfy.ps1 -Action Stop | Out-Null; throw 'ComfyUI readiness timed out after 240 seconds.' }
    }
    'Stop' {
        $owner = Read-Owner
        $process = Get-OwnedProcess $owner
        if (-not $process) {
            if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
            Write-Output 'Dungeon-owned ComfyUI is already stopped.'
            break
        }
        Stop-Process -Id $process.Id -ErrorAction Stop
        try { $process.WaitForExit(30000) } catch {}
        if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) { throw "Dungeon ComfyUI PID $($process.Id) did not stop within 30 seconds." }
        Remove-Item -LiteralPath $stateFile -Force
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        do {
            try { $null = Invoke-RestMethod "$baseUrl/system_stats" -TimeoutSec 1; Start-Sleep -Milliseconds 500 }
            catch { break }
        } while ([DateTime]::UtcNow -lt $deadline)
        Write-Output 'Stopped only the recorded Dungeon-owned ComfyUI process.'
    }
}
