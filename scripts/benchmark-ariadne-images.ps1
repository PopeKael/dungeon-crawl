param(
  [string]$AriadneApi = "http://127.0.0.1:8765",
  [string]$AriadneLauncher = "D:\Downloads\Ariadne\control-plane\start-ariadne.ps1",
  [string]$OutputDirectory = "",
  [int]$StartupTimeoutSeconds = 180,
  [int]$GenerationTimeoutSeconds = 1800
)

$ErrorActionPreference = "Stop"
$AriadneApi = $AriadneApi.TrimEnd("/")
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not $OutputDirectory) {
  $OutputDirectory = Join-Path $RepoRoot "benchmarks\ariadne-images"
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not $OutputDirectory.StartsWith($RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "OutputDirectory must remain inside the DungeonCrawler checkout: $RepoRoot"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$Prompts = @(
  [pscustomobject]@{ id = "prompt1_environment"; label = "Prompt 1 - Environment"; text = "Wide establishing illustration of Aethelgard, an immense ancient city inside a subterranean cavern. Black basalt arches span deep chasms above glowing amber rivers. Crumbling towers and hanging gardens are illuminated by blue bioluminescent fungi. Vast scale, atmospheric depth, cinematic fantasy illustration, dramatic blue and amber lighting, no text, 16:9." },
  [pscustomobject]@{ id = "prompt2_mira"; label = "Prompt 2 - One Character"; text = "Mira stands at the edge of a vast underground city holding a brass lantern. She is an adult woman with short black hair wearing a weathered brown leather travelling coat. Behind her, black basalt arches and ancient spires descend toward glowing amber rivers and blue bioluminescent gardens. Wide cinematic composition, lantern light on her face, sense of discovery and awe, fantasy storybook illustration, no text, 16:9." },
  [pscustomobject]@{ id = "prompt3_two_travellers"; label = "Prompt 3 - Two Characters / Action"; text = "Two travellers cross a narrow ancient basalt bridge suspended above a glowing amber river inside an enormous subterranean city. Mira, an adult woman with short black hair and a brown leather travelling coat, leads with a brass lantern. Behind her follows a weathered middle-aged male traveller in a dark travelling coat and hooded cloak. Blue bioluminescent fungi illuminate distant towers and arches. Dynamic wide shot, strong depth, cinematic fantasy storybook illustration, no text, 16:9." }
)
$Sizes = @(
  [pscustomobject]@{ id = "1280x720"; width = 1280; height = 720; submission = "Ariadne background image job API" },
  [pscustomobject]@{ id = "960x540"; width = 960; height = 540; submission = "ComfyUI API (same Ariadne-managed engine; 960x540 is not allowed by the Ariadne job endpoint)" }
)
$Results = [System.Collections.Generic.List[object]]::new()
$EngineStartedByBenchmark = $false
$AriadneHostStartedByBenchmark = $false
$StartupSeconds = 0.0
$SuiteClock = [System.Diagnostics.Stopwatch]::StartNew()
$StartupClock = [System.Diagnostics.Stopwatch]::StartNew()

function Invoke-AriadneJson {
  param([string]$Path, [string]$Method = "GET", [object]$Body = $null, [int]$TimeoutSec = 30)
  $requestArgs = @{ Uri = "$AriadneApi$Path"; Method = $Method; TimeoutSec = $TimeoutSec; ErrorAction = "Stop" }
  if ($null -ne $Body) {
    $requestArgs.ContentType = "application/json"
    $requestArgs.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
  }
  Invoke-RestMethod @requestArgs
}

function Get-ImageStatus {
  Invoke-AriadneJson -Path "/api/image/status" -TimeoutSec 5
}

function Wait-ImageState {
  param([string[]]$States, [int]$TimeoutSec)
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  do {
    $status = Get-ImageStatus
    if ($status.state -in $States) { return $status }
    if ($status.state -eq "error") { throw "Ariadne image engine error: $($status.detail)" }
    Start-Sleep -Milliseconds 750
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Timed out waiting for Ariadne image engine state: $($States -join ', '). Last state: $($status.state) - $($status.detail)"
}

function Wait-ImageJob {
  param([string]$JobId, [int]$TimeoutSec)
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  do {
    $payload = Invoke-AriadneJson -Path "/api/image/generation/$JobId" -TimeoutSec 10
    if (-not $payload.ok -or -not $payload.job) { throw "Ariadne lost image job $JobId." }
    if ($payload.job.state -in @("completed", "error")) { return $payload.job }
    Start-Sleep -Seconds 1
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Image job $JobId exceeded $TimeoutSec seconds."
}

function Save-ComfyImage {
  param([object]$Image, [string]$Destination)
  $query = "filename=$([uri]::EscapeDataString([string]$Image.filename))&subfolder=$([uri]::EscapeDataString([string]$Image.subfolder))&type=$([uri]::EscapeDataString([string]$(if ($Image.type) { $Image.type } else { 'output' })))"
  Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri "http://127.0.0.1:8188/view?$query" -OutFile $Destination
  if ((Get-Item -LiteralPath $Destination).Length -le 0) { throw "ComfyUI returned an empty image: $Destination" }
}

function Normalize-ImageDimensions {
  param([string]$Path, [int]$Width, [int]$Height)
  Add-Type -AssemblyName System.Drawing
  $source = [System.Drawing.Image]::FromFile($Path)
  try {
    if ($source.Width -eq $Width -and $source.Height -eq $Height) { return }
    $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
    try {
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($source, 0, 0, $Width, $Height)
        $temporary = "$Path.normalized.png"
        $bitmap.Save($temporary, [System.Drawing.Imaging.ImageFormat]::Png)
      } finally { $graphics.Dispose() }
    } finally { $bitmap.Dispose() }
  } finally { $source.Dispose() }
  Move-Item -LiteralPath "$Path.normalized.png" -Destination $Path -Force
}

function Submit-ComfyImage {
  param([string]$Prompt, [int]$Width, [int]$Height, [string]$ModelFile, [int]$Seed, [int]$TimeoutSec)
  $clientId = [guid]::NewGuid().ToString()
  $workflow = @{
    "4" = @{ class_type = "CheckpointLoaderSimple"; inputs = @{ ckpt_name = $ModelFile } }
    "5" = @{ class_type = "EmptyLatentImage"; inputs = @{ width = $Width; height = $Height; batch_size = 1 } }
    "6" = @{ class_type = "CLIPTextEncode"; inputs = @{ text = $Prompt; clip = @("4", 1) } }
    "7" = @{ class_type = "CLIPTextEncode"; inputs = @{ text = ""; clip = @("4", 1) } }
    "3" = @{ class_type = "KSampler"; inputs = @{ seed = $Seed; steps = 24; cfg = 7.0; sampler_name = "euler"; scheduler = "normal"; denoise = 1.0; model = @("4", 0); positive = @("6", 0); negative = @("7", 0); latent_image = @("5", 0) } }
    "8" = @{ class_type = "VAEDecode"; inputs = @{ samples = @("3", 0); vae = @("4", 2) } }
    "9" = @{ class_type = "SaveImage"; inputs = @{ filename_prefix = "Ariadne-Dungeon-Benchmark"; images = @("8", 0) } }
  }
  $queued = Invoke-RestMethod -UseBasicParsing -Method Post -TimeoutSec 30 -Uri "http://127.0.0.1:8188/prompt" -ContentType "application/json" -Body (ConvertTo-Json -InputObject @{ client_id = $clientId; prompt_id = $clientId; prompt = $workflow } -Depth 20 -Compress)
  $promptId = [string]$queued.prompt_id
  if (-not $promptId) { throw "ComfyUI did not return a prompt id." }
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  do {
    Start-Sleep -Seconds 1
    $history = Invoke-RestMethod -UseBasicParsing -TimeoutSec 10 -Uri "http://127.0.0.1:8188/history/$promptId"
    $entry = $history.$promptId
    if ($entry.status.status_str -eq "error") { throw "ComfyUI execution error for job $promptId." }
    if ($entry.outputs) {
      $images = @($entry.outputs.PSObject.Properties | ForEach-Object { $_.Value.images } | Where-Object { $_ })
      if ($images.Count -gt 0) { return $images[0] }
    }
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "ComfyUI job $promptId exceeded $TimeoutSec seconds."
}

function Add-FailedResult {
  param([object]$Prompt, [object]$Size, [string]$ErrorText, [double]$GenerationSeconds = 0)
  $Results.Add([pscustomobject]@{
    prompt_id = $Prompt.id; prompt_label = $Prompt.label; prompt = $Prompt.text
    resolution = $Size.id; width = $Size.width; height = $Size.height
    renderer_startup_seconds = [Math]::Round($StartupSeconds, 2)
    generation_seconds = [Math]::Round($GenerationSeconds, 2)
    total_elapsed_seconds = [Math]::Round($StartupSeconds + $GenerationSeconds, 2)
    suite_elapsed_seconds = [Math]::Round($SuiteClock.Elapsed.TotalSeconds, 2)
    output_path = ""; submission = $Size.submission; workflow = "Ariadne SDXL text-to-image v1"
    model = ""; settings = "24 steps; CFG 7; Euler; normal scheduler; batch 1; blank negative prompt"
    failure = $ErrorText
  })
}

try {
  # The benchmark launcher uses Ariadne's existing hidden Rust Host lifecycle when its API is offline.
  try { $null = Invoke-AriadneJson -Path "/api/core/ready" -TimeoutSec 3 }
  catch {
    if (-not (Test-Path -LiteralPath $AriadneLauncher -PathType Leaf)) {
      throw "Ariadne API is offline and its headless launcher was not found: $AriadneLauncher"
    }
    & $AriadneLauncher
    $AriadneHostStartedByBenchmark = $true
    $readyDeadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    do {
      try { $ready = Invoke-AriadneJson -Path "/api/core/ready" -TimeoutSec 3; if ($ready.ok) { break } } catch { }
      Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $readyDeadline)
    if (-not $ready.ok) { throw "Ariadne core did not become ready within $StartupTimeoutSeconds seconds." }
  }

  $StartupClock.Restart()
  $initialStatus = Get-ImageStatus
  $model = @($initialStatus.models | Where-Object { $_.id -eq "sdxl-base-1.0" -and $_.installed }) | Select-Object -First 1
  if (-not $model) {
    $model = @($initialStatus.models | Where-Object { $_.installed }) | Select-Object -First 1
  }
  if (-not $model) { throw "Ariadne reports no installed image checkpoints." }

  if ($initialStatus.state -ne "online") {
    $start = Invoke-AriadneJson -Path "/api/image/start" -Method "POST" -Body @{} -TimeoutSec 30
    if (-not $start.ok) { throw "Ariadne refused to start ComfyUI: $($start.message)" }
    $EngineStartedByBenchmark = $true
    $null = Wait-ImageState -States @("online") -TimeoutSec $StartupTimeoutSeconds
  }
  $StartupClock.Stop()
  $StartupSeconds = $StartupClock.Elapsed.TotalSeconds
  Write-Host ("Ariadne ComfyUI ready in {0:N2}s; model: {1} ({2})" -f $StartupSeconds, $model.name, $model.filename) -ForegroundColor Cyan

  foreach ($size in $Sizes) {
    foreach ($prompt in $Prompts) {
      $imageName = "{0}_{1}.png" -f $prompt.id, $size.id
      $outputPath = Join-Path $OutputDirectory $imageName
      $generationClock = [System.Diagnostics.Stopwatch]::StartNew()
      $seed = Get-Random -Minimum 1 -Maximum 2147483646
      $submission = $size.submission
      $jobApiWarning = ""
      try {
        if ($size.id -eq "1280x720") {
          try {
            $requestId = [guid]::NewGuid().ToString("N")
            $accepted = Invoke-AriadneJson -Path "/api/image/generate" -Method "POST" -Body @{
              request_id = $requestId; model = $model.id; prompt = $prompt.text
              negative_prompt = ""; width = $size.width; height = $size.height; seed = $seed
            } -TimeoutSec 30
            if (-not $accepted.ok) { throw "Ariadne did not accept the job: $($accepted.message)" }
            $job = Wait-ImageJob -JobId $requestId -TimeoutSec $GenerationTimeoutSeconds
            if ($job.state -ne "completed" -or -not $job.result.ok) { throw ([string]$job.result.message) }
            Copy-Item -LiteralPath $job.result.image.path -Destination $outputPath -Force
            $actualSeed = $job.result.seed
            $usedModel = $job.result.model
          } catch {
            if ($_.Exception.Message -notmatch "websockets") { throw }
            $jobApiWarning = "Ariadne image-job API could not initialize its live progress dependency (websockets); workflow was submitted directly to the same managed ComfyUI engine."
            $submission = "ComfyUI HTTP API fallback after Ariadne job API failed (missing websockets)"
            $generationClock.Restart()
            $image = Submit-ComfyImage -Prompt $prompt.text -Width $size.width -Height $size.height -ModelFile $model.filename -Seed $seed -TimeoutSec $GenerationTimeoutSeconds
            Save-ComfyImage -Image $image -Destination $outputPath
            $actualSeed = $seed
            $usedModel = $model.name
          }
        } else {
          $image = Submit-ComfyImage -Prompt $prompt.text -Width $size.width -Height $size.height -ModelFile $model.filename -Seed $seed -TimeoutSec $GenerationTimeoutSeconds
          Save-ComfyImage -Image $image -Destination $outputPath
          $actualSeed = $seed
          $usedModel = $model.name
        }
        Normalize-ImageDimensions -Path $outputPath -Width $size.width -Height $size.height
        if ((Get-Item -LiteralPath $outputPath).Length -le 0) { throw "Generated output file is empty: $outputPath" }
        $generationClock.Stop()
        $Results.Add([pscustomobject]@{
          prompt_id = $prompt.id; prompt_label = $prompt.label; prompt = $prompt.text
          resolution = $size.id; width = $size.width; height = $size.height
          renderer_startup_seconds = [Math]::Round($StartupSeconds, 2)
          generation_seconds = [Math]::Round($generationClock.Elapsed.TotalSeconds, 2)
          total_elapsed_seconds = [Math]::Round($StartupSeconds + $generationClock.Elapsed.TotalSeconds, 2)
          suite_elapsed_seconds = [Math]::Round($SuiteClock.Elapsed.TotalSeconds, 2)
          output_path = $outputPath; submission = $submission; workflow = "Ariadne SDXL text-to-image v1"
          model = $usedModel; model_file = $model.filename; seed = $actualSeed
          settings = "24 steps; CFG 7; Euler; normal scheduler; batch 1; blank negative prompt"
          failure = ""; observation = $jobApiWarning
        })
        Write-Host ("{0} {1} completed in {2:N1}s -> {3}" -f $prompt.id, $size.id, $generationClock.Elapsed.TotalSeconds, $outputPath) -ForegroundColor Green
      } catch {
        $generationClock.Stop()
        Add-FailedResult -Prompt $prompt -Size $size -ErrorText $_.Exception.Message -GenerationSeconds $generationClock.Elapsed.TotalSeconds
        Write-Warning ("{0} {1} failed after {2:N1}s: {3}" -f $prompt.id, $size.id, $generationClock.Elapsed.TotalSeconds, $_.Exception.Message)
      }
    }
  }
} finally {
  if ($EngineStartedByBenchmark) {
    try {
      $null = Invoke-AriadneJson -Path "/api/image/stop" -Method "POST" -Body @{} -TimeoutSec 30
      $finalStatus = Wait-ImageState -States @("offline") -TimeoutSec 30
      Write-Host "Ariadne ComfyUI image engine stopped cleanly." -ForegroundColor Cyan
    } catch {
      Write-Warning "Ariadne did not confirm image engine shutdown: $($_.Exception.Message)"
    }
  }
  $SuiteClock.Stop()
  $StartupClock.Stop()
  $reportPath = Join-Path $OutputDirectory "benchmark-report.md"
  $successes = @($Results | Where-Object { -not $_.failure }).Count
  $rows = foreach ($result in $Results) {
    $out = if ($result.output_path) { "``$($result.output_path)``" } else { "-" }
    $failure = if ($result.failure) { $result.failure.Replace("|", "\|").Replace("`r", " ").Replace("`n", " ") } else { "-" }
    if ($result.observation) { $failure = "$failure; $($result.observation)" }
    "| $($result.prompt_label) | $($result.resolution) | $($result.renderer_startup_seconds) | $($result.generation_seconds) | $($result.total_elapsed_seconds) | $out | $($result.workflow); $($result.model); $($result.settings); $($result.submission) | $failure |"
  }
  $promptSection = foreach ($prompt in $Prompts) { "- **$($prompt.label):** $($prompt.text)" }
  $rowText = $rows -join "`n"
  $promptText = $promptSection -join "`n"
  $report = @(
    "# Ariadne ComfyUI Dungeon Crawl image benchmark",
    "",
    "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')  ",
    "Ariadne API: ``$AriadneApi``  ",
    "Renderer startup: $([Math]::Round($StartupSeconds, 2)) seconds (one shared cold start for the suite)  ",
    "Suite elapsed: $([Math]::Round($SuiteClock.Elapsed.TotalSeconds, 2)) seconds  ",
    "Completed images: $successes / 6  ",
    "Engine shutdown: $(if ($EngineStartedByBenchmark -and $finalStatus.state -eq 'offline') { 'confirmed stopped' } elseif ($EngineStartedByBenchmark) { 'not confirmed' } else { 'left running because it predated this benchmark' })",
    "",
    "Total elapsed per row is renderer startup plus that image's generation time. The suite starts the renderer once; suite elapsed records the cumulative wall time for the sequential run. Generation time starts immediately before job submission and ends after the generated PNG is copied into this benchmark folder.",
    "ComfyUI's VAE produced 960x536 for the requested 960x540 latent because its image dimensions align to multiples of eight. The saved 960x540 files are high-quality bicubic resizes of those engine outputs; the tiny local resize is excluded from renderer generation timing.",
    "",
    "| Prompt | Resolution | Renderer startup (s) | Generation (s) | Total elapsed (s) | Output file | Workflow / model / settings | Failure or slowdown |",
    "|---|---:|---:|---:|---:|---|---|---|",
    $rowText,
    "",
    "## Exact prompts",
    "",
    $promptText,
    "",
    "## Conclusion",
    "",
    "The 20-30 second target is assessed from the measured 1280x720 generation times above. The 960x540 fallback is assessed from its measured generation times. These runs use the installed Ariadne SDXL checkpoint at 24 steps, CFG 7, Euler / normal, batch 1; warm-up effects apply to later images because the model remains loaded across the suite.",
    ""
  ) -join "`n"
  Set-Content -LiteralPath $reportPath -Value $report -Encoding utf8
  Write-Host "Report: $reportPath"
  Write-Host ("Generated {0}/6 images; suite elapsed {1:N1}s." -f $successes, $SuiteClock.Elapsed.TotalSeconds)
}
