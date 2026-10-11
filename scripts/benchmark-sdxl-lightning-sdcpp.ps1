param(
    [ValidateSet('A', 'B', 'C')]
    [string] $Variant = 'A',
    [int] $Runs = 4,
    [int] $Port = 18191
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtime = Join-Path $root 'runtime/sd-cpp-vulkan'
$dist = Join-Path $runtime 'dist'
$serverExe = Join-Path $dist 'sd-server.exe'
$model = Join-Path $root 'runtime/sdxl-lightning/ComfyUI/models/checkpoints/sdxl_lightning_4step.safetensors'
$reportDir = Join-Path $root 'benchmarks/sd-cpp-vulkan'
$imageDir = Join-Path $reportDir 'images'
$prompt = 'Wide establishing illustration of Aethelgard, an immense ancient city inside a subterranean cavern. Black basalt arches span deep chasms above glowing amber rivers. Crumbling towers and hanging gardens are illuminated by blue bioluminescent fungi. Vast scale, atmospheric depth, cinematic fantasy illustration, dramatic blue and amber lighting, no text, 16:9.'
$seed = 982008
$ollamaUrl = 'http://127.0.0.1:11434'
$baseUrl = "http://127.0.0.1:$Port"
$adapter = 'luid_0x00000000_0x0000e32d_phys_0'
$memoryLog = Join-Path $reportDir "$Variant-memory.jsonl"
$stdout = Join-Path $runtime "$Variant-server.stdout.log"
$stderr = Join-Path $runtime "$Variant-server.stderr.log"
$ollamaStdout = Join-Path $runtime 'ollama-serve.stdout.log'
$ollamaStderr = Join-Path $runtime 'ollama-serve.stderr.log'
$server = $null
$ollama = $null
$samples = [System.Collections.Generic.List[object]]::new()
$runRecords = [System.Collections.Generic.List[object]]::new()
$failure = $null
$serverStartedUtc = $null
$readySeconds = $null
$qwenRecord = $null
$runSamplingTimes = @()
$runVaeTimes = @()

New-Item -ItemType Directory -Force -Path $imageDir | Out-Null
Remove-Item -LiteralPath $memoryLog -ErrorAction SilentlyContinue

function Invoke-JsonApi([string] $Uri, [string] $Method = 'GET', $Body = $null, [int] $TimeoutSec = 300) {
    if ($null -eq $Body) {
        return Invoke-RestMethod -Uri $Uri -Method $Method -TimeoutSec $TimeoutSec
    }
    $json = $Body | ConvertTo-Json -Depth 12 -Compress
    return Invoke-RestMethod -Uri $Uri -Method $Method -ContentType 'application/json' -Body $json -TimeoutSec $TimeoutSec
}

function Get-QwenRecord {
    $state = Invoke-JsonApi "$ollamaUrl/api/ps" -TimeoutSec 8
    $modelState = @($state.models | Where-Object { $_.name -eq 'qwen3.5:4b' }) | Select-Object -First 1
    if (-not $modelState -or [int64]$modelState.size_vram -le 0 -or [int]$modelState.context_length -ne 65536) {
        throw 'qwen3.5:4b is not resident at context_length 65536.'
    }
    $others = @($state.models | Where-Object { $_.name -ne 'qwen3.5:4b' })
    if ($others.Count -gt 0) { throw "Unexpected resident Ollama model(s): $($others.name -join ', ')" }
    return $modelState
}

function Confirm-QwenReady {
    $readyBody = @{ model = 'qwen3.5:4b'; prompt = 'Reply exactly READY.'; stream = $false; think = $false; keep_alive = '60m'; options = @{ num_ctx = 65536; num_predict = 8 } }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $answer = Invoke-JsonApi "$ollamaUrl/api/generate" 'POST' $readyBody 180
    $timer.Stop()
    if ($answer.response -notmatch '\bREADY\b') { throw "Narrator readiness response was not READY: $($answer.response)" }
    $resident = Get-QwenRecord
    return [pscustomobject]@{ answer = $answer.response.Trim(); seconds = [math]::Round($timer.Elapsed.TotalSeconds, 3); context = [int]$resident.context_length; size_vram = [int64]$resident.size_vram }
}

function Add-GpuSample([string] $Phase, [int] $ImageIndex = 0) {
    $counters = @(
        "\GPU Adapter Memory($adapter)\Dedicated Usage",
        "\GPU Adapter Memory($adapter)\Shared Usage",
        '\GPU Process Memory(*)\Dedicated Usage',
        '\GPU Process Memory(*)\Shared Usage'
    )
    $entries = @((Get-Counter -Counter $counters -ErrorAction Stop).CounterSamples)
    $serverDedicated = 0L
    $serverShared = 0L
    $adapterDedicated = 0L
    $adapterShared = 0L
    foreach ($entry in $entries) {
        $path = $entry.Path.ToLowerInvariant()
        $bytes = [int64]$entry.CookedValue
        if ($path -match "gpu adapter memory\($adapter\)\\dedicated usage$") { $adapterDedicated = $bytes }
        elseif ($path -match "gpu adapter memory\($adapter\)\\shared usage$") { $adapterShared = $bytes }
        elseif ($server -and $path -match "gpu process memory\(pid_$($server.Id)_") {
            if ($path.EndsWith('\dedicated usage')) { $serverDedicated = $bytes }
            if ($path.EndsWith('\shared usage')) { $serverShared = $bytes }
        }
    }
    $item = [pscustomobject]@{ utc = [DateTime]::UtcNow.ToString('o'); phase = $Phase; run = $ImageIndex; adapter_dedicated_bytes = $adapterDedicated; adapter_shared_bytes = $adapterShared; sdcpp_dedicated_bytes = $serverDedicated; sdcpp_shared_bytes = $serverShared }
    $samples.Add($item)
    $item | ConvertTo-Json -Compress | Add-Content -LiteralPath $memoryLog -Encoding utf8
}

function Get-RunMemory([string] $Phase, [int] $ImageIndex) {
    $subset = @($samples | Where-Object { $_.phase -eq $Phase -and $_.run -eq $ImageIndex })
    if ($subset.Count -eq 0) { return $null }
    return [pscustomobject]@{
        sample_count = $subset.Count
        peak_dedicated_gib = [math]::Round((($subset | Measure-Object adapter_dedicated_bytes -Maximum).Maximum) / 1GB, 3)
        peak_shared_gib = [math]::Round((($subset | Measure-Object adapter_shared_bytes -Maximum).Maximum) / 1GB, 3)
        sdcpp_peak_dedicated_gib = [math]::Round((($subset | Measure-Object sdcpp_dedicated_bytes -Maximum).Maximum) / 1GB, 3)
        sdcpp_peak_shared_gib = [math]::Round((($subset | Measure-Object sdcpp_shared_bytes -Maximum).Maximum) / 1GB, 3)
    }
}

function Read-LogText {
    $parts = @()
    foreach ($file in @($stdout, $stderr)) { if (Test-Path -LiteralPath $file) { $parts += Get-Content -LiteralPath $file -Raw } }
    return ($parts -join "`n")
}

function Get-LogMetrics([string] $Text) {
    $sampling = [regex]::Matches($Text, 'sampling completed, taking ([0-9.]+)s') | ForEach-Object { [double]$_.Groups[1].Value }
    $vae = [regex]::Matches($Text, 'decode_first_stage completed(?:, taking| in) ([0-9.]+)s') | ForEach-Object { [double]$_.Groups[1].Value }
    $tensorLoads = [regex]::Matches($Text, 'loading tensors completed, taking ([0-9.]+)s') | ForEach-Object { [double]$_.Groups[1].Value }
    $params = [regex]::Matches($Text, 'total params memory size = ([0-9.]+)MB \(VRAM ([0-9.]+)MB, RAM ([0-9.]+)MB\)') | ForEach-Object { [pscustomobject]@{ total_mb = [double]$_.Groups[1].Value; vram_mb = [double]$_.Groups[2].Value; ram_mb = [double]$_.Groups[3].Value } }
    $compute = [regex]::Matches($Text, '(?:unet|vae) compute buffer size: ([0-9.]+) MB\((VRAM|RAM)\)') | ForEach-Object { [pscustomobject]@{ mb = [double]$_.Groups[1].Value; backend = $_.Groups[2].Value } }
    return [pscustomobject]@{ sampling_seconds = @($sampling); vae_decode_seconds = @($vae); tensor_load_seconds = @($tensorLoads); parameter_memory = @($params); compute_buffers = @($compute) }
}

function Save-And-CheckPng($Job, [string] $Path) {
    if ($Job.status -ne 'completed' -or -not $Job.result -or @($Job.result.images).Count -eq 0) { throw "Image job did not complete with a PNG: $($Job.error.message)" }
    $encoded = [string]$Job.result.images[0].b64_json
    if ($encoded.StartsWith('data:')) { $encoded = $encoded.Substring($encoded.IndexOf(',') + 1) }
    [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($encoded))
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 24 -or $bytes[0] -ne 137 -or $bytes[1] -ne 80 -or $bytes[2] -ne 78 -or $bytes[3] -ne 71) { throw "Output is not a valid PNG: $Path" }
    $width = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 16))
    $height = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 20))
    Add-Type -AssemblyName System.Drawing
    $rawPath = $null
    if ($width -eq 960 -and $height -eq 576) {
        $rawName = '{0}-engine-960x576.png' -f [IO.Path]::GetFileNameWithoutExtension($Path)
        $rawPath = Join-Path (Split-Path -Parent $Path) $rawName
        Move-Item -LiteralPath $Path -Destination $rawPath -Force
        $source = [System.Drawing.Bitmap]::FromFile($rawPath)
        try {
            $canvas = New-Object System.Drawing.Bitmap(960, 536)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($canvas)
                try {
                    $graphics.DrawImage($source, [System.Drawing.Rectangle]::new(0, 0, 960, 536), [System.Drawing.Rectangle]::new(0, 20, 960, 536), [System.Drawing.GraphicsUnit]::Pixel)
                    $canvas.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
                } finally { $graphics.Dispose() }
            } finally { $canvas.Dispose() }
        } finally { $source.Dispose() }
    }
    $decoded = [System.Drawing.Bitmap]::FromFile($Path)
    try { $finalWidth = $decoded.Width; $finalHeight = $decoded.Height } finally { $decoded.Dispose() }
    if ($finalWidth -ne 960 -or $finalHeight -ne 536) { throw "Expected normalized 960x536 PNG, got ${finalWidth}x${finalHeight}." }
    return [pscustomobject]@{ path = $Path; raw_engine_path = $rawPath; bytes = (Get-Item -LiteralPath $Path).Length; width = $finalWidth; height = $finalHeight; engine_width = $width; engine_height = $height; normalization = if ($rawPath) { 'center crop 20px from top and bottom; generated canvas was aligned to 960x576 by stable-diffusion.cpp' } else { 'none' }; valid_png = $true }
}

