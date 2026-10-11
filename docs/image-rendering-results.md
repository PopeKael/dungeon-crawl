# Dungeon Crawl image rendering results

Measured on Windows 11 with an AMD Radeon RX 7800 XT 16 GB, 11 October 2026.
The selected workflow is the only one tested here that met the speed and
coexistence targets together.

## Current Dungeon-owned workflow

Dungeon uses a headless `stable-diffusion.cpp` server with its Vulkan backend.
The local checkpoint is SDXL-Lightning 4-step FP16. Dungeon manages the server
process and readiness, submits requests on loopback, saves returned PNGs under
`public/generated/`, and associates each image with its saved assistant
passage. Automatic requests are enabled by default. The browser receives the
saved image-request placeholder first and dispatches it while the visible
narration continues; the completed image replaces the placeholder. A failed
image can be retried from that passage.

| Setting | Measured value |
|---|---|
| Checkpoint | `sdxl_lightning_4step.safetensors`, FP16 |
| Runtime | stable-diffusion.cpp `1b0ba10`, Vulkan device 0 |
| GPU | AMD Radeon RX 7800 XT; Vulkan driver 26.8.1 (LLPC) |
| Canvas | 960×536 delivered; engine generates 960×576 and center-crops 20 pixels from top and bottom |
| Sampling | Euler, `sgm_uniform`, 4 steps, CFG 1.0, batch 1 |
| Memory budget | `--max-vram 6.0`; no CPU offload or VAE tiling |
| Narrator in coexistence test | `qwen3.5:4b`, 65,536 context, 5.224 GiB reported resident VRAM |

### Repeated coexistence measurements

| Run | End-to-end image time | Sampling | VAE decode | Peak dedicated memory | Peak shared memory | Narrator response | PNG |
|---|---:|---:|---:|---:|---:|---|---|
| Initial | 19.380 s | 6.670 s | 8.580 s | 13.818 GiB | 7.427 GiB | `READY` | Valid |
| Warm 1 | 11.940 s | 2.820 s | 8.200 s | **14.096 GiB** | **7.433 GiB** | `READY` | Valid |
| Warm 2 | 11.954 s | 2.460 s | 7.870 s | 12.816 GiB | 7.433 GiB | `READY` | Valid |
| Warm 3 | 11.939 s | 2.670 s | 7.790 s | 13.882 GiB | 7.433 GiB | `READY` | Valid |

Peak dedicated memory stayed below the 14.5 GiB target, and Qwen answered
`READY` after every image. Shared memory rose substantially; these four
successful renders do not prove that unrelated GPU or RAM workloads can safely
run at the same time. Model weights were staged through system RAM by the
renderer, and VAE decode was the largest part of warm generation time.

The first image included 2.470 seconds of checkpoint tensor loading. Renderer
startup reached API readiness in 2.129 seconds. The server's own image times
were 18.05 seconds cold and 11.05, 10.35, and 10.50 seconds warm; the table
uses end-to-end API timings. The repeatable local command is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\benchmark-sdxl-lightning-sdcpp.ps1 -Variant A -Runs 4
```

## Comparison with measured alternatives

| Workflow | Result | What it establishes |
|---|---|---|
| Ariadne-managed SDXL Base, 24 steps | Warm 960×540: 15.5–16.5 s. 1280×720: 93.4–248.7 s. | Earlier visual baseline. Six images were coherent fantasy scenes; named-character details and prompt adherence varied. |
| Dungeon ComfyUI DirectML, SDXL-Lightning 4-step, image only | Warm 960×540 mean: 8.74 s across three prompts. All three produced PNGs. | Fastest image-only path measured. 1280×720 failed on all three later measured attempts with GPU allocation errors; an earlier exploratory attempt completed once in 53.4 s. |
| DirectML plus resident Qwen | No tested variant met the requested repeatability, ≤20 s warm time, and ≤14.5 GiB dedicated-memory limit together. The quickest exact-size first image took 21.245 s, peaked at 15.336 GiB, and a repeat stalled. | The image-only speed does not carry over safely when the narrator remains resident. |
| Dungeon Vulkan plus resident Qwen | Three consecutive warm runs: 11.939–11.954 s; peak dedicated 14.096 GiB. | Selected coexistence workflow; meets the stated warm speed and dedicated-memory targets, with high shared-memory use. |
| FLUX.2 Klein 4B Distilled, native Windows ROCm | No image job started. ComfyUI failed during startup at `torch.cuda.mem_get_info()` with `hipErrorInvalidValue`. | No image-quality or speed result; this attempt does not support a recommendation for Klein. |

## Recommendation and limits

Use the Dungeon-owned Vulkan SDXL-Lightning workflow for the current Windows
story renderer. It is slower than the 8.74-second DirectML image-only result,
but it generated three repeatable warm images with the 4B narrator resident,
stayed below the dedicated-memory ceiling, and kept the narrator responsive.
The two timing comparisons use slightly different canvases: Vulkan generates
960×576 then crops to 960×536, while DirectML used 960×540 directly.

The successful Vulkan runs confirm that the output is a valid PNG and that the
prompt workflow runs repeatedly; they were not a formal visual-quality scoring
study. The six earlier Ariadne images received a visual review, with good
cavern atmosphere but variable character and costume fidelity. Character
consistency remains a model-quality limitation rather than a speed result.

Runtime binaries, model weights, raw GPU samples, and the Vulkan run images are
machine-local and ignored by Git. The benchmark report, prompt, per-run JSON,
and generated Vulkan PNGs are retained locally under
`benchmarks/sd-cpp-vulkan/`; the six Ariadne comparison images and their report
are tracked under `benchmarks/ariadne-images/`. A fresh checkout therefore
needs the documented local runtime and checkpoint before it can run this
renderer; the report does not package model files.
