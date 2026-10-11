param(
    [string] $OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'benchmarks/sdxl-lightning'),
    [int] $CounterIntervalMilliseconds = 500
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$backendScript = Join-Path $PSScriptRoot 'dungeon-image-backend.ps1'
$runtime = Join-Path $root 'runtime/sdxl-lightning'
$statePath = Join-Path $runtime 'state/comfy.pid.json'
$logsPath = Join-Path $runtime 'logs'
$ollamaExe = (Get-Command ollama.exe -ErrorAction Stop).Source
$ollamaUrl = 'http://127.0.0.1:11434'
$comfyUrl = 'http://127.0.0.1:18189'
$model = 'qwen3.5:4b'
$context = 65536
$checkpoint = 'sdxl_lightning_4step.safetensors'
$prompt = 'Wide establishing illustration of Aethelgard, an immense ancient city inside a subterranean cavern. Black basalt arches span deep chasms above glowing amber rivers. Crumbling towers and hanging gardens are illuminated by blue bioluminescent fungi. Vast scale, atmospheric depth, cinematic fantasy illustration, dramatic blue and amber lighting, no text, 16:9.'
$samplePath = Join-Path $OutputDirectory 'gpu-coexistence-samples.jsonl'
$phasePath = Join-Path $OutputDirectory 'gpu-coexistence-phases.jsonl'
$resultPath = Join-Path $OutputDirectory 'gpu-coexistence.json'
$reportPath = Join-Path $OutputDirectory 'gpu-coexistence.md'
$serverStdout = Join-Path $logsPath 'ollama-coexistence.stdout.log'
$serverStderr = Join-Path $logsPath 'ollama-coexistence.stderr.log'
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory, $logsPath
Remove-Item -LiteralPath $samplePath, $phasePath -Force -ErrorAction SilentlyContinue

Add-Type -Path (Join-Path $PSScriptRoot 'gpu-adapters.cs')
$adapter = [DungeonGpuAdapters]::Read() | Where-Object { -not $_.Software -and $_.Capacity -gt 1GB } | Select-Object -First 1
if (-not $adapter) { throw 'Could not identify the RX 7800 XT through DXGI.' }
$adapterLuid = $adapter.Luid

$markers = [Collections.Generic.List[object]]::new()
$runs = [Collections.Generic.List[object]]::new()
$serverProcess = $null
$serverStartedByTest = $false
$imageStartedByTest = $false
$samplerJob = $null
$narratorRootPid = $null
$comfyRootPids = [Collections.Generic.List[int]]::new()
$narratorResidentInfo = $null
$imageOnlyResidentInfo = $null
$coexistResidentInfo = $null
$loadTimes = [ordered]@{}
$narratorUsable = $false
$narratorUsabilitySeconds = $null
$narratorUsabilityText = ''
$offloadConclusion = 'Not determined'
$cleanupErrors = [Collections.Generic.List[string]]::new()

function Add-PhaseMarker([string] $Name, [string] $Event) {
    $item = [pscustomobject]@{ name = $Name; event = $Event; utc = [DateTime]::UtcNow.ToString('o') }
    $script:markers.Add($item)
    $item | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:phasePath -Encoding UTF8
}

function Get-ResidentModel {
    $data = Invoke-RestMethod -Uri ($script:ollamaUrl + '/api/ps') -TimeoutSec 5
    $matches = @($data.models | Where-Object { $_.name -eq $script:model })
    if ($matches.Count -gt 1) { throw 'Ollama reports duplicate qwen3.5:4b resident entries.' }
    if ($matches.Count -eq 0) { return $null }
    $m = $matches[0]
    [pscustomobject]@{
        name = $m.name
        size_bytes = [long]$m.size
        size_vram_bytes = [long]$m.size_vram
        context_length = [int]$m.context_length
        vram_gib = [Math]::Round(([double]$m.size_vram / 1GB), 3)
        model_gib = [Math]::Round(([double]$m.size / 1GB), 3)
        gpu_resident_fraction = if ([double]$m.size -gt 0) { [Math]::Round(([double]$m.size_vram / [double]$m.size), 4) } else { $null }
        expires_at = $m.expires_at
    }
}

