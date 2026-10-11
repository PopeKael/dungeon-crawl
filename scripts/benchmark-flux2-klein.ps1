param(
    [ValidateSet('Install', 'Benchmark')]
    [string]$Action = 'Benchmark',
    [ValidateRange(2, 10)]
    [int]$Repeats = 2
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtime = Join-Path $root 'runtime\flux2-klein'
$comfy = Join-Path $runtime 'ComfyUI'
$venvPython = Join-Path $runtime 'venv312\Scripts\python.exe'
$models = Join-Path $comfy 'models'
$output = Join-Path $root 'benchmarks\flux2-klein'
$launcher = Join-Path $PSScriptRoot 'dungeon-comfy.ps1'

function Install-Runtime {
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null
    $privateTemp = Join-Path $runtime 'tmp'
    New-Item -ItemType Directory -Force -Path $privateTemp | Out-Null
    $env:TEMP = $privateTemp
    $env:TMP = $privateTemp
    if (-not (Test-Path (Join-Path $comfy 'main.py'))) {
        git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git $comfy
        if ($LASTEXITCODE -ne 0) { throw 'Could not clone the official Comfy-Org/ComfyUI repository.' }
    }
    $sourcePython = (Get-Command python -ErrorAction Stop).Source
    if (-not (Test-Path $venvPython)) { & $sourcePython -m venv (Join-Path $runtime 'venv312') }
    & $venvPython -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) { throw 'Could not update private runtime pip.' }
    & $venvPython -m pip install --upgrade --no-build-isolation --index-url https://repo.amd.com/rocm/whl-multi-arch/ --extra-index-url https://pypi.org/simple 'setuptools>=70.2.0' wheel
    if ($LASTEXITCODE -ne 0) { throw 'Could not install private Python build helpers.' }
    & $venvPython -m pip install --upgrade --no-build-isolation --index-url https://repo.amd.com/rocm/whl-multi-arch/ --extra-index-url https://pypi.org/simple 'torch[device-all]==2.12.0+rocm7.14.0' 'torchvision[device-all]==0.27.0+rocm7.14.0' 'torchaudio==2.11.0+rocm7.14.0'
    if ($LASTEXITCODE -ne 0) { throw 'Could not install Comfy-Org Windows ROCm 7.14 PyTorch packages.' }
    $constraints = Join-Path $runtime 'requirements-rocm-constraints.txt'
    @('torch==2.12.0+rocm7.14.0','torchvision==0.27.0+rocm7.14.0','torchaudio==2.11.0+rocm7.14.0') | Set-Content -LiteralPath $constraints -Encoding ascii
    & $venvPython -m pip install --upgrade --constraint $constraints --index-url https://repo.amd.com/rocm/whl-multi-arch/ --extra-index-url https://pypi.org/simple -r (Join-Path $comfy 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Could not install private ComfyUI requirements.' }
    $torchInfo = & $venvPython -c "import torch; x=torch.randn((128,128),device='cuda'); y=x@x; torch.cuda.synchronize(); print({'torch':torch.__version__,'hip':torch.version.hip,'cuda_available':torch.cuda.is_available(),'devices':torch.cuda.device_count(),'name':torch.cuda.get_device_name(0),'arch':torch.cuda.get_device_properties(0).gcnArchName,'kernel_smoke':list(y.shape)})"
    if ($LASTEXITCODE -ne 0) { throw 'Private PyTorch installation failed import/device validation.' }
    Write-Output "PyTorch: $torchInfo"
    $commit = git -C $comfy rev-parse HEAD
    Set-Content -LiteralPath (Join-Path $runtime 'runtime-version.txt') -Value "ComfyUI commit=$commit`nPython=$(& $venvPython --version)`nROCm=7.14.0 Windows multi-arch wheels`nPyTorch=$(& $venvPython -c 'import torch; print(torch.__version__)')`nGPU target=gfx1101`nModel=FLUX.2 Klein 4B Distilled FP8" -Encoding utf8
    foreach ($folder in @('diffusion_models','text_encoders','vae')) { New-Item -ItemType Directory -Force -Path (Join-Path $models $folder) | Out-Null }
    $downloads = @(
        @{ Name='flux-2-klein-4b-fp8.safetensors'; Url='https://huggingface.co/black-forest-labs/FLUX.2-klein-4b-fp8/resolve/main/flux-2-klein-4b-fp8.safetensors'; Folder='diffusion_models' },
        @{ Name='qwen_3_4b.safetensors'; Url='https://huggingface.co/Comfy-Org/flux2-klein/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors'; Folder='text_encoders' },
        @{ Name='flux2-vae.safetensors'; Url='https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors'; Folder='vae' }
    )
    foreach ($file in $downloads) {
        $destination = Join-Path (Join-Path $models $file.Folder) $file.Name
        if (-not (Test-Path $destination)) {
            Write-Output "Downloading $($file.Name) into Dungeon's ignored runtime."
            & curl.exe --fail --location --retry 6 --retry-delay 3 --continue-at - --output $destination $file.Url
            if ($LASTEXITCODE -ne 0) { throw "Download failed for $($file.Name). Partial data, if any, remains in Dungeon's ignored runtime for resume." }
        }
    }
    $expected = @('models\diffusion_models\flux-2-klein-4b-fp8.safetensors','models\text_encoders\qwen_3_4b.safetensors','models\vae\flux2-vae.safetensors')
    foreach ($relative in $expected) { if ((Get-Item (Join-Path $comfy $relative)).Length -lt 100MB) { throw "Model file failed size sanity check: $relative" } }
}

