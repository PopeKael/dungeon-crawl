# Windows guide

## Launching

Normal Dungeon Crawl launches use **DungeonCrawler.exe** or its Desktop/Start-menu shortcut. `Launch-Windows.bat` now forwards to that EXE; it must be built first. The executable shows a 640×480 splash with live startup stages, takes ownership of the local Ollama server, starts the configured Qwen 4B/64K narrator, Dungeon-owned Vulkan renderer, web app and gateway, then opens the browser. The tray offers **Open web page**, **Shut down**, and **Exit**; Exit remains available during startup and force-stops Dungeon-owned workloads before closing the tray. Shutdown also terminates the local Ollama server. Follow the [Windows executable guide](windows-launcher.md) for the lifecycle details.

The configured profile is Qwen 3.5 4B, 64K context and the existing SDXL-Lightning Vulkan renderer. Startup does not install models or image dependencies. A terminal web launch can use other compatible backends; see [Phase 1 local configuration](phase1-local.md).

Legacy upstream image setup and smoke scripts remain available for maintenance, but are not used by the normal launcher. The current launcher manages the Dungeon-owned Vulkan renderer as part of Dungeon startup and shutdown; see [image generation](image-generation.md) for its measured configuration.

## Image setup

Local image generation is optional. The launcher only sets up Git, Python,
and `ultra-fast-image-gen` if you type `Y` at the image prompt, so a missing
Python runtime will not block text play. When enabled it clones
`ultra-fast-image-gen` into `%USERPROFILE%\ultra-fast-image-gen`, creates
`.venv`, and installs the right PyTorch build for your GPU:

- **NVIDIA** (`nvidia-smi` present): CUDA wheels.
- **Supported AMD Radeon**: AMD's official PyTorch-on-Windows (ROCm) wheels —
  see [Image generation](image-generation.md#amd-gpus) for the supported-GPU
  list and driver requirements.
- **Anything else**: CPU wheels.

If GPU setup gives you trouble or you want the most compatible optional image
path, double-click `windows\Launch-Windows-CPU.bat` instead and opt into image
setup there. The image setup also fast-forwards an existing clean
`ultra-fast-image-gen` checkout, keeps the selected PyTorch wheel in place
while installing the rest of that repo's requirements, verifies the expected
`flux2-4b-sdnq` CLI route is still present, and reinstalls image dependencies
when `requirements.txt` changes.

To force CPU for an explicit image setup from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -SetupImages -CpuOnly
```

## Tuning

On Windows, local text generation defaults to a safer 65K context window and
a 6 minute upstream timeout so a slow or wedged Ollama request returns
control to the app instead of leaving the UI spinning forever. Set
`LOCAL_TEXT_CONTEXT` or `LOCAL_TEXT_TIMEOUT_MS` in `.env.server` to tune
those limits.

## Proving the image path

To sanity-check image routing without downloading models or generating an
image:

```powershell
npm run check:image-routing
npm run check:image-server-http
```

To prove the real Windows image path, double-click
`windows\Launch-Windows-Image-Smoke.bat` (auto GPU when available) or
`windows\Launch-Windows-Image-Smoke-CPU.bat` (forced CPU). This performs a
real 512px FLUX generation, will download model weights the first time, and
writes a transcript to `logs/windows-image-smoke-*.log`. The image server
itself tees backend output to `logs/windows-image-server-*.log`, with the
latest path saved in `logs/windows-image-server-latest.txt`.

For the full proof loop, double-click `windows\Launch-Windows-Image-Loop.bat`;
it runs a fresh CPU smoke and, when a supported GPU is detected, a fresh GPU
smoke, switching the shared PyTorch venv wheel as needed and collecting
diagnostics after each success or failure.

## Diagnostics

If something hangs or GPU/CPU image generation fails, double-click
`windows\Diagnose-Windows.bat` to write a machine, GPU, Ollama, PyTorch,
image-worker, and recent-log snapshot to `logs/windows-diagnostics-*.txt`.

From PowerShell, the same checks are:

```powershell
npm run image:loop:windows
npm run image:smoke:windows
npm run image:smoke:windows:cuda
npm run image:smoke:windows:cpu
npm run windows:diagnose
npm run windows:stop
```