function Get-ProcessTreeIds([int] $RootPid) {
    if (-not $RootPid) { return @() }
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId)
    $found = [Collections.Generic.HashSet[int]]::new()
    $null = $found.Add($RootPid)
    do {
        $changed = $false
        foreach ($p in $all) {
            if ($found.Contains([int]$p.ParentProcessId) -and $found.Add([int]$p.ProcessId)) { $changed = $true }
        }
    } while ($changed)
    @($found)
}

function Wait-OllamaReady {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { $null = Invoke-RestMethod -Uri ($script:ollamaUrl + '/api/version') -TimeoutSec 2; return }
        catch { Start-Sleep -Milliseconds 400 }
    }
    throw 'Dungeon-configured local Ollama endpoint did not become ready within 60 seconds.'
}

function Invoke-Narrator([string] $PromptText, [int] $Predict, [string] $KeepAlive) {
    $body = @{
        model = $script:model; prompt = $PromptText; stream = $false; think = $false; keep_alive = $KeepAlive
        options = @{ num_ctx = $script:context; num_predict = $Predict }
    } | ConvertTo-Json -Depth 5 -Compress
    Invoke-RestMethod -Uri ($script:ollamaUrl + '/api/generate') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 300
}

function Invoke-Render([string] $Label) {
    $clientId = [guid]::NewGuid().ToString()
    $seed = switch ($Label) {
        'image-only-model-load' { 982009 }
        'image-only-measured' { 982010 }
        default { 982011 }
    }
    $prefix = 'benchmark-sdxl-lightning/gpu-memory-coexistence/' + $Label
    $graph = [ordered]@{
        '1' = @{ class_type = 'CheckpointLoaderSimple'; inputs = @{ ckpt_name = $script:checkpoint } }
        '2' = @{ class_type = 'CLIPTextEncode'; inputs = @{ text = $script:prompt; clip = @('1', 1) } }
        '3' = @{ class_type = 'CLIPTextEncode'; inputs = @{ text = ''; clip = @('1', 1) } }
        '4' = @{ class_type = 'EmptyLatentImage'; inputs = @{ width = 960; height = 540; batch_size = 1 } }
        '5' = @{ class_type = 'KSampler'; inputs = @{ model = @('1', 0); positive = @('2', 0); negative = @('3', 0); latent_image = @('4', 0); seed = $seed; steps = 4; cfg = 1.0; sampler_name = 'euler'; scheduler = 'sgm_uniform'; denoise = 1.0 } }
        '6' = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('5', 0); vae = @('1', 2) } }
        '7' = @{ class_type = 'SaveImage'; inputs = @{ images = @('6', 0); filename_prefix = $prefix } }
    }
    $body = @{ prompt = $graph; client_id = $clientId } | ConvertTo-Json -Depth 12 -Compress
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $queued = Invoke-RestMethod -Uri ($script:comfyUrl + '/prompt') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30
    $promptId = [string]$queued.prompt_id
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    $jobHistory = $null
    $failure = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 350
        try {
            $history = Invoke-RestMethod -Uri ($script:comfyUrl + '/history/' + $promptId) -TimeoutSec 10
            $prop = $history.PSObject.Properties[$promptId]
            if ($prop) {
                $jobHistory = $prop.Value
                if ($jobHistory.outputs -and $jobHistory.outputs.'7' -and $jobHistory.outputs.'7'.images.Count -gt 0) { break }
                if ($jobHistory.status.status_str -eq 'error') { $failure = ($jobHistory.status.messages | ConvertTo-Json -Depth 10 -Compress); break }
            }
        } catch { $failure = $_.Exception.Message; break }
    }
    $watch.Stop()
    $output = $null
    if ($jobHistory -and $jobHistory.outputs -and $jobHistory.outputs.'7' -and $jobHistory.outputs.'7'.images.Count -gt 0) {
        $image = $jobHistory.outputs.'7'.images[0]
        $output = Join-Path (Join-Path $script:runtime 'ComfyUI/output') (Join-Path ([string]$image.subfolder) ([string]$image.filename))
        if (-not (Test-Path -LiteralPath $output)) { $failure = 'Comfy history returned an output path that does not exist.' }
    } elseif (-not $failure) { $failure = 'Timed out waiting for the ComfyUI job result.' }
    [pscustomobject]@{
        label = $Label; prompt_id = $promptId; seed = $seed; width = 960; height = 540
        elapsed_seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
        success = [bool](-not $failure); output = $output; failure = $failure
    }
}

