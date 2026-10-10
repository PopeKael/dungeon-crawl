# Pure policy is separate from collection so busy/unknown/low-memory cases can
# be tested without launching workloads or changing shared GPU state.
function Get-DungeonDecision($Snapshot, $Config) {
    $reasons = [Collections.Generic.List[string]]::new()
    if (-not $Snapshot.TelemetryAvailable) {
        $reasons.Add('GPU telemetry is unavailable. Startup is held until it can be measured.')
    } else {
        $busy = @($Snapshot.Samples | Where-Object { $_.Busiest -ge $Config.busyEnginePercent -or $_.ThreeD -ge $Config.busy3DPercent })
        if ($busy.Count -ge $Config.busySamplesRequired) {
            $reasons.Add(('GPU is busy across {0} samples. Active processes: {1}. Finish or pause that work and retry.' -f $busy.Count, $Snapshot.ActiveProcesses))
        }
        if ($null -eq $Snapshot.ModelBudgetGiB) {
            $reasons.Add("No verified startup memory budget is configured for $($Snapshot.Model). Add a measured budget before using it as the launch default.")
        } else {
            $additional = [Math]::Max(0, $Snapshot.ModelBudgetGiB - $Snapshot.ReusableModelGiB)
            $required = $additional + $Config.vramHeadroomGiB
            if ($Snapshot.FreeVramGiB -lt $required) {
                $reasons.Add(('Insufficient free VRAM: {0:N1} GiB free; {1:N1} GiB required including headroom. Other resident models will not be unloaded.' -f $Snapshot.FreeVramGiB, $required))
            }
        }
    }
    if ($null -eq $Snapshot.FreeRamGiB -or $Snapshot.FreeRamGiB -lt $Config.minimumFreeRamGiB) {
        $reasons.Add(('Insufficient or unavailable free RAM: {0} GiB; minimum {1} GiB.' -f $Snapshot.FreeRamGiB, $Config.minimumFreeRamGiB))
    }
    [pscustomobject]@{ Ready = ($reasons.Count -eq 0); Reasons = @($reasons.ToArray()); Snapshot = $Snapshot }
}

function Get-DungeonSnapshot($Settings, $Config) {
    $snapshot = [pscustomobject]@{
        TelemetryAvailable = $false; Samples = @(); ActiveProcesses = 'unavailable'
        FreeVramGiB = $null; TotalVramGiB = $null; FreeRamGiB = $null
        Model = $Settings.model; Context = $Settings.context; ModelBudgetGiB = $null
        ReusableModelGiB = 0; ResidentModels = @(); Error = ''
    }
    $budget = $Config.modelBudgetsGiB.PSObject.Properties[$Settings.model]
    if ($budget) { $snapshot.ModelBudgetGiB = [double]$budget.Value }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5
        $snapshot.FreeRamGiB = [Math]::Round($os.FreePhysicalMemory / 1MB, 2)
    } catch { $snapshot.Error = 'RAM telemetry: ' + $_.Exception.Message }
    try {
        $resident = Invoke-RestMethod ($Settings.ollamaUrl.TrimEnd('/') + '/api/ps') -TimeoutSec 3
        $snapshot.ResidentModels = @($resident.models | Select-Object name, size_vram, context_length)
        $matching = @($resident.models | Where-Object { $_.name -eq $Settings.model -and $_.context_length -eq $Settings.context -and $_.size_vram -ge ($_.size * 0.99) })
        if ($matching.Count -eq 1) { $snapshot.ReusableModelGiB = $matching[0].size_vram / 1GB }
    } catch { <# Offline Ollama can be started after the readiness check. #> }
    try {
        if (-not ('DungeonGpuAdapters' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'gpu-adapters.cs') }
        $adapters = @([DungeonGpuAdapters]::Read() | Where-Object { -not $_.Software -and $_.Capacity -ge 1GB })
        if ($adapters.Count -ne 1) { throw 'A single dedicated GPU could not be identified; multiple dedicated adapters need an explicit selection policy.' }
        $capacity = [double]$adapters[0].Capacity
        $selectedLuid = $adapters[0].Luid
        $readings = @(Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage', '\GPU Adapter Memory(*)\Dedicated Usage' -SampleInterval 1 -MaxSamples 4)
        $samples = @(); $processActivity = @{}; [double]$highestUsed = 0
        foreach ($reading in ($readings | Select-Object -Skip 1)) {
            $valid = @($reading.CounterSamples | Where-Object { $_.Status -eq 0 -or $_.Status -eq 1 })
            $memory = @($valid | Where-Object { $_.Path -like '*\dedicated usage' -and $_.InstanceName.StartsWith($selectedLuid + '_phys_') })
            if ($memory.Count -ne 1 -or $memory[0].CookedValue -lt 0 -or $memory[0].CookedValue -gt $capacity) { throw 'GPU adapter memory measurement is unavailable or inconsistent.' }
            $highestUsed = [Math]::Max($highestUsed, $memory[0].CookedValue)
            $engines = @{}; $engineCount = 0
            foreach ($counter in $valid) {
                if ($counter.InstanceName -match '^pid_(\d+)_(luid_.+_phys_\d+_eng_\d+_engtype_(.+))$') {
                    $processNumber = [int]$Matches[1]; $engine = $Matches[2]; $engineCount++
                    if (-not $engine.StartsWith($memory[0].InstanceName + '_eng_')) { $engineCount--; continue }
                    $value = [Math]::Max(0, [Math]::Min(100, $counter.CookedValue))
                    $engines[$engine] += $value
                    $processActivity[$processNumber] = [Math]::Max([double]$processActivity[$processNumber], $value)
                }
            }
            if (-not $engineCount) { throw 'GPU engine activity is unavailable.' }
            $busiest = 0; $threeD = 0
            foreach ($engine in $engines.Keys) {
                $value = [Math]::Min(100, $engines[$engine])
                $busiest = [Math]::Max($busiest, $value)
                if ($engine -match 'engtype_3d$') { $threeD = [Math]::Max($threeD, $value) }
            }
            $samples += [pscustomobject]@{ Busiest = [Math]::Round($busiest, 1); ThreeD = [Math]::Round($threeD, 1) }
        }
        $snapshot.Samples = $samples
        $snapshot.TotalVramGiB = [Math]::Round($capacity / 1GB, 2)
        $snapshot.FreeVramGiB = [Math]::Round(($capacity - $highestUsed) / 1GB, 2)
        $snapshot.ActiveProcesses = (@($processActivity.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object {
            $proc = Get-Process -Id $_.Key -ErrorAction SilentlyContinue
            '{0} (PID {1}, {2:N1}%)' -f $(if ($proc) { $proc.ProcessName } else { 'exited/unknown' }), $_.Key, $_.Value
        })) -join ', '
        $snapshot.TelemetryAvailable = $true
    } catch { $snapshot.Error += ' GPU telemetry: ' + $_.Exception.Message }
    $snapshot
}
