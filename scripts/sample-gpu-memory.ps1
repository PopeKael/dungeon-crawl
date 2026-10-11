param(
    [Parameter(Mandatory = $true)] [string] $OutputPath,
    [Parameter(Mandatory = $true)] [string] $StopFile,
    [int] $IntervalMilliseconds = 500
)

$ErrorActionPreference = 'Stop'
$parent = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$statePath = Join-Path $root 'runtime/sdxl-lightning/state/comfy.pid.json'
while (-not (Test-Path -LiteralPath $StopFile)) {
    try {
        $samples = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage','\GPU Adapter Memory(*)\Total Committed','\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
        $ownedPid = $null
        if (Test-Path -LiteralPath $statePath) {
            try { $ownedPid = [int](Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).processId } catch { }
        }
        $samples = $samples | Where-Object { $_.Path -notmatch 'GPU Process Memory' -or ($null -ne $ownedPid -and $_.Path -match "pid_${ownedPid}_") }
        $values = foreach ($sample in $samples) {
            [pscustomobject]@{ path = $sample.Path; bytes = [double]$sample.CookedValue }
        }
        [pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); owned_pid = $ownedPid; counters = @($values) } | ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath $OutputPath -Encoding UTF8
    } catch {
        [pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content -LiteralPath $OutputPath -Encoding UTF8
    }
    Start-Sleep -Milliseconds $IntervalMilliseconds
}