function Get-PhaseStats([string] $Name) {
    $start = @($script:markers | Where-Object { $_.name -eq $Name -and $_.event -eq 'start' } | Select-Object -Last 1)
    $end = @($script:markers | Where-Object { $_.name -eq $Name -and $_.event -eq 'end' } | Select-Object -Last 1)
    if (-not $start -or -not $end -or -not (Test-Path -LiteralPath $script:samplePath)) { return $null }
    $t0 = [DateTime]::Parse($start[0].utc).ToUniversalTime()
    $t1 = [DateTime]::Parse($end[0].utc).ToUniversalTime()
    $rows = foreach ($line in Get-Content -LiteralPath $script:samplePath) {
        try { $s = $line | ConvertFrom-Json } catch { continue }
        if (-not $s.utc -or -not $s.adapter_bytes) { continue }
        $t = [DateTime]::Parse($s.utc).ToUniversalTime()
        if ($t -ge $t0 -and $t -le $t1) { $s }
    }
    $rows = @($rows)
    if (-not $rows.Count) { return $null }
    $narrator = @($script:narratorPids)
    $comfy = @($script:comfyRootPids)
    $narratorVals = [Collections.Generic.List[double]]::new()
    $comfyVals = [Collections.Generic.List[double]]::new()
    foreach ($row in $rows) {
        [double]$nTotal = 0; [double]$cTotal = 0
        foreach ($owner in $row.processes) {
            if ($narrator -contains [int]$owner.pid) { $nTotal += [double]$owner.bytes }
            if ($comfy -contains [int]$owner.pid) { $cTotal += [double]$owner.bytes }
        }
        $narratorVals.Add($nTotal); $comfyVals.Add($cTotal)
    }
    [pscustomobject]@{
        samples = $rows.Count
        adapter_baseline_gib = [Math]::Round(([double]$rows[0].adapter_bytes / 1GB), 3)
        adapter_mean_gib = [Math]::Round((($rows | Measure-Object -Property adapter_bytes -Average).Average / 1GB), 3)
        adapter_peak_gib = [Math]::Round((($rows | Measure-Object -Property adapter_bytes -Maximum).Maximum / 1GB), 3)
        adapter_after_gib = [Math]::Round(([double]$rows[-1].adapter_bytes / 1GB), 3)
        narrator_process_peak_gib = [Math]::Round((($narratorVals | Measure-Object -Maximum).Maximum / 1GB), 3)
        image_process_peak_gib = [Math]::Round((($comfyVals | Measure-Object -Maximum).Maximum / 1GB), 3)
    }
}

