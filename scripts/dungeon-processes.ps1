# Lifecycle identity checks apply equally to the Next.js server and private edge.
function Get-DungeonOwnedProcess([string]$StatePath) {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($state.ProcessId -notmatch '^\d+$' -or [long]$state.ProcessId -le 0) { throw 'Invalid saved process identity.' }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($state.ProcessId)" -OperationTimeoutSec 5
    if (-not $process) { return $null }
    # PowerShell 7 may deserialize ISO dates to DateTime; Windows PowerShell
    # retains strings. Compare the same precise UTC representation in either.
    $created = if ($state.Created -is [DateTime]) { $state.Created.ToUniversalTime().ToString('o') } else { [string]$state.Created }
    if ($process.CreationDate.ToUniversalTime().ToString('o') -ne $created -or
        $process.CommandLine -ne $state.CommandLine -or $process.ExecutablePath -ne $state.ExecutablePath) {
        throw 'The saved PID now belongs to a different process. It will not be stopped.'
    }
    $process
}

function Save-DungeonOwnedProcess($Child, [string]$StatePath) {
    try {
        $identity = Get-CimInstance Win32_Process -Filter "ProcessId = $($Child.Id)" -OperationTimeoutSec 5
        if (-not $identity) { throw 'The application process exited before it could be registered.' }
        @{ ProcessId = $Child.Id; Created = $identity.CreationDate.ToUniversalTime().ToString('o'); CommandLine = $identity.CommandLine; ExecutablePath = $identity.ExecutablePath } |
            ConvertTo-Json | Set-Content -LiteralPath $StatePath
    } catch {
        # This is the just-created process object, never a port-based guess.
        if (-not $Child.HasExited) { $Child.Kill() }
        throw
    }
}

function Stop-DungeonOwnedProcesses([string[]]$StatePaths) {
    # Validate every identity before stopping anything.
    $processes = @($StatePaths | ForEach-Object { Get-DungeonOwnedProcess $_ })
    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -ErrorAction Stop
    }
    foreach ($path in $StatePaths) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
}