if ($Action -eq 'Install') { Install-Runtime; exit 0 }
if (-not (Test-Path $venvPython)) { throw 'Dungeon runtime is not installed. Run: powershell -NoProfile -ExecutionPolicy Bypass -File scripts\benchmark-flux2-klein.ps1 -Action Install' }
$check = & $venvPython -c "import torch; assert torch.cuda.is_available(); print(torch.cuda.get_device_name(0), torch.version.hip)"
if ($LASTEXITCODE -ne 0) { throw "Private ROCm PyTorch cannot see an accelerator: $check" }
$startup = $null
try {
    $startWatch = [Diagnostics.Stopwatch]::StartNew()
    $startOutput = & $launcher -Action Start | Select-Object -Last 1
    try { $startup = $startOutput | ConvertFrom-Json } catch { throw "Could not parse Dungeon ComfyUI startup telemetry: $startOutput" }
    if (-not $startup.Ready) { throw "ComfyUI failed readiness: $startOutput" }
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    $bench = Join-Path $PSScriptRoot 'flux2_klein_benchmark.py'
    & $venvPython $bench --output $output --repeats $Repeats
    if ($LASTEXITCODE -ne 0) { throw 'FLUX.2 Klein benchmark job failed. See private ComfyUI logs.' }
    $runData = Get-Content -LiteralPath (Join-Path $output 'runs.json') -Raw | ConvertFrom-Json
    $summary = [ordered]@{
        title = 'Dungeon Crawl FLUX.2 Klein 4B Distilled benchmark'
        generated_utc = [DateTime]::UtcNow.ToString('o')
        hardware = 'AMD Radeon RX 7800 XT 16 GB; Windows ROCm gfx1101 path'
        backend = 'Dungeon-owned headless ComfyUI; loopback 127.0.0.1:18188'
        comfyui_startup_seconds = [double]$startup.StartupSeconds
        repeats_per_prompt_resolution = $Repeats
        model_load_warmup = 'First run per prompt and resolution is cold/first-use. Estimated loading/compile overhead is first-run time minus its paired second warm run; not separately instrumented inside ComfyUI.'
        qwen_coexistence = 'See benchmark-report.md for the read-only Ollama residency and 4B/64K check. This benchmark script does not unload narrator models.'
        runs = $runData.rows
        comparison = 'Prior baseline: 960x540 warm ~15.5-16.5s; 1280x720 ~93-249s (benchmarks/ariadne-images/benchmark-report.md).'
    }
    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'benchmark-report.json') -Encoding utf8
    Write-Output "Benchmark report: $(Join-Path $output 'benchmark-report.json')"
} finally {
    & $launcher -Action Stop
}