function Write-ResultFiles($Payload) {
    $Payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:resultPath -Encoding UTF8
    $rows = [Collections.Generic.List[string]]::new()
    $rows.Add('# Dungeon Crawl GPU memory coexistence test')
    $rows.Add('')
    $rows.Add(('Generated UTC: {0}' -f $Payload.completed_utc))
    $rows.Add(('GPU: {0}, {1:N2} GiB dedicated' -f $Payload.gpu.name, $Payload.gpu.capacity_gib))
    $rows.Add(('Measurement: Windows WDDM `GPU Adapter Memory(*)\Dedicated Usage` and `GPU Process Memory(*)\Dedicated Usage`, sampled about every {0} ms.' -f $Payload.sample_interval_ms))
    $rows.Add('')
    $rows.Add('| State | Narrator VRAM | Image process VRAM | Total dedicated | Peak dedicated | Render time | Result |')
    $rows.Add('|---|---:|---:|---:|---:|---:|---|')
    foreach ($state in $Payload.states) {
        $n = if ($null -eq $state.narrator_vram_gib) { '—' } else { '{0:N3} GiB' -f $state.narrator_vram_gib }
        $i = if ($null -eq $state.image_process_peak_gib) { '—' } else { '{0:N3} GiB' -f $state.image_process_peak_gib }
        $t = if ($null -eq $state.total_dedicated_gib) { '—' } else { '{0:N3} GiB' -f $state.total_dedicated_gib }
        $p = if ($null -eq $state.peak_dedicated_gib) { '—' } else { '{0:N3} GiB' -f $state.peak_dedicated_gib }
        $r = if ($null -eq $state.render_seconds) { '—' } else { '{0:N2} s' -f $state.render_seconds }
        $rows.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $state.name,$n,$i,$t,$p,$r,$state.result))
    }
    $rows.Add('')
    $rows.Add('## Narrator residency and offloading')
    $rows.Add('')
    $rows.Add(('Narrator only: {0}' -f ($Payload.narrator_only | ConvertTo-Json -Compress)))
    $rows.Add(('Narrator after coexist render: {0}' -f ($Payload.narrator_after_coexist | ConvertTo-Json -Compress)))
    $rows.Add(('Usability probe after render: success={0}, elapsed={1}s, reply={2}' -f $Payload.narrator_usable_after_render,$Payload.narrator_usability_seconds,$Payload.narrator_reply))
    $rows.Add(('Offloading observation: {0}' -f $Payload.offload_observation))
    $rows.Add('')
    $rows.Add('## Method notes')
    $rows.Add('')
    $rows.Add('- The dedicated adapter counter is the whole GPU, including the desktop baseline; per-process counters attribute Ollama and Dungeon ComfyUI allocations. Ollama `/api/ps` supplies the model-specific `size_vram`, model size and context length.')
    $rows.Add('- No other LLM was requested or loaded. The narrator request uses only `qwen3.5:4b`, `num_ctx=65536`, `think=false` and small output limits.')
    $rows.Add('- Outputs use the existing environment prompt and the existing SDXL-Lightning 4-step workflow. This test changes no model, runtime, prompt, architecture, or story code.')
    $rows.Add('- Renderer and Ollama server started by this script were stopped. No unrelated process was terminated.')
    $rows.Add('')
    if ($Payload.cleanup_errors.Count) { $rows.Add(('Cleanup notes: {0}' -f ($Payload.cleanup_errors -join '; '))); $rows.Add('') }
    $rows | Set-Content -LiteralPath $script:reportPath -Encoding UTF8
}

