$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dungeon-processes.ps1')
$fixtureRoot = Join-Path $PSScriptRoot ('../logs/process-fixture-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$fixturePath = Join-Path $fixtureRoot 'process.json'
$otherPath = Join-Path $fixtureRoot 'other.json'
$script:stopped = @()
$script:forceStopped = @()
$created = [DateTime]::UtcNow
$script:fixtureProcess = [pscustomobject]@{ Id = 12345; ProcessName = 'node'; StartTime = $created; Path = 'C:\fixture\node.exe' }
function Get-Process { param($Id, $ErrorAction) return $script:fixtureProcess }
function Stop-Process { param($Id, $ErrorAction, [switch]$Force) $script:stopped += $Id; if ($Force) { $script:forceStopped += $Id } }
function Assert-That($condition, $message) { if (-not $condition) { throw $message } }
function Get-CimInstance {
    param($ClassName, $Filter, $ErrorAction)
    if ($ClassName -ne 'Win32_Process' -or -not $script:runnerCurrent) { return }
    if ($Filter -and $Filter -notmatch "ProcessId = $($script:runnerCurrent.ProcessId)(\s|$)") { return }
    $script:runnerCurrent
}
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
    $other = Get-Content $fixturePath -Raw | ConvertFrom-Json; $other.ExecutablePath = 'C:\unrelated\node.exe'; $other | ConvertTo-Json | Set-Content $otherPath
    $rejected = $false
    try { Stop-DungeonOwnedProcesses @($otherPath) } catch { $rejected = $true }
    Assert-That ($rejected -and $script:stopped.Count -eq 0) 'Changed executable path must not be stopped.'
    Stop-DungeonOwnedProcesses @($fixturePath) -Force
    Assert-That ($script:stopped.Count -eq 1 -and $script:forceStopped.Count -eq 1 -and -not (Test-Path $fixturePath)) 'Force shutdown must stop only the matching process and clear state.'
    $script:fixtureProcess = $null
    Assert-That ($null -eq (Get-DungeonOwnedProcess $otherPath)) 'Exited processes must permit recovery.'

    $ollamaStatePath = Join-Path $fixtureRoot 'ollama.json'
    $script:listenerPid = 23456
    $script:fixtureProcess = [pscustomobject]@{ Id = $script:listenerPid; ProcessName = 'ollama'; StartTime = [DateTime]::UtcNow; Path = 'C:\fixture\ollama.exe' }
    function Get-DungeonTcpListeners([int]$LocalPort, [string]$LocalAddress = '') {
        if ($LocalPort -eq 11434) { [pscustomobject]@{ LocalAddress='127.0.0.1'; LocalPort=11434; OwningProcess=$script:listenerPid } }
    }
    function Get-Command([string]$Name, $ErrorAction) {
        if ($Name -eq 'ollama.exe') { [pscustomobject]@{ Source='C:\fixture\ollama.exe' }; return }
        throw "Unexpected command lookup in fixture: $Name"
    }
    function Wait-Process($Id, $Timeout, $ErrorAction) { }

    # A runner that exits between enumeration and identity recheck is already
    # stopped; a reused PID after Stop-Process must not trigger a false failure.
    $runnerPath = 'C:\fixture\lib\ollama\llama-server.exe'
    $runnerCreated = [DateTime]::UtcNow
    $script:runnerCurrent = [pscustomobject]@{
        ProcessId = 34567; ExecutablePath = $runnerPath
        CommandLine = 'llama-server.exe --model test'; CreationDate = $runnerCreated
    }
    $script:runnerRace = $false
    function Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        if ($ClassName -ne 'Win32_Process') { return }
        if ($script:runnerRace -and -not $Filter) {
            $snapshot = $script:runnerCurrent
            $script:runnerCurrent = $null
            return $snapshot
        }
        if (-not $script:runnerCurrent) { return }
        if ($Filter -and $Filter -notmatch "ProcessId = $($script:runnerCurrent.ProcessId)(\s|$)") { return }
        $script:runnerCurrent
    }
    $script:runnerRace = $true
    $stoppedBeforeRunner = $script:stopped.Count
    Assert-That ((Stop-DungeonOllamaRunnerProcesses 'C:\fixture\ollama.exe') -eq 0) 'A runner that exited before the identity check should be treated as already stopped.'
    Assert-That ($script:stopped.Count -eq $stoppedBeforeRunner) 'An exited runner PID must not be stopped again.'
    $script:runnerRace = $false
    $script:runnerCurrent = [pscustomobject]@{
        ProcessId = 34567; ExecutablePath = $runnerPath
        CommandLine = 'llama-server.exe --model test'; CreationDate = $runnerCreated
    }
    $script:runnerReplacementOnStop = $true
    function Stop-Process {
        param($Id, $ErrorAction, [switch]$Force)
        $script:stopped += $Id
        if ($Force) { $script:forceStopped += $Id }
        if ($Id -eq 34567 -and $script:runnerReplacementOnStop) {
            $script:runnerCurrent = [pscustomobject]@{
                ProcessId = 34567; ExecutablePath = 'C:\unrelated\worker.exe'
                CommandLine = 'unrelated worker'; CreationDate = $runnerCreated.AddSeconds(1)
            }
        } elseif ($Id -eq 34567 -and $script:runnerBlankPathOnStop) {
            $script:runnerCurrent = [pscustomobject]@{
                ProcessId = 34567; ExecutablePath = ''
                CommandLine = ''; CreationDate = $runnerCreated
            }
        }
    }
    $stoppedBeforeRunner = $script:stopped.Count
    Assert-That ((Stop-DungeonOllamaRunnerProcesses 'C:\fixture\ollama.exe') -eq 1) 'A matching Ollama runner should be stopped.'
    Assert-That ($script:stopped.Count -eq ($stoppedBeforeRunner + 1) -and $script:stopped[-1] -eq 34567) 'Only the verified runner should be stopped.'

    # A partial CIM row during process exit must not throw from GetFullPath.
    $script:runnerReplacementOnStop = $false
    $script:runnerBlankPathOnStop = $true
    $script:runnerCurrent = [pscustomobject]@{
        ProcessId = 34567; ExecutablePath = $runnerPath
        CommandLine = 'llama-server.exe --model test'; CreationDate = $runnerCreated
    }
    $stoppedBeforeRunner = $script:stopped.Count
    Assert-That ((Stop-DungeonOllamaRunnerProcesses 'C:\fixture\ollama.exe') -eq 1) 'A runner with a partial exit snapshot should complete cleanup without a path exception.'
    Assert-That ($script:stopped.Count -eq ($stoppedBeforeRunner + 1) -and $script:stopped[-1] -eq 34567) 'The partial-snapshot case should stop only the verified runner.'

    # Restore the server-only fixtures after runner identity checks.
    $script:runnerCurrent = $null
    function Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        if ($ClassName -eq 'Win32_Process' -and $script:runnerCurrent) { $script:runnerCurrent }
    }
    $stoppedBeforeOllama = $script:stopped.Count
    Assert-That (Stop-DungeonOllamaServer 'http://127.0.0.1:11434' $ollamaStatePath -Force) 'A verified Ollama server listener should stop.'
    Assert-That ($script:stopped.Count -eq ($stoppedBeforeOllama + 1) -and $script:forceStopped[-1] -eq $script:listenerPid) 'Ollama shutdown should force-stop only its verified API listener.'
    $script:fixtureProcess = [pscustomobject]@{ Id = $script:listenerPid; ProcessName = 'other-service'; StartTime = [DateTime]::UtcNow; Path = 'C:\fixture\other.exe' }
    $rejected = $false
    try { Stop-DungeonOllamaServer 'http://127.0.0.1:11434' $ollamaStatePath -Force } catch { $rejected = $true }
    Assert-That ($rejected -and $script:stopped.Count -eq ($stoppedBeforeOllama + 1)) 'An unverified port owner must remain untouched.'
    'Passed: owned process matching, reused PID, executable mismatch, force stop, runner exit race, runner PID reuse, partial runner snapshot, and verified Ollama-port ownership. No real processes stopped.'
} finally {
    Remove-Item -LiteralPath $fixturePath, $otherPath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureRoot
}
