param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('start', 'status', 'stop')]
    [string] $Action,
    [int] $Port = 18189,
    [int] $ReadyTimeoutSeconds = 120,
    [switch] $CpuVae,
    [switch] $LowVram,
    [switch] $SplitCrossAttention,
    [switch] $NoVram
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtime = Join-Path $root 'runtime/sdxl-lightning'
$python = Join-Path $runtime 'python/python.exe'
$comfy = Join-Path $runtime 'ComfyUI'
$stateDir = Join-Path $runtime 'state'
$logsDir = Join-Path $runtime 'logs'
$pidFile = Join-Path $stateDir 'comfy.pid.json'
$baseUrl = "http://127.0.0.1:$Port"

New-Item -ItemType Directory -Force -Path $stateDir, $logsDir, (Join-Path $runtime 'tmp') | Out-Null

function Get-OwnedProcess {
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
    $state = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
    try { $proc = Get-Process -Id ([int]$state.processId) -ErrorAction Stop } catch { return $null }
    if ($proc.StartTime.ToUniversalTime().Ticks -ne [long]$state.startTimeUtcTicks) { return $null }
    if (-not $proc.Path -or [IO.Path]::GetFullPath($proc.Path) -ne [IO.Path]::GetFullPath($python)) { return $null }
    return $proc
}

function Test-Ready {
    try {
        $null = Invoke-RestMethod -Uri "$baseUrl/system_stats" -TimeoutSec 2
        return $true
    } catch { return $false }
}

switch ($Action) {
    'status' {
        $proc = Get-OwnedProcess
        [pscustomobject]@{ Owned = [bool]$proc; ProcessId = if ($proc) { $proc.Id } else { $null }; Ready = (Test-Ready); Url = $baseUrl } | ConvertTo-Json -Compress
    }
    'start' {
        if (Get-OwnedProcess) { throw 'Dungeon-owned ComfyUI process is already running.' }
        $portListener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($portListener) { throw "Port $Port is already occupied; refusing to control a process not started by this script." }
        if (-not (Test-Path -LiteralPath $python) -or -not (Test-Path -LiteralPath (Join-Path $comfy 'main.py'))) { throw 'The private Python or ComfyUI checkout is missing.' }
        $env:TEMP = Join-Path $runtime 'tmp'
        $env:TMP = $env:TEMP
        $arguments = @('-s', 'main.py', '--directml', '0', '--listen', '127.0.0.1', '--port', "$Port", '--disable-auto-launch')
        if ($CpuVae) { $arguments += '--cpu-vae' }
        if ($LowVram) { $arguments += '--lowvram' }
        if ($SplitCrossAttention) { $arguments += '--use-split-cross-attention' }
        if ($NoVram) { $arguments += '--novram' }
        $proc = Start-Process -FilePath $python -ArgumentList $arguments -WorkingDirectory $comfy -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logsDir 'comfy.stdout.log') -RedirectStandardError (Join-Path $logsDir 'comfy.stderr.log')
        Start-Sleep -Milliseconds 300
        $proc.Refresh()
        if ($proc.HasExited) { throw "ComfyUI exited during launch. See $logsDir" }
        @{ processId = $proc.Id; startTimeUtcTicks = $proc.StartTime.ToUniversalTime().Ticks; executable = $python; port = $Port; arguments = $arguments } | ConvertTo-Json | Set-Content -LiteralPath $pidFile -Encoding UTF8
        $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Ready) { [pscustomobject]@{ Owned = $true; ProcessId = $proc.Id; Ready = $true; Url = $baseUrl } | ConvertTo-Json -Compress; exit 0 }
            $proc.Refresh()
            if ($proc.HasExited) { Remove-Item -LiteralPath $pidFile -Force; throw "ComfyUI exited before readiness. See $logsDir" }
            Start-Sleep -Milliseconds 500
        }
        throw "ComfyUI did not become ready within $ReadyTimeoutSeconds seconds. See $logsDir"
    }
    'stop' {
        $proc = Get-OwnedProcess
        if (-not $proc) {
            if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force }
            [pscustomobject]@{ Owned = $false; Stopped = $false; Ready = (Test-Ready); Note = 'No verified Dungeon-owned process.' } | ConvertTo-Json -Compress
            exit 0
        }
        $proc.CloseMainWindow() | Out-Null
        if (-not $proc.WaitForExit(8000)) { Stop-Process -Id $proc.Id -Force; $proc.WaitForExit() }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{ Owned = $false; Stopped = $true; Ready = (Test-Ready); ProcessId = $proc.Id } | ConvertTo-Json -Compress
    }
}