try {
    # Confirm the only eligible AI runtime is clean before creating the baseline.
    $backendState = & $backendScript status | ConvertFrom-Json
    if ($backendState.Owned -or $backendState.Ready) { throw 'Dungeon ComfyUI was already active; refusing to adopt or stop a process not started by this measurement.' }
    try { $null = Invoke-RestMethod -Uri ($ollamaUrl + '/api/ps') -TimeoutSec 2; throw 'Ollama endpoint was already active; refusing to inspect or alter a pre-existing server.' }
    catch { if ($_.Exception.Message -like 'Ollama endpoint was already active*') { throw }; if ($_.Exception.Response) { throw 'Ollama responded with an unexpected API error before baseline.' } }

    $baselineProcesses = @(Get-Process | Where-Object { $_.ProcessName -match '^(ollama|ollama_llama_server)$' })
    if ($baselineProcesses.Count) { throw ('Ollama process exists although the API is offline; refusing to alter it. PIDs: ' + (($baselineProcesses.Id) -join ',')) }
    $baselineComfy = @(Get-Process -Name python -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($runtime, [StringComparison]::OrdinalIgnoreCase) })
    if ($baselineComfy.Count) { throw 'A private ComfyUI Python process exists without a valid lifecycle state file; refusing to alter it.' }

    # Start one continuous elevated WDDM sampler for every stage.
    $samplerJob = Start-Job -Name 'Dungeon-GPU-Coexistence-Sampler' -ArgumentList $samplePath,$adapterLuid,$CounterIntervalMilliseconds -ScriptBlock {
        param($Path,$Luid,$Interval)
        $ErrorActionPreference = 'Continue'
        while ($true) {
            try {
                $counters = (Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage','\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
                $device = @($counters | Where-Object { $_.Path -match '(?i)GPU Adapter Memory' -and $_.Path -match [regex]::Escape($Luid) } | Select-Object -Last 1)
                $procs = @($counters | Where-Object { $_.Path -match '(?i)GPU Process Memory' -and $_.Path -match [regex]::Escape($Luid) } | ForEach-Object {
                    $m = [regex]::Match($_.Path,'(?i)pid_(\d+)_')
                    if ($m.Success) { [pscustomobject]@{ pid = [int]$m.Groups[1].Value; bytes = [long][Math]::Max([double]0,[double]$_.CookedValue) } }
                })
                if ($device.Count) {
                    [pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); adapter_bytes = [long][Math]::Max([double]0,[double]$device[0].CookedValue); processes = $procs } | ConvertTo-Json -Depth 5 -Compress | Add-Content -LiteralPath $Path -Encoding UTF8
                }
            } catch {
                [pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); error = $_.Exception.Message } | ConvertTo-Json -Compress | Add-Content -LiteralPath $Path -Encoding UTF8
            }
            Start-Sleep -Milliseconds $Interval
        }
    }
    Start-Sleep -Seconds 2

    Add-PhaseMarker 'clean baseline' 'start'; Start-Sleep -Seconds 5; Add-PhaseMarker 'clean baseline' 'end'

    # Start only Dungeon's configured local Ollama listener; do not pull models.
    $null = New-Item -ItemType Directory -Force -Path $logsPath
    $serverProcess = Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden -PassThru -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr
    $serverStartedByTest = $true
    Wait-OllamaReady
    $residentBefore = Invoke-RestMethod -Uri ($ollamaUrl + '/api/ps') -TimeoutSec 5
    if (@($residentBefore.models).Count -gt 0) { throw ('Unexpected model resident after starting the local server; no model was loaded by this test: ' + ((@($residentBefore.models | ForEach-Object name)) -join ', ')) }
    $showBody = @{ model = $model } | ConvertTo-Json -Compress
    $null = Invoke-RestMethod -Uri ($ollamaUrl + '/api/show') -Method Post -ContentType 'application/json' -Body $showBody -TimeoutSec 30

    Add-PhaseMarker 'narrator load' 'start'
    $loadWatch = [Diagnostics.Stopwatch]::StartNew()
    $loadResponse = Invoke-Narrator 'Reply with exactly READY.' 4 '30m'
    $loadWatch.Stop()
    $loadTimes.narrator_seconds = [Math]::Round($loadWatch.Elapsed.TotalSeconds,3)
    $loadTimes.narrator_ollama_load_seconds = if ($loadResponse.load_duration) { [Math]::Round(([double]$loadResponse.load_duration / 1e9),3) } else { $null }
    Add-PhaseMarker 'narrator load' 'end'
    $narratorResidentInfo = Get-ResidentModel
    if (-not $narratorResidentInfo) { throw 'qwen3.5:4b did not remain resident after its load request.' }
    if ($narratorResidentInfo.context_length -ne $context) { throw ('Expected narrator context 65536, Ollama reports ' + $narratorResidentInfo.context_length) }
    $narratorRootPid = [int]$serverProcess.Id
    $narratorPids = @(Get-ProcessTreeIds $narratorRootPid)
    Add-PhaseMarker 'narrator only idle' 'start'; Start-Sleep -Seconds 5; Add-PhaseMarker 'narrator only idle' 'end'

    # Evict only the test's target narrator model for the isolated image-only stage.
    Add-PhaseMarker 'narrator unload for image-only stage' 'start'
    $null = Invoke-Narrator '' 1 '0'
    Add-PhaseMarker 'narrator unload for image-only stage' 'end'
    $afterUnload = Invoke-RestMethod -Uri ($ollamaUrl + '/api/ps') -TimeoutSec 5
    if (@($afterUnload.models).Count -ne 0) { throw 'A model remained resident after unloading the only model loaded by this test; stopping before image-only stage.' }

    # Image backend process, before checkpoint load.
    Add-PhaseMarker 'image-only backend startup' 'start'
    $startupWatch = [Diagnostics.Stopwatch]::StartNew()
    $imageStartedByTest = $true
    $startJson = & $backendScript start -Port 18189 -ReadyTimeoutSeconds 120
    $startupWatch.Stop()
    $comfyInfo = $startJson | ConvertFrom-Json
    $loadTimes.image_backend_start_seconds = [Math]::Round($startupWatch.Elapsed.TotalSeconds,3)
    $comfyRootPids.Add([int]$comfyInfo.ProcessId)
    Add-PhaseMarker 'image-only backend startup' 'end'
    Add-PhaseMarker 'image-only backend before SDXL load' 'start'; Start-Sleep -Seconds 4; Add-PhaseMarker 'image-only backend before SDXL load' 'end'

    # The first render is the model load/warm-up. A second one measures steady state.
    Add-PhaseMarker 'image-only model load warm render' 'start'
    $imageWarmup = Invoke-Render 'image-only-model-load'
    $runs.Add($imageWarmup)
    foreach ($id in (Get-ProcessTreeIds ([int]$comfyInfo.ProcessId))) { if (-not $comfyRootPids.Contains([int]$id)) { $comfyRootPids.Add([int]$id) } }
    Add-PhaseMarker 'image-only model load warm render' 'end'
    Add-PhaseMarker 'image-only loaded idle' 'start'; Start-Sleep -Seconds 4; Add-PhaseMarker 'image-only loaded idle' 'end'
    $imageOnlyResidentInfo = Get-ResidentModel
    if ($imageOnlyResidentInfo) { throw 'Unexpected narrator residency appeared during image-only stage.' }
    Add-PhaseMarker 'image-only measured render' 'start'
    $imageOnlyRun = Invoke-Render 'image-only-measured'
    $runs.Add($imageOnlyRun)
    Add-PhaseMarker 'image-only measured render' 'end'

    # Cleanly stop only the ComfyUI process started above, and confirm its allocation returns.
    $stopImage = & $backendScript stop | ConvertFrom-Json
    $imageStartedByTest = $false
    Add-PhaseMarker 'image-only after backend shutdown' 'start'; Start-Sleep -Seconds 5; Add-PhaseMarker 'image-only after backend shutdown' 'end'

    # Restore qwen at the exact 64K setting, then start ComfyUI while it is resident.
    Add-PhaseMarker 'narrator reload before coexist' 'start'
    $reloadWatch = [Diagnostics.Stopwatch]::StartNew()
    $reloadResponse = Invoke-Narrator 'Reply with exactly READY.' 4 '30m'
    $reloadWatch.Stop()
    $loadTimes.narrator_reload_seconds = [Math]::Round($reloadWatch.Elapsed.TotalSeconds,3)
    Add-PhaseMarker 'narrator reload before coexist' 'end'
    $narratorResidentInfo = Get-ResidentModel
    if (-not $narratorResidentInfo -or $narratorResidentInfo.context_length -ne $context) { throw 'Narrator did not restore at context 65536 before the coexistence stage.' }
    $narratorPids = @(Get-ProcessTreeIds $narratorRootPid)
    Add-PhaseMarker 'coexist backend startup' 'start'
    $coStartWatch = [Diagnostics.Stopwatch]::StartNew()
    $imageStartedByTest = $true
    $coStartJson = & $backendScript start -Port 18189 -ReadyTimeoutSeconds 120
    $coStartWatch.Stop()
    $coComfyInfo = $coStartJson | ConvertFrom-Json
    $loadTimes.coexist_backend_start_seconds = [Math]::Round($coStartWatch.Elapsed.TotalSeconds,3)
    if (-not $comfyRootPids.Contains([int]$coComfyInfo.ProcessId)) { $comfyRootPids.Add([int]$coComfyInfo.ProcessId) }
    Add-PhaseMarker 'coexist backend startup' 'end'
    Add-PhaseMarker 'coexist before SDXL load' 'start'; Start-Sleep -Seconds 4; Add-PhaseMarker 'coexist before SDXL load' 'end'
    $coexistingNarratorBefore = Get-ResidentModel

    Add-PhaseMarker 'coexist render' 'start'
    $coexistRun = Invoke-Render 'qwen-plus-sdxl-render'
    $runs.Add($coexistRun)
    Add-PhaseMarker 'coexist render' 'end'
    $coexistPids = @(Get-ProcessTreeIds ([int]$coComfyInfo.ProcessId))
    foreach ($id in $coexistPids) { if (-not $comfyRootPids.Contains([int]$id)) { $comfyRootPids.Add([int]$id) } }
    $narratorAfterCoexist = Get-ResidentModel
    $psAfter = Invoke-RestMethod -Uri ($ollamaUrl + '/api/ps') -TimeoutSec 5
    $offloadConclusion = if ($narratorAfterCoexist -and $narratorAfterCoexist.context_length -eq $context -and $narratorAfterCoexist.size_vram_bytes -ge $coexistingNarratorBefore.size_vram_bytes) { 'No post-render narrator offload/eviction detected: qwen remained listed at 65,536 context and its reported VRAM allocation did not fall.' } elseif (-not $narratorAfterCoexist) { 'Narrator was no longer resident after render (evicted or unloaded); see post-render usability probe and reload timing.' } else { 'Narrator remained listed, but reported VRAM/context changed; see exact Ollama /api/ps values.' }

    Add-PhaseMarker 'narrator usability after coexist' 'start'
    $usableWatch = [Diagnostics.Stopwatch]::StartNew()
    $usableResponse = Invoke-Narrator 'Reply with exactly READY.' 8 '30m'
    $usableWatch.Stop()
    $narratorUsabilitySeconds = [Math]::Round($usableWatch.Elapsed.TotalSeconds,3)
    $narratorUsabilityText = ([string]$usableResponse.response).Trim()
    $narratorUsable = $narratorUsabilityText -match 'READY'
    Add-PhaseMarker 'narrator usability after coexist' 'end'
    if (-not $narratorUsable) { throw ('Narrator usability probe did not return READY. Response: ' + $narratorUsabilityText) }

    # Shutdown image first; qwen stays resident during this return measurement.
    $stopCoexistImage = & $backendScript stop | ConvertFrom-Json
    $imageStartedByTest = $false
    Add-PhaseMarker 'after coexist image shutdown' 'start'; Start-Sleep -Seconds 5; Add-PhaseMarker 'after coexist image shutdown' 'end'
    $narratorAfterImageStop = Get-ResidentModel

    # Then unload qwen and stop only the Ollama server this script started.
    Add-PhaseMarker 'narrator shutdown' 'start'
    $null = Invoke-Narrator '' 1 '0'
    $psAfterUnload = Invoke-RestMethod -Uri ($ollamaUrl + '/api/ps') -TimeoutSec 5
    if (@($psAfterUnload.models).Count -ne 0) { throw 'A model remained resident after narrator unload; will not stop the Ollama server with a resident model.' }
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -ErrorAction Stop; $serverProcess.WaitForExit(10000) }
    $serverStartedByTest = $false
    Add-PhaseMarker 'narrator shutdown' 'end'
    Add-PhaseMarker 'final baseline return' 'start'; Start-Sleep -Seconds 5; Add-PhaseMarker 'final baseline return' 'end'
}
catch {
    $cleanupErrors.Add(('Test error: ' + $_.Exception.Message))
    throw
}
finally {
    if ($imageStartedByTest) {
        try { $null = & $backendScript stop | ConvertFrom-Json; $imageStartedByTest = $false }
        catch { $cleanupErrors.Add(('ComfyUI cleanup: ' + $_.Exception.Message)) }
    }
    if ($serverStartedByTest) {
        try {
            try {
                $residentForCleanup = Invoke-RestMethod -Uri ($ollamaUrl + '/api/ps') -TimeoutSec 3
                if (@($residentForCleanup.models | Where-Object { $_.name -eq $model }).Count) { $null = Invoke-Narrator '' 1 '0' }
            } catch { }
            if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -ErrorAction SilentlyContinue; $serverProcess.WaitForExit(10000) }
            $serverStartedByTest = $false
        } catch { $cleanupErrors.Add(('Ollama cleanup: ' + $_.Exception.Message)) }
    }
    if ($samplerJob) {
        Stop-Job -Job $samplerJob -ErrorAction SilentlyContinue
        Remove-Job -Job $samplerJob -Force -ErrorAction SilentlyContinue
    }
}

