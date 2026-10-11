param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('A','B','C','D','E')]
    [string] $Variant
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtime = Join-Path $root 'runtime/sdxl-lightning'
$backend = Join-Path $PSScriptRoot 'dungeon-image-backend.ps1'
$runner = Join-Path $PSScriptRoot 'run-sdxl-coexistence-variant.py'
$python = Join-Path $runtime 'python/python.exe'
$ollamaUrl = 'http://127.0.0.1:11434'
$comfyUrl = 'http://127.0.0.1:18189'
$model = 'qwen3.5:4b'
$context = 65536
$outDir = Join-Path $root 'benchmarks/sdxl-lightning/coexistence-optimization'
$samplesPath = Join-Path $outDir ("gpu-{0}.jsonl" -f $Variant)
$resultPath = Join-Path $outDir ("variant-{0}.json" -f $Variant)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Remove-Item -LiteralPath $samplesPath -Force -ErrorAction SilentlyContinue

function Get-ResidentNarrator {
    $state = Invoke-RestMethod -Uri ($ollamaUrl + '/api/ps') -TimeoutSec 5
    $items = @($state.models | Where-Object { $_.name -eq $model })
    if ($items.Count -ne 1) { return $null }
    $m = $items[0]
    [pscustomobject]@{
        name = $m.name; context = [int]$m.context_length
        size_vram_bytes = [long]$m.size_vram
        vram_gib = [Math]::Round(([double]$m.size_vram / 1GB), 3)
    }
}

function Get-ProcessTreeIds([int] $RootPid) {
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId)
    $found = [Collections.Generic.HashSet[int]]::new()
    $null = $found.Add($RootPid)
    do {
        $changed = $false
        foreach ($process in $all) {
            if ($found.Contains([int]$process.ParentProcessId) -and $found.Add([int]$process.ProcessId)) { $changed = $true }
        }
    } while ($changed)
    @($found)
}