try {
    if (-not (Test-Path -LiteralPath $serverExe) -or -not (Test-Path -LiteralPath $model)) { throw 'The staged server binary or SDXL-Lightning checkpoint is missing.' }
    try { $null = Invoke-JsonApi "$ollamaUrl/api/ps" -TimeoutSec 3 }
    catch {
        $ollamaExe = (Get-Command ollama.exe -ErrorAction Stop).Source
        $ollama = Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden -PassThru -RedirectStandardOutput $ollamaStdout -RedirectStandardError $ollamaStderr
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        do {
            Start-Sleep -Milliseconds 500
            try { $null = Invoke-JsonApi "$ollamaUrl/api/ps" -TimeoutSec 3; break } catch { }
            $ollama.Refresh()
            if ($ollama.HasExited) { throw "Ollama exited while starting; inspect $ollamaStderr" }
        } while ([DateTime]::UtcNow -lt $deadline)
    }

    $ollamaState = Invoke-JsonApi "$ollamaUrl/api/ps" -TimeoutSec 8
    $otherModels = @($ollamaState.models | Where-Object { $_.name -ne 'qwen3.5:4b' })
    if ($otherModels.Count -gt 0) { throw "Refusing to proceed while other Ollama model(s) are resident: $($otherModels.name -join ', ')" }
    $qwenRecord = @($ollamaState.models | Where-Object { $_.name -eq 'qwen3.5:4b' }) | Select-Object -First 1
    if (-not $qwenRecord) { $null = Confirm-QwenReady }
    $qwenRecord = Get-QwenRecord
    Add-GpuSample 'qwen-baseline'

    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { throw "Port $Port is occupied; refusing to control an existing listener." }
    $serverArgs = @('--listen-ip','127.0.0.1','--listen-port',"$Port",'--model',$model,'--backend','vulkan0','--max-vram','6.0','--width','960','--height','536','--steps','4','--cfg-scale','1.0','--sampling-method','euler','--scheduler','sgm_uniform','--seed',"$seed",'--log-level','verbose')
    if ($Variant -in @('B','C')) { $serverArgs += '--offload-to-cpu' }
    if ($Variant -eq 'C') { $serverArgs += @('--vae-tiling','--vae-tile-size','256x256') }
    $serverStartedUtc = [DateTime]::UtcNow
    $serverTimer = [Diagnostics.Stopwatch]::StartNew()
    $server = Start-Process -FilePath $serverExe -ArgumentList $serverArgs -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = Get-QwenRecord
    Add-GpuSample 'server-startup'
    $deadline = [DateTime]::UtcNow.AddMinutes(6)
    $capabilities = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        Add-GpuSample 'server-startup'
        try { $capabilities = Invoke-JsonApi "$baseUrl/sdcpp/v1/capabilities" -TimeoutSec 3; break } catch { }
        $server.Refresh()
        if ($server.HasExited) { throw "stable-diffusion.cpp exited during startup; inspect $stdout and $stderr" }
    }
    if (-not $capabilities) { throw 'stable-diffusion.cpp did not become ready within six minutes.' }
    $serverTimer.Stop()
    $readySeconds = [math]::Round($serverTimer.Elapsed.TotalSeconds, 3)
    $runNumber = 0
    while ($runNumber -lt $Runs) {
        $runNumber++
        $logBefore = Read-LogText
        Add-GpuSample 'render' $runNumber
        $body = @{
            prompt = $prompt; negative_prompt = ''; clip_skip = -1; width = 960; height = 536; strength = 1.0; seed = $seed; batch_count = 1
            sample_params = @{ scheduler = 'sgm_uniform'; sample_method = 'euler'; sample_steps = 4; guidance = @{ txt_cfg = 1.0 } }
            vae_tiling_params = @{ enabled = $false; tile_size_w = 256; tile_size_h = 256; target_overlap = 0.5 }
            preview = 'none'; output_format = 'png'; output_compression = 100
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $accepted = Invoke-JsonApi "$baseUrl/sdcpp/v1/img_gen" 'POST' $body 30
        $jobId = [string]$accepted.id
        if (-not $jobId) { throw 'stable-diffusion.cpp did not return a job id.' }
        $job = $null
        do {
            Add-GpuSample 'render' $runNumber
            Start-Sleep -Milliseconds 450
            $job = Invoke-JsonApi "$baseUrl/sdcpp/v1/jobs/$jobId" -TimeoutSec 10
            if ($job.status -eq 'failed') { throw "Run $runNumber failed: $($job.error.message)" }
            if ($job.status -eq 'cancelled') { throw "Run $runNumber was cancelled." }
            $server.Refresh()
            if ($server.HasExited) { throw "stable-diffusion.cpp exited during run $runNumber." }
        } while ($job.status -ne 'completed')
        $timer.Stop()
        Add-GpuSample 'render' $runNumber
        $imagePath = Join-Path $imageDir "$Variant-run-$('{0:d2}' -f $runNumber).png"
        $image = Save-And-CheckPng $job $imagePath
        $logAfter = Read-LogText
        $segment = $logAfter.Substring([math]::Min($logBefore.Length, $logAfter.Length))
        $logMetrics = Get-LogMetrics $segment
        $loadTotal = if (@($logMetrics.tensor_load_seconds).Count) { [math]::Round((@($logMetrics.tensor_load_seconds) | Measure-Object -Sum).Sum,3) } else { 0.0 }
        $sampling = if (@($logMetrics.sampling_seconds).Count) { [double](@($logMetrics.sampling_seconds)[-1]) } else { $null }
        $vaeDecode = if (@($logMetrics.vae_decode_seconds).Count) { [double](@($logMetrics.vae_decode_seconds)[-1]) } else { $null }
        $memory = Get-RunMemory 'render' $runNumber
        $ready = Confirm-QwenReady
        $run = [pscustomobject]@{ run = $runNumber; status = 'success'; total_seconds = [math]::Round($timer.Elapsed.TotalSeconds,3); model_load_tensor_seconds = $loadTotal; sampling_seconds = $sampling; vae_decode_seconds = $vaeDecode; image = $image; memory = $memory; qwen_ready_seconds = $ready.seconds; qwen_context = $ready.context; qwen_size_vram_bytes = $ready.size_vram }
        $runRecords.Add($run)
        $runSamplingTimes += $sampling
        $runVaeTimes += $vaeDecode
        "Run $runNumber/$Runs $Variant total=$($run.total_seconds)s sample=$sampling vae=$vaeDecode peak_dedicated=$($memory.peak_dedicated_gib)GiB peak_shared=$($memory.peak_shared_gib)GiB PNG=$($image.valid_png) Qwen=$($ready.answer)"
    }
} catch {
    $failure = $_.Exception.Message
    Write-Warning $failure
} finally {
    $serverPid = if ($server) { [int]$server.Id } else { $null }
    if ($server -and -not $server.HasExited) {
        $verified = $false
        try {
            $current = Get-Process -Id $server.Id -ErrorAction Stop
            $verified = ($current.Path -and [IO.Path]::GetFullPath($current.Path) -eq [IO.Path]::GetFullPath($serverExe) -and $current.StartTime.ToUniversalTime().Ticks -eq $server.StartTime.ToUniversalTime().Ticks)
        } catch { }
        if ($verified) { Stop-Process -Id $server.Id -Force; $server.WaitForExit() }
    }
    $allLogs = Read-LogText
    $allMetrics = Get-LogMetrics $allLogs
    $paramsMemory = @($allMetrics.parameter_memory | Select-Object -Last 1)
    $computeBuffers = @($allMetrics.compute_buffers)
    $adapterBaseline = @($samples | Where-Object phase -eq 'qwen-baseline' | Select-Object -First 1)
    $summary = [pscustomobject]@{
        created_utc = [DateTime]::UtcNow.ToString('o'); variant = $Variant; version = 'stable-diffusion.cpp master-956-1b0ba10'; commit = '1b0ba10'; port = $Port; server_pid = $serverPid; server_startup_to_ready_seconds = $readySeconds
        command = ('"{0}" {1}' -f $serverExe, ($serverArgs -join ' ')); gpu = 'Vulkan0 AMD Radeon RX 7800 XT; Vulkan driver 26.8.1 (LLPC)'
        model = 'sdxl_lightning_4step.safetensors (existing FP16 full SDXL checkpoint)'; model_path = $model; prompt = $prompt; workflow = @{ width_requested = 960; height_requested = 536; steps = 4; sampler = 'euler'; scheduler = 'sgm_uniform'; cfg = 1.0; seed = $seed; backend = 'vulkan0'; max_vram_gib = 6.0; offload_to_cpu = ($Variant -in @('B','C')); vae_tiling = ($Variant -eq 'C'); vae_tile_size = if ($Variant -eq 'C') { '256x256 pixels' } else { $null } }
        qwen = @{ model = 'qwen3.5:4b'; context = 65536; size_vram_bytes = if ($qwenRecord) { [int64]$qwenRecord.size_vram } else { $null }; ollama_pid = if ($ollama) { $ollama.Id } else { $null }; kept_resident_after_run = [bool]$qwenRecord }
        narrator_free_smoke = @{ path = (Join-Path $imageDir 'image-only-smoke.png'); elapsed_seconds = 17.198; generation_seconds = 16.44; sampling_seconds = 5.12; vae_decode_seconds = 8.59; dedicated_peak_gib = 11.84; shared_peak_gib = 0.673; actual_dimensions = '960x576 (stable-diffusion.cpp aligns SDXL height to a multiple of 64)' }
        memory = @{ adapter_baseline_dedicated_gib = if ($adapterBaseline) { [math]::Round($adapterBaseline.adapter_dedicated_bytes / 1GB,3) } else { $null }; adapter_baseline_shared_gib = if ($adapterBaseline) { [math]::Round($adapterBaseline.adapter_shared_bytes / 1GB,3) } else { $null }; samples = $samples }
        model_parameters_reported = $paramsMemory; compute_buffers_reported = $computeBuffers; runs = $runRecords; failure = $failure; ollama_started_for_test = [bool]$ollama; ollama_left_running = [bool]$ollama
    }
    $jsonPath = Join-Path $reportDir "$Variant-report.json"
    $summary | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $jsonPath -Encoding utf8
}

if ($failure) { exit 1 }