$sampleLines = @(Get-Content -LiteralPath $samplePath -ErrorAction SilentlyContinue)
$samples = @($sampleLines | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.adapter_bytes })
$states = [Collections.Generic.List[object]]::new()
function Add-State([string]$Name,[string]$Phase,$NarratorInfo,$RenderSeconds,[string]$Result) {
    $stats = Get-PhaseStats $Phase
    $states.Add([pscustomobject]@{
        name=$Name; narrator_vram_gib=if($NarratorInfo){$NarratorInfo.vram_gib}else{0.0}
        image_process_peak_gib=if($stats){$stats.image_process_peak_gib}else{$null}
        total_dedicated_gib=if($stats){$stats.adapter_after_gib}else{$null}
        peak_dedicated_gib=if($stats){$stats.adapter_peak_gib}else{$null}
        render_seconds=$RenderSeconds; result=$Result; details=$stats
    })
}
Add-State 'Clean baseline' 'clean baseline' $null $null 'measured'
Add-State 'Narrator only (qwen3.5:4b, 65,536)' 'narrator only idle' $narratorResidentInfo $null $(if($narratorResidentInfo){'resident'}else{'failed'})
Add-State 'Image backend started, checkpoint not loaded' 'image-only backend before SDXL load' $null $null 'ready'
Add-State 'Image only, model load + first render' 'image-only model load warm render' $null $(if($imageWarmup){$imageWarmup.elapsed_seconds}else{$null}) $(if($imageWarmup.success){'success'}else{'failure'})
Add-State 'Image only, SDXL loaded and idle' 'image-only loaded idle' $null $null 'ready after warm render'
Add-State 'Image only, warm 960x540 render' 'image-only measured render' $null $(if($imageOnlyRun){$imageOnlyRun.elapsed_seconds}else{$null}) $(if($imageOnlyRun.success){'success'}else{'failure'})
Add-State 'Coexist, backend started before SDXL load' 'coexist before SDXL load' $coexistingNarratorBefore $null 'qwen resident'
Add-State 'Coexist, 960x540 render' 'coexist render' $narratorAfterCoexist $(if($coexistRun){$coexistRun.elapsed_seconds}else{$null}) $(if($coexistRun.success){'success'}else{'failure'})
Add-State 'After renderer shutdown, narrator retained' 'after coexist image shutdown' $narratorAfterImageStop $null $(if($narratorAfterImageStop){'qwen resident'}else{'not resident'})
Add-State 'After narrator shutdown' 'final baseline return' $null $null 'measured'

