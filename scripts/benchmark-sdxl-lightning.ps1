param(
    [int] $RunsPerCase = 2,
    [int[]] $PromptIndices = @(1, 2, 3),
    [string[]] $Resolutions = @('960x540', '1280x720'),
    [int] $ReadyTimeout = 180
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtime = Join-Path $root 'runtime/sdxl-lightning'
$reportDir = Join-Path $root 'benchmarks/sdxl-lightning'
$backendScript = Join-Path $PSScriptRoot 'dungeon-image-backend.ps1'
$monitorScript = Join-Path $PSScriptRoot 'sample-gpu-memory.ps1'
$memoryLog = Join-Path $reportDir 'gpu-memory.jsonl'
$stopFile = Join-Path $reportDir 'gpu-memory.stop'
$env:TEMP = Join-Path $runtime 'tmp'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Force -Path $env:TEMP,$reportDir | Out-Null

$monitor = $null
$overallExitCode = 0
try {
    $state = (& $backendScript status | ConvertFrom-Json)
    if ($state.Owned) { & $backendScript stop | Out-Null }
    Remove-Item -LiteralPath $memoryLog,$stopFile,(Join-Path $reportDir 'benchmark.json'),(Join-Path $reportDir 'benchmark-report.md') -Force -ErrorAction SilentlyContinue
    $monitor = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$monitorScript,'-OutputPath',$memoryLog,'-StopFile',$stopFile,'-IntervalMilliseconds','500') -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1200

    foreach ($promptIndex in $PromptIndices) {
        if ($promptIndex -lt 1 -or $promptIndex -gt 3) { throw "Prompt index must be 1, 2, or 3; got $promptIndex." }
        foreach ($resolution in $Resolutions) {
            if ($resolution -notin @('960x540','1280x720')) { throw "Unsupported benchmark resolution: $resolution" }
            $state = (& $backendScript status | ConvertFrom-Json)
            if ($state.Owned) { & $backendScript stop | Out-Null }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $startText = & $backendScript start -ReadyTimeoutSeconds $ReadyTimeout
            $watch.Stop()
            $launchLine = @($startText | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
            if (-not $launchLine) { throw "Backend start returned no readiness record: $($startText -join ' ')" }
            $launch = $launchLine[0] | ConvertFrom-Json
            Write-Host "Prompt $promptIndex / ${resolution}: cold start $([math]::Round($watch.Elapsed.TotalSeconds,2))s, backend PID $($launch.ProcessId)"
            $caseRuns = if ($resolution -eq '1280x720') { 1 } else { $RunsPerCase }
            $arguments = @(
                '-s','-u',(Join-Path $PSScriptRoot 'benchmark-sdxl-lightning.py'),
                '--runs-per-case',"$caseRuns",'--max-jobs','0','--ready-timeout',"$ReadyTimeout",
                '--externally-started','--startup-seconds',"$([math]::Round($watch.Elapsed.TotalSeconds,3))",
                '--backend-pid',"$($launch.ProcessId)",'--prompt-indices',"$promptIndex",'--only-resolution',$resolution,'--append'
            )
            & (Join-Path $runtime 'python/python.exe') @arguments
            if ($LASTEXITCODE -ne 0) { $overallExitCode = 1 }
            $state = (& $backendScript status | ConvertFrom-Json)
            if ($state.Owned) { & $backendScript stop | Out-Null }
        }
    }
} finally {
    try {
        $state = (& $backendScript status | ConvertFrom-Json)
        if ($state.Owned) { & $backendScript stop | Out-Null }
    } catch { }
    Start-Sleep -Milliseconds 1200
    if ($monitor) {
        New-Item -ItemType File -Force -Path $stopFile | Out-Null
        if (-not $monitor.WaitForExit(10000)) { Stop-Process -Id $monitor.Id -Force }
    }
    Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
}
exit $overallExitCode
