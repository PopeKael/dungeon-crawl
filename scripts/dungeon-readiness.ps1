# Pure policy is separate from collection so busy/unknown/low-memory cases can
# be tested without launching workloads or changing shared GPU state.
if (-not (Get-Command Get-DungeonOwnedProcess -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'dungeon-processes.ps1')
}

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
            $imageBudget = [double]$Snapshot.ImageBackendBudgetGiB
            $reusableImage = [double]$Snapshot.ReusableImageBackendGiB
            $additionalImage = [Math]::Max(0, $imageBudget - $reusableImage)
            $required = $additional + $additionalImage + $Config.vramHeadroomGiB
            if ($Snapshot.FreeVramGiB -lt $required) {
                $reasons.Add(('Insufficient free VRAM: {0:N1} GiB free; {1:N1} GiB required for the narrator, image renderer and headroom. Other resident models will not be unloaded.' -f $Snapshot.FreeVramGiB, $required))
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
        ReusableModelGiB = 0; ImageBackendBudgetGiB = 0; ReusableImageBackendGiB = 0
        ResidentModels = @(); Error = ''
    }
    $budget = $Config.modelBudgetsGiB.PSObject.Properties[$Settings.model]
    if ($budget) { $snapshot.ModelBudgetGiB = [double]$budget.Value }
    $imageBudget = $Config.imageBackendBudgetsGiB.PSObject.Properties[$Settings.imageBackend]
    if ($imageBudget) { $snapshot.ImageBackendBudgetGiB = [double]$imageBudget.Value }
    try {
        if (-not ('DungeonSystemMemory' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'gpu-adapters.cs') }
        $snapshot.FreeRamGiB = [Math]::Round([DungeonSystemMemory]::AvailablePhysicalBytes() / 1GB, 2)
    } catch { $snapshot.Error = 'RAM telemetry: ' + $_.Exception.Message }
    try {
        $resident = Invoke-RestMethod ($Settings.ollamaUrl.TrimEnd('/') + '/api/ps') -TimeoutSec 3
        $snapshot.ResidentModels = @($resident.models | Select-Object name, size_vram, context_length)
        $matching = @($resident.models | Where-Object { $_.name -eq $Settings.model -and $_.context_length -eq $Settings.context -and $_.size_vram -ge ($_.size * 0.99) })
        if ($matching.Count -eq 1) { $snapshot.ReusableModelGiB = $matching[0].size_vram / 1GB }
    } catch { <# Offline Ollama can be started after the readiness check. #> }
    if ($snapshot.ImageBackendBudgetGiB -gt 0) {
        try {
            $imageStatePath = Join-Path $PSScriptRoot '../runtime/sd-cpp-vulkan/state/backend-process.json'
            $imageProcess = Get-DungeonOwnedProcess $imageStatePath
            if ($imageProcess) { $snapshot.ReusableImageBackendGiB = $snapshot.ImageBackendBudgetGiB }
        } catch { $snapshot.Error += ' Image backend state: ' + $_.Exception.Message }
    }
    try {
        if (-not ('DungeonGpuAdapters' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'gpu-adapters.cs') }
        $adapters = @([DungeonGpuAdapters]::Read() | Where-Object { -not $_.Software -and $_.Capacity -ge 1GB })
        if ($adapters.Count -ne 1) { throw 'A single dedicated GPU could not be identified; multiple dedicated adapters need an explicit selection policy.' }
        $adapter = $adapters[0]
        $capacity = [double]$adapter.Capacity
        $snapshot.TotalVramGiB = [Math]::Round($capacity / 1GB, 2)
        # IDXGIAdapter3::QueryVideoMemoryInfo reports usage for the calling
        # process. Startup safety needs the whole adapter's usage, so use the
        # WDDM adapter-wide counter (the same source shown by MachineGlass).
        $memoryCounters = @(Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage' -MaxSamples 1 -ErrorAction Stop).CounterSamples
        $adapterCounters = @($memoryCounters | Where-Object { $_.InstanceName.StartsWith($adapter.Luid + '_phys_') })
        if ($adapterCounters.Count -ne 1) { throw "Could not identify one adapter-wide VRAM counter for $($adapter.Name) ($($adapter.Luid))." }
        $usedVram = [double]$adapterCounters[0].CookedValue
        if ($usedVram -lt 0 -or $usedVram -gt $capacity) { throw 'Adapter-wide dedicated GPU memory measurement is inconsistent.' }
        $snapshot.FreeVramGiB = [Math]::Round(($capacity - $usedVram) / 1GB, 2)
        $snapshot.ActiveProcesses = 'GPU process activity unavailable'
        try {
            $readings = @(Get-Counter -Counter '\GPU Engine(*)\Utilization Percentage' -SampleInterval 1 -MaxSamples 4 -ErrorAction Stop)
            $samples = @(); $processActivity = @{}
            foreach ($reading in ($readings | Select-Object -Skip 1)) {
                $valid = @($reading.CounterSamples | Where-Object { $_.Status -eq 0 -or $_.Status -eq 1 })
                $engines = @{}; $engineCount = 0
                foreach ($counter in $valid) {
                    if ($counter.InstanceName -match '^pid_(\d+)_(luid_.+_phys_\d+_eng_\d+_engtype_(.+))$' -and $Matches[2].StartsWith($adapter.Luid + '_phys_')) {
                        $processNumber = [int]$Matches[1]; $engine = $Matches[2]; $engineCount++
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
            if (-not $samples.Count) { throw 'GPU engine activity is unavailable.' }
            $snapshot.Samples = $samples
            $snapshot.ActiveProcesses = (@($processActivity.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object {
                $proc = Get-Process -Id $_.Key -ErrorAction SilentlyContinue
                '{0} (PID {1}, {2:N1}%)' -f $(if ($proc) { $proc.ProcessName } else { 'exited/unknown' }), $_.Key, $_.Value
            })) -join ', '
        } catch {
            $snapshot.Error += ' GPU activity counters unavailable; launch is gated by live VRAM and RAM measurements only.'
        }
        $snapshot.TelemetryAvailable = $true
    } catch { $snapshot.Error += ' GPU telemetry: ' + $_.Exception.Message }
    $snapshot
}