$finalStats = Get-PhaseStats 'final baseline return'
$payload = [pscustomobject]@{
    completed_utc=[DateTime]::UtcNow.ToString('o')
    gpu=[pscustomobject]@{name=$adapter.Name;capacity_gib=[Math]::Round(($adapter.Capacity/1GB),3);luid=$adapterLuid}
    sample_interval_ms=$CounterIntervalMilliseconds
    method='Windows WDDM GPU Adapter Memory and GPU Process Memory dedicated usage counters; same DXGI LUID throughout.'
    cold_image_backend_start_seconds=$loadTimes.image_backend_start_seconds
    coexist_image_backend_start_seconds=$loadTimes.coexist_backend_start_seconds
    narrator_load=$loadTimes
    narrator_only=$narratorResidentInfo
    narrator_before_coexist=$coexistingNarratorBefore
    narrator_after_coexist=$narratorAfterCoexist
    narrator_after_image_shutdown=$narratorAfterImageStop
    narrator_usable_after_render=$narratorUsable
    narrator_usability_seconds=$narratorUsabilitySeconds
    narrator_reply=$narratorUsabilityText
    offload_observation=$offloadConclusion
    runs=@($runs.ToArray())
    states=@($states.ToArray())
    final_baseline=$finalStats
    cleanup_errors=@($cleanupErrors.ToArray())
    samples_path=$samplePath
}
Write-ResultFiles $payload
$finalizer = Join-Path $PSScriptRoot 'finalize-gpu-coexistence-report.py'
$python = Join-Path $runtime 'python/python.exe'
& $python $finalizer
if ($LASTEXITCODE -ne 0) { throw 'Final report generation failed.' }
$finalPayload = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
$finalPayload | ConvertTo-Json -Depth 12
Write-Output ('Report: ' + $reportPath)
