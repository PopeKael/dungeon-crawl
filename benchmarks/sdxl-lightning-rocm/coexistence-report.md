# Native ROCm SDXL-Lightning coexistence test

## Result: blocked before image jobs

No narrator or image model was loaded. No benchmark images were generated, so there are no render, model-load, sampling, VAE, or peak-memory measurements to report.

The isolated ComfyUI checkout is version `0.39.0`, commit `7f7fd918ed0815c5d5ef2ccfe44bfc8e72cfd217`. Its installed ROCm interpreter is Dungeon's existing `runtime/flux2-klein/venv312` (Python `3.12.0`, PyTorch `2.12.0+rocm7.14.0`, HIP `7.14.60850`). PyTorch enumerates `AMD Radeon RX 7800 XT`, architecture `gfx1101`, with `15.984 GiB` reported device memory.

The requested baseline launch options are supported by this checkout:

```text
--listen 127.0.0.1 --port 18190 --disable-auto-launch
--enable-dynamic-vram --vram-headroom 1.5 --cache-none
```

Normal VRAM mode is the default; no `--lowvram`, `--cpu-vae`, or split-attention option was passed. `--cache-none` is available to ensure identical-seed submissions execute rather than being served from the node cache.

ComfyUI exits during import, before its API becomes ready. In `comfy/model_management.py:get_total_memory()`, startup calls `torch.cuda.mem_get_info()`, which fails in this environment with `torch.AcceleratorError: CUDA error: invalid argument` / `hipErrorInvalidValue`. The exact startup probe log is `runtime/sdxl-lightning-rocm/logs/native-rocm-startup-probe.err.log`; stdout is in `runtime/sdxl-lightning-rocm/logs/native-rocm-startup-probe.log`. The same memory query also fails when run directly, before starting ComfyUI or loading Qwen, so this is not caused by narrator coexistence.

Windows GPU adapter counters could not be read in this session (`Get-Counter` returned `c0000bb8`). Ollama was offline and no models were loaded; the failed ComfyUI probe exited and left no listener on port 18190. The existing DirectML renderer was not started or modified.

## What remains unmeasured

All four requested renders, their PNG validity, narrator responses/residency, dedicated/shared memory peaks, `/free` behavior, and pinned-memory variant remain untested. No claim about native ROCm coexistence or speed can be made from this run.

The immediate blocker is the Windows ROCm `mem_get_info()` failure during ComfyUI startup. This checkout's CLI supports the requested DynamicVRAM and headroom flags, but the server never reaches readiness. A prior Dungeon-local ROCm runtime note also records a failed GPU matrix operation on the alternate ROCm 10 / PyTorch 2.13 path; switching stacks is not a verified workaround. No ComfyUI source patch was made because a previous local memory-stat bypass faulted in the ROCm DLL.
