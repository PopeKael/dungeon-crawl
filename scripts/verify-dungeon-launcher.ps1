$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dungeon-readiness.ps1')
$config = Get-Content (Join-Path $PSScriptRoot '../config/launcher.example.json') -Raw | ConvertFrom-Json
function Assert-That($condition, $message) { if (-not $condition) { throw $message } }
function New-Snapshot {
    [pscustomobject]@{ TelemetryAvailable = $true; Samples = @(@{Busiest=5;ThreeD=5},@{Busiest=6;ThreeD=6},@{Busiest=5;ThreeD=5}); ActiveProcesses = 'test-game'; FreeVramGiB = 15; FreeRamGiB = 12; ModelBudgetGiB = [double]$config.modelBudgetsGiB.'qwen3.5:4b'; ReusableModelGiB = 0; ImageBackendBudgetGiB = [double]$config.imageBackendBudgetsGiB.'sd-cpp-vulkan'; ReusableImageBackendGiB = 0; Model = 'qwen3.5:4b' }
}
$s = New-Snapshot
$requiredCold = [double]$config.modelBudgetsGiB.'qwen3.5:4b' + [double]$config.imageBackendBudgetsGiB.'sd-cpp-vulkan' + [double]$config.vramHeadroomGiB
$s.FreeVramGiB = $requiredCold - 0.01
Assert-That (-not (Get-DungeonDecision $s $config).Ready) 'Cold narrator and image renderer must block below measured budgets plus headroom.'
$s.FreeVramGiB = $requiredCold
Assert-That (Get-DungeonDecision $s $config).Ready 'Measured cold workload budgets and 1.25 GiB headroom should pass at the threshold.'
$s.FreeVramGiB = 12.8
Assert-That (Get-DungeonDecision $s $config).Ready 'The measured 12.8 GiB post-handoff availability must admit the tested Dungeon workload.'
$s.FreeVramGiB = 7.2
$s.ReusableModelGiB = 5.22
Assert-That (-not (Get-DungeonDecision $s $config).Ready) 'A resident narrator does not remove the cold image-renderer budget.'
$s.ReusableImageBackendGiB = $s.ImageBackendBudgetGiB
Assert-That (Get-DungeonDecision $s $config).Ready 'Matching resident narrator and renderer allocations should be reusable.'
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
foreach ($file in @('dungeon-tray.ps1','dungeon-worker.ps1','dungeon-readiness.ps1','dungeon-processes.ps1','dungeon-sdcpp.ps1','configure-private-upstream.ps1','stop-windows.ps1','install-dungeon-shortcut.ps1')) {
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file), [ref]$tokens, [ref]$parseErrors)
    Assert-That ($parseErrors.Count -eq 0) ("Parse errors in ${file}: " + ($parseErrors -join ', '))
}
'Passed: launcher readiness scenarios (including measured cold VRAM) and syntax. No workloads launched.'
