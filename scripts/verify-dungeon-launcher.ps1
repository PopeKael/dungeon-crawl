$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dungeon-readiness.ps1')
$config = Get-Content (Join-Path $PSScriptRoot '../config/launcher.json') -Raw | ConvertFrom-Json
function Assert-That($condition, $message) { if (-not $condition) { throw $message } }
function New-Snapshot {
    [pscustomobject]@{ TelemetryAvailable = $true; Samples = @(@{Busiest=5;ThreeD=5},@{Busiest=6;ThreeD=6},@{Busiest=5;ThreeD=5}); ActiveProcesses = 'test-game'; FreeVramGiB = 9; FreeRamGiB = 12; ModelBudgetGiB = 6; ReusableModelGiB = 0; Model = 'qwen3.5:4b' }
}
$s = New-Snapshot
Assert-That (Get-DungeonDecision $s $config).Ready 'Idle system should pass.'
$s.FreeVramGiB = 7
Assert-That (-not (Get-DungeonDecision $s $config).Ready) 'Cold model must reserve 6 GiB plus 2 GiB headroom.'
$s.ReusableModelGiB = 5.22
Assert-That (Get-DungeonDecision $s $config).Ready 'Matching resident allocation should be reusable.'
$s.FreeRamGiB = 2
Assert-That (-not (Get-DungeonDecision $s $config).Ready) 'Low RAM must block.'
$s = New-Snapshot; $s.TelemetryAvailable = $false
Assert-That (-not (Get-DungeonDecision $s $config).Ready) 'Missing telemetry must not be treated as idle.'
$s = New-Snapshot; $s.ModelBudgetGiB = $null
Assert-That (-not (Get-DungeonDecision $s $config).Ready) 'Unknown model memory requirement must block.'
$s = New-Snapshot; $s.Samples = @(@{Busiest=70;ThreeD=70},@{Busiest=80;ThreeD=80},@{Busiest=5;ThreeD=5})
Assert-That (-not (Get-DungeonDecision $s $config).Ready) 'Sustained gaming must block.'
$s = New-Snapshot; $s.Samples = @(@{Busiest=50;ThreeD=0},@{Busiest=50;ThreeD=0},@{Busiest=5;ThreeD=5})
Assert-That (-not (Get-DungeonDecision $s $config).Ready) 'Compute work must block.'
$s = New-Snapshot; $s.Samples = @(@{Busiest=90;ThreeD=90},@{Busiest=5;ThreeD=5},@{Busiest=5;ThreeD=5})
Assert-That (Get-DungeonDecision $s $config).Ready 'One transient spike must not look like sustained work.'
foreach ($file in @('dungeon-tray.ps1','dungeon-worker.ps1','dungeon-readiness.ps1','install-dungeon-shortcut.ps1')) {
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file), [ref]$tokens, [ref]$parseErrors)
    Assert-That ($parseErrors.Count -eq 0) ("Parse errors in ${file}: " + ($parseErrors -join ', '))
}
'Passed: 9 readiness scenarios and launcher script syntax. No workloads launched.'
