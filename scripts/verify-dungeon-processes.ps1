$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dungeon-processes.ps1')
$fixtureRoot = Join-Path $PSScriptRoot ('../logs/process-fixture-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$fixturePath = Join-Path $fixtureRoot 'process.json'
$otherPath = Join-Path $fixtureRoot 'other.json'
$script:stopped = @()
$created = [DateTime]::UtcNow
$script:fixtureProcess = [pscustomobject]@{ ProcessId = 12345; CreationDate = $created; CommandLine = 'node fixture'; ExecutablePath = 'C:\fixture\node.exe' }
function Get-CimInstance { param($ClassName, $Filter, $OperationTimeoutSec) return $script:fixtureProcess }
function Stop-Process { param($Id, $ErrorAction) $script:stopped += $Id }
function Assert-That($condition, $message) { if (-not $condition) { throw $message } }
try {
    Assert-That ($null -eq (Get-DungeonOwnedProcess $fixturePath)) 'Absent state must be harmless.'
    @{ ProcessId = 12345; Created = $created.ToUniversalTime().ToString('o'); CommandLine = 'node fixture'; ExecutablePath = 'C:\fixture\node.exe' } | ConvertTo-Json | Set-Content $fixturePath
    Assert-That ((Get-DungeonOwnedProcess $fixturePath).ProcessId -eq 12345) 'Matching identity must pass.'
    Copy-Item $fixturePath $otherPath
    $other = Get-Content $otherPath -Raw | ConvertFrom-Json
    $other.Created = $created.AddSeconds(-1).ToString('o'); $other | ConvertTo-Json | Set-Content $otherPath
    $rejected = $false
    try { Stop-DungeonOwnedProcesses @($fixturePath, $otherPath) } catch { $rejected = $true }
    Assert-That ($rejected -and $script:stopped.Count -eq 0) 'A reused PID must prevent all stops.'
    foreach ($field in @('CommandLine', 'ExecutablePath')) {
        $other = Get-Content $fixturePath -Raw | ConvertFrom-Json; $other.$field = 'unrelated'; $other | ConvertTo-Json | Set-Content $otherPath
        $rejected = $false
        try { Stop-DungeonOwnedProcesses @($otherPath) } catch { $rejected = $true }
        Assert-That ($rejected -and $script:stopped.Count -eq 0) 'Changed command/executable must not be stopped.'
    }
    Stop-DungeonOwnedProcesses @($fixturePath)
    Assert-That ($script:stopped.Count -eq 1 -and -not (Test-Path $fixturePath)) 'Only matching processes should stop and clear state.'
    $script:fixtureProcess = $null
    Assert-That ($null -eq (Get-DungeonOwnedProcess $otherPath)) 'Exited processes must permit recovery.'
    'Passed: owned process matching, reused PID, command/path mismatch, all-identities prevalidation, stop and stale-state recovery. No real processes stopped.'
} finally {
    Remove-Item -LiteralPath $fixturePath, $otherPath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureRoot
}
