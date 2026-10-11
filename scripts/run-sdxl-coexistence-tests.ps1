$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtime = Join-Path $root 'runtime/sdxl-lightning'
$logs = Join-Path $runtime 'logs'
$stateDir = Join-Path $runtime 'state'
$outDir = Join-Path $root 'benchmarks/sdxl-lightning/coexistence-optimization'
$ollamaUrl = 'http://127.0.0.1:11434'
$ollamaExe = (Get-Command ollama.exe -ErrorAction Stop).Source
$serverStdout = Join-Path $logs 'ollama-coexist-optimization.stdout.log'
$serverStderr = Join-Path $logs 'ollama-coexist-optimization.stderr.log'
$statePath = Join-Path $stateDir 'coexist-optimization-ollama.json'
$measureScript = Join-Path $PSScriptRoot 'measure-sdxl-coexistence.ps1'
$resultFiles = @()
$server = $null
$serverStartedByThisRun = $false
$cleanupErrors = [Collections.Generic.List[string]]::new()
New-Item -ItemType Directory -Force -Path $outDir,$logs,$stateDir | Out-Null

if (Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue) { throw 'Ollama port 11434 is occupied; refusing to inspect or control an existing service.' }
if (Get-Process -Name ollama,ollama_llama_server -ErrorAction SilentlyContinue) { throw 'An Ollama process exists although its API is offline; refusing to alter a process this task did not start.' }

try {
    $server = Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden -PassThru -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr
    $serverStartedByThisRun = $true
    $server | Select-Object Id,StartTime,Path | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    $ready = $false
    do {
        try { $null = Invoke-RestMethod -Uri ($ollamaUrl+'/api/version') -TimeoutSec 2; $ready = $true; break }
        catch { Start-Sleep -Milliseconds 500 }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $ready) { throw 'Ollama did not become ready within 60 seconds.' }
    $before = Invoke-RestMethod -Uri ($ollamaUrl+'/api/ps') -TimeoutSec 5
    if (@($before.models).Count) { throw 'Unexpected Ollama model is resident; stopping before tests.' }

    $loadBody = @{model='qwen3.5:4b';prompt='Reply exactly READY.';stream=$false;think=$false;keep_alive='30m';options=@{num_ctx=65536;num_predict=8}} | ConvertTo-Json -Compress
    $load = Invoke-RestMethod -Uri ($ollamaUrl+'/api/generate') -Method Post -ContentType 'application/json' -Body $loadBody -TimeoutSec 300
    $resident = Invoke-RestMethod -Uri ($ollamaUrl+'/api/ps') -TimeoutSec 5
    $qwen = @($resident.models | Where-Object { $_.name -eq 'qwen3.5:4b' })
    if ($qwen.Count -ne 1 -or [int]$qwen[0].context_length -ne 65536 -or $load.response -notmatch 'READY') { throw 'Could not establish qwen3.5:4b residency at 65,536 context.' }
    Write-Output ("Narrator ready: {0} at context {1}; Ollama reports {2:N3} GiB VRAM." -f $qwen[0].name,$qwen[0].context_length,($qwen[0].size_vram/1GB))

    foreach ($variant in @('A','B','C','D','E')) {
        Write-Output ("Starting variant {0}; narrator remains resident." -f $variant)
        try { & $measureScript -Variant $variant } catch { Write-Warning ("Variant {0} orchestration error: {1}" -f $variant,$_.Exception.Message) }
        $resultPath = Join-Path $outDir ("variant-{0}.json" -f $variant)
        if (Test-Path -LiteralPath $resultPath) {
            $resultFiles += $resultPath
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            Write-Output ("Variant {0}: png={1}, warm={2}s, sampling={3}s, VAE={4}s, peak={5} GiB dedicated, shared increase={6} GiB, safe={7}" -f $variant,$result.measured.png_valid,$result.measured.total_seconds,$result.measured.sampling_seconds,$result.measured.vae_decode_seconds,$result.gpu.dedicated_peak_gib,$result.gpu.shared_increase_gib,$result.safe_success)
            if ($result.safe_success) { break }
        } else { Write-Warning ("Variant {0} did not write a result file." -f $variant) }
        $resident = Invoke-RestMethod -Uri ($ollamaUrl+'/api/ps') -TimeoutSec 5
        $qwen = @($resident.models | Where-Object { $_.name -eq 'qwen3.5:4b' })
        if ($qwen.Count -ne 1 -or [int]$qwen[0].context_length -ne 65536) { throw "Narrator residency lost after variant $variant; refusing to continue testing." }
    }
} finally {
    if ($serverStartedByThisRun) {
        try {
            $body = @{model='qwen3.5:4b';keep_alive='0'} | ConvertTo-Json -Compress
            $null = Invoke-RestMethod -Uri ($ollamaUrl+'/api/generate') -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180
            $remaining = Invoke-RestMethod -Uri ($ollamaUrl+'/api/ps') -TimeoutSec 10
            if (@($remaining.models).Count -ne 0) { throw 'A model remained resident after requested unload; preserving the Ollama server.' }
            $live = Get-Process -Id $server.Id -ErrorAction SilentlyContinue
            if ($live -and $live.StartTime.ToUniversalTime().Ticks -eq $server.StartTime.ToUniversalTime().Ticks -and [IO.Path]::GetFullPath($live.Path) -eq [IO.Path]::GetFullPath($ollamaExe)) {
                Stop-Process -Id $server.Id -ErrorAction Stop
                $server.WaitForExit(10000)
            }
            Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
}

$report = [pscustomobject]@{completed_utc=[DateTime]::UtcNow.ToString('o');narrator='qwen3.5:4b';context=65536;loaded_once_and_kept_resident=$true;variant_files=$resultFiles;cleanup_errors=@($cleanupErrors.ToArray())}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outDir 'run-summary.json') -Encoding UTF8
$report | ConvertTo-Json -Depth 5
if ($cleanupErrors.Count) { throw ('Cleanup incomplete: ' + ($cleanupErrors -join '; ')) }