function Invoke-Job([int]$Seed,[string]$Label) {
    $prefix = "benchmark-sdxl-lightning/coexistence-optimization/$Variant/$Label"
    $runnerArgs = @('-s','-u',$runner,'--seed',"$Seed",'--prefix',$prefix)
    if ($Variant -in @('C','D','E')) { $runnerArgs += @('--vae-node','VAEDecodeTiled','--tile-size','512','--overlap','64') }
    $text = & $python @runnerArgs 2>&1
    $exit = $LASTEXITCODE
    $jsonLine = @($text | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
    if (-not $jsonLine) { return [pscustomobject]@{ exit_code=$exit; output=($text -join "`n"); failure='Runner returned no JSON result.' } }
    try { $data = $jsonLine[0] | ConvertFrom-Json } catch { return [pscustomobject]@{ exit_code=$exit; output=($text -join "`n"); failure='Runner JSON was invalid.' } }
    $data | Add-Member -NotePropertyName exit_code -NotePropertyValue $exit
    $data
}

function Read-WindowCounters {
    $parsed = foreach ($line in Get-Content -LiteralPath $samplesPath -ErrorAction SilentlyContinue) {
        try { $line | ConvertFrom-Json } catch { $null }
    }
    $parsed = @($parsed | Where-Object { $_ -and $_.adapter_dedicated_bytes -ne $null })
    if (-not $parsed.Count) { return $null }
    $maxDedicated = ($parsed | Measure-Object -Property adapter_dedicated_bytes -Maximum).Maximum
    $maxShared = ($parsed | Measure-Object -Property adapter_shared_bytes -Maximum).Maximum
    $first = $parsed[0]
    $peakProcessDedicated = 0L; $peakProcessShared = 0L
    foreach ($row in $parsed) {
        $d = ($row.processes | Measure-Object -Property dedicated_bytes -Sum).Sum
        $s = ($row.processes | Measure-Object -Property shared_bytes -Sum).Sum
        if ($d -gt $peakProcessDedicated) { $peakProcessDedicated = [long]$d }
        if ($s -gt $peakProcessShared) { $peakProcessShared = [long]$s }
    }
    [pscustomobject]@{
        samples=$parsed.Count
        dedicated_baseline_gib=[Math]::Round(([double]$first.adapter_dedicated_bytes/1GB),3)
        dedicated_peak_gib=[Math]::Round(([double]$maxDedicated/1GB),3)
        dedicated_after_gib=[Math]::Round(([double]$parsed[-1].adapter_dedicated_bytes/1GB),3)
        shared_baseline_gib=[Math]::Round(([double]$first.adapter_shared_bytes/1GB),3)
        shared_peak_gib=[Math]::Round(([double]$maxShared/1GB),3)
        shared_increase_gib=[Math]::Round(([double]($maxShared-$first.adapter_shared_bytes)/1GB),3)
        process_dedicated_peak_gib=[Math]::Round(([double]$peakProcessDedicated/1GB),3)
        process_shared_peak_gib=[Math]::Round(([double]$peakProcessShared/1GB),3)
    }
}

$residentBefore = Get-ResidentNarrator
if (-not $residentBefore -or $residentBefore.context -ne $context) { throw 'qwen3.5:4b at 65,536 context must already be resident before each renderer variant.' }
try { $null = Invoke-RestMethod -Uri ($comfyUrl + '/system_stats') -TimeoutSec 2; throw 'The ComfyUI port is already active; refusing to control an existing renderer.' } catch { if ($_.Exception.Message -like 'The ComfyUI port is already active*') { throw } }

$opts = switch ($Variant) {
    A { @{ CpuVae=$true; LowVram=$false; SplitCrossAttention=$false; NoVram=$false; vae='VAEDecode'; description='CPU VAE only' } }
    B { @{ CpuVae=$true; LowVram=$true; SplitCrossAttention=$false; NoVram=$false; vae='VAEDecode'; description='low-VRAM + CPU VAE' } }
    C { @{ CpuVae=$false; LowVram=$true; SplitCrossAttention=$false; NoVram=$false; vae='VAEDecodeTiled'; description='low-VRAM + tiled VAE, tile 512 overlap 64' } }
    D { @{ CpuVae=$false; LowVram=$true; SplitCrossAttention=$true; NoVram=$false; vae='VAEDecodeTiled'; description='low-VRAM + tiled VAE + split cross-attention' } }
    E { @{ CpuVae=$false; LowVram=$false; SplitCrossAttention=$true; NoVram=$true; vae='VAEDecodeTiled'; description='novram + tiled VAE + split cross-attention' } }
}

$server = Start-Job -Name ("Dungeon-SDXL-{0}-GPU-Sampler" -f $Variant) -ArgumentList $samplesPath -ScriptBlock {
    param($path)
    $ErrorActionPreference = 'Continue'
    $luid = 'luid_0x00000000_0x0000e32d'
    while ($true) {
        try {
            $counterSet = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage','\GPU Adapter Memory(*)\Shared Usage','\GPU Process Memory(*)\Dedicated Usage','\GPU Process Memory(*)\Shared Usage' -ErrorAction Stop).CounterSamples
            $deviceDed = @($counterSet | Where-Object { $_.Path -match '(?i)GPU Adapter Memory' -and $_.Path -match [regex]::Escape($luid) -and $_.Path -match '(?i)Dedicated Usage' } | Select-Object -First 1)
            $deviceShared = @($counterSet | Where-Object { $_.Path -match '(?i)GPU Adapter Memory' -and $_.Path -match [regex]::Escape($luid) -and $_.Path -match '(?i)Shared Usage' } | Select-Object -First 1)
            $processes = @($counterSet | Where-Object { $_.Path -match '(?i)GPU Process Memory' -and $_.Path -match [regex]::Escape($luid) } | Group-Object { if ($_.Path -match '(?i)pid_(\d+)_.*(Dedicated|Shared) Usage') { $Matches[1] } else { '0' } } | ForEach-Object {
                $pidValue = [int]$_.Name
                $ded = ($_.Group | Where-Object { $_.Path -match '(?i)Dedicated Usage' } | Measure-Object -Property CookedValue -Sum).Sum
                $shr = ($_.Group | Where-Object { $_.Path -match '(?i)Shared Usage' } | Measure-Object -Property CookedValue -Sum).Sum
                [pscustomobject]@{ pid=$pidValue; dedicated_bytes=[long]$ded; shared_bytes=[long]$shr }
            })
            if ($deviceDed.Count -and $deviceShared.Count) {
                [pscustomobject]@{
                    utc=[DateTime]::UtcNow.ToString('o')
                    adapter_dedicated_bytes=[long]$deviceDed[0].CookedValue
                    adapter_shared_bytes=[long]$deviceShared[0].CookedValue
                    processes=$processes
                } | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath $path -Encoding UTF8
            }
        } catch { }
        Start-Sleep -Milliseconds 400
    }
}

$backendStarted = $false
$comfyPid = $null
$warmup = $null
$measured = $null
$narratorAfterRender = $null
$narratorProbe = $null
$memory = $null
try {
    Start-Sleep -Seconds 3
    $startArgs = @{Action='start';Port=18189;ReadyTimeoutSeconds=120}
    foreach ($name in @('CpuVae','LowVram','SplitCrossAttention','NoVram')) { if ($opts[$name]) { $startArgs[$name]=$true } }
    $startText = & $backend @startArgs
    $startLine = @($startText | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
    if (-not $startLine) { throw "Backend returned no start record: $($startText -join ' ')" }
    $start = $startLine[0] | ConvertFrom-Json
    $backendStarted = $true
    $comfyPid = [int]$start.ProcessId
    Start-Sleep -Seconds 2

    if ($Variant -eq 'A') { $warmSeed=982008 } else { $warmSeed=982008 }
    $warmup = Invoke-Job $warmSeed 'warmup'
    if ($warmup.png_valid) { $measured = Invoke-Job 982009 'measured' }
    $narratorAfterRender = Get-ResidentNarrator
    if ($narratorAfterRender -and $narratorAfterRender.context -eq $context) {
        $body = @{model=$model;prompt='Reply exactly READY.';stream=$false;think=$false;keep_alive='30m';options=@{num_ctx=$context;num_predict=8}} | ConvertTo-Json -Compress
        $narratorProbe = Invoke-RestMethod -Uri ($ollamaUrl+'/api/generate') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180
    }
} finally {
    if ($backendStarted) { try { $null = & $backend stop | ConvertFrom-Json } catch { } }
    Start-Sleep -Seconds 2
    Stop-Job -Job $server -ErrorAction SilentlyContinue
    Remove-Job -Job $server -Force -ErrorAction SilentlyContinue
    $memory = Read-WindowCounters
}

$narratorAfterProbe = Get-ResidentNarrator
$answer = if ($narratorProbe) { ([string]$narratorProbe.response).Trim() } else { $null }
$safe = [bool]($measured -and $measured.png_valid -and $measured.total_seconds -le 20 -and $memory -and $memory.dedicated_peak_gib -le 14.5 -and $memory.shared_increase_gib -lt 1.0 -and $narratorAfterProbe -and $narratorAfterProbe.context -eq $context -and $answer -match 'READY')
$result = [pscustomobject]@{
    variant=$Variant; description=$opts.description
    flags=@(if($opts.CpuVae){'--cpu-vae'};if($opts.LowVram){'--lowvram'};if($opts.SplitCrossAttention){'--use-split-cross-attention'};if($opts.NoVram){'--novram'})
    workflow=[pscustomobject]@{model='sdxl_lightning_4step.safetensors';precision='FP16';resolution='960x540';prompt='Prompt 1 — Environment';seed=982009;sampler='Euler';scheduler='sgm_uniform';steps=4;cfg=1.0;denoise=1.0;vae_node=$opts.vae;tile_size=if($opts.vae -eq 'VAEDecodeTiled'){512}else{$null};overlap=if($opts.vae -eq 'VAEDecodeTiled'){64}else{$null}}
    warmup=$warmup;measured=$measured;gpu=$memory
    narrator_before=$residentBefore;narrator_after_render=$narratorAfterRender;narrator_after_probe=$narratorAfterProbe
    narrator_reply=$answer;narrator_usable=([bool]($answer -match 'READY'));safe_success=$safe
    comfy_pid=$comfyPid;sample_path=$samplesPath;completed_utc=[DateTime]::UtcNow.ToString('o')
}
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding UTF8
$result | ConvertTo-Json -Depth 12
if (-not $result.measured -or -not $result.measured.png_valid) { return }
