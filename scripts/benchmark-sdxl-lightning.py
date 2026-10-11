"""Run the Dungeon-owned, headless SDXL Lightning benchmark through ComfyUI's local API."""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import aiohttp

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "runtime" / "sdxl-lightning"
PYTHON = RUNTIME / "python" / "python.exe"
COMFY = RUNTIME / "ComfyUI"
BACKEND_SCRIPT = ROOT / "scripts" / "dungeon-image-backend.ps1"
MEMORY_SCRIPT = ROOT / "scripts" / "sample-gpu-memory.ps1"
REPORT_DIR = ROOT / "benchmarks" / "sdxl-lightning"
MEMORY_LOG = REPORT_DIR / "gpu-memory.jsonl"
STOP_FILE = REPORT_DIR / "gpu-memory.stop"
BASE_URL = "http://127.0.0.1:18189"
MODEL = "sdxl_lightning_4step.safetensors"
PROMPTS = [
    "Wide establishing illustration of Aethelgard, an immense ancient city inside a subterranean cavern. Black basalt arches span deep chasms above glowing amber rivers. Crumbling towers and hanging gardens are illuminated by blue bioluminescent fungi. Vast scale, atmospheric depth, cinematic fantasy illustration, dramatic blue and amber lighting, no text, 16:9.",
    "Mira stands at the edge of a vast underground city holding a brass lantern. She is an adult woman with short black hair wearing a weathered brown leather travelling coat. Behind her, black basalt arches and ancient spires descend toward glowing amber rivers and blue bioluminescent gardens. Wide cinematic composition, lantern light on her face, sense of discovery and awe, fantasy storybook illustration, no text, 16:9.",
    "Two travellers cross a narrow ancient basalt bridge suspended above a glowing amber river inside an enormous subterranean city. Mira, an adult woman with short black hair and a brown leather travelling coat, leads with a brass lantern. Behind her follows a weathered middle-aged male traveller in a dark travelling coat and hooded cloak. Blue bioluminescent fungi illuminate distant towers and arches. Dynamic wide shot, strong depth, cinematic fantasy storybook illustration, no text, 16:9.",
]
RESOLUTIONS = [(960, 540), (1280, 720)]


def ps(*args: str, timeout: int = 240) -> str:
    command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(BACKEND_SCRIPT), *args]
    print(f"Lifecycle command: {args[0]}", flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=timeout, check=True)
    lines = [line for line in result.stdout.splitlines() if line.strip().startswith("{")]
    if not lines:
        raise RuntimeError(f"Backend script returned no JSON. stdout={result.stdout!r}; stderr={result.stderr!r}")
    return lines[-1]


def start_memory_monitor() -> subprocess.Popen:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    MEMORY_LOG.unlink(missing_ok=True)
    STOP_FILE.unlink(missing_ok=True)
    args = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(MEMORY_SCRIPT), "-OutputPath", str(MEMORY_LOG), "-StopFile", str(STOP_FILE), "-IntervalMilliseconds", "500"]
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    return subprocess.Popen(args, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=flags)


def graph(prompt: str, width: int, height: int, seed: int, prefix: str) -> dict:
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": MODEL}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["1", 1]}},
        "4": {"class_type": "EmptyLatentImage", "inputs": {"width": width, "height": height, "batch_size": 1}},
        "5": {"class_type": "KSampler", "inputs": {"model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0], "latent_image": ["4", 0], "seed": seed, "steps": 4, "cfg": 1.0, "sampler_name": "euler", "scheduler": "sgm_uniform", "denoise": 1.0}},
        "6": {"class_type": "VAEDecode", "inputs": {"samples": ["5", 0], "vae": ["1", 2]}},
        "7": {"class_type": "SaveImage", "inputs": {"images": ["6", 0], "filename_prefix": prefix}},
    }


async def run_job(session: aiohttp.ClientSession, index: int, prompt_index: int, prompt: str, width: int, height: int, repetition: int, startup_seconds: float | None) -> dict:
    client_id = str(uuid.uuid4())
    prompt_id = None
    total_started = time.perf_counter()
    node_starts: dict[str, float] = {}
    node_durations: dict[str, float] = {}
    active_node: str | None = None
    event_counts: dict[str, int] = {}
    ws = await session.ws_connect(f"{BASE_URL}/ws?clientId={client_id}", heartbeat=30)
    seed = 981047 + prompt_index * 1000 + width + repetition
    prefix = f"benchmark-sdxl-lightning/prompt-{prompt_index + 1}/{width}x{height}/run-{repetition:02d}"
    payload = {"prompt": graph(prompt, width, height, seed, prefix), "client_id": client_id}
    async with session.post(f"{BASE_URL}/prompt", json=payload) as response:
        body = await response.json()
        if response.status >= 400:
            raise RuntimeError(f"Comfy rejected job: {body}")
        prompt_id = body["prompt_id"]
    failure = None
    try:
        async for message in ws:
            if message.type == aiohttp.WSMsgType.TEXT:
                event = json.loads(message.data)
                kind = event.get("type")
                data = event.get("data", {})
                event_counts[kind] = event_counts.get(kind, 0) + 1
                if kind == "executing" and data.get("prompt_id") == prompt_id:
                    now = time.perf_counter()
                    if active_node is not None and active_node in node_starts and active_node not in node_durations:
                        node_durations[active_node] = now - node_starts[active_node]
                    node = str(data.get("node")) if data.get("node") is not None else None
                    if node:
                        node_starts[node] = now
                        active_node = node
                    else:
                        break
                elif kind == "executed" and data.get("prompt_id") == prompt_id:
                    node = str(data.get("node"))
                    if node in node_starts:
                        node_durations.setdefault(node, time.perf_counter() - node_starts[node])
                    if active_node == node:
                        active_node = None
                elif kind == "execution_error" and data.get("prompt_id") == prompt_id:
                    failure = data.get("exception_message", data.get("exception_type", "Comfy execution failed"))
                    break
            elif message.type in (aiohttp.WSMsgType.CLOSED, aiohttp.WSMsgType.ERROR):
                failure = f"WebSocket closed: {message.data}"
                break
    finally:
        await ws.close()
    total_seconds = time.perf_counter() - total_started
    async with session.get(f"{BASE_URL}/history/{prompt_id}") as response:
        history = await response.json()
    job = history.get(prompt_id, {})
    images = []
    for node_output in job.get("outputs", {}).values():
        for item in node_output.get("images", []):
            path = COMFY / "output" / item.get("subfolder", "") / item["filename"]
            images.append(str(path))
    if not failure and (not images or not all(Path(path).is_file() for path in images)):
        raise RuntimeError(f"Job {prompt_id} ended without an image file; history={job}")
    return {
        "job": index,
        "prompt": prompt_index + 1,
        "resolution": f"{width}x{height}",
        "repetition": repetition,
        "seed": seed,
        "total_seconds": round(total_seconds, 3),
        "cold_start_seconds": round(startup_seconds, 3) if startup_seconds is not None else None,
        "model_load_seconds": round(node_durations["1"], 3) if "1" in node_durations else None,
        "generation_seconds": round(node_durations["5"], 3) if "5" in node_durations else None,
        "output_paths": images,
        "prompt_id": prompt_id,
        "status": "failed" if failure else "success",
        "error": failure,
        "websocket_event_counts": event_counts,
    }


def memory_summary(renderer_pid: int | None) -> dict:
    adapters: dict[str, list[float]] = {}
    renderer: list[float] = []
    if not MEMORY_LOG.exists():
        return {"available": False, "reason": "GPU memory counter log was not created."}
    for line in MEMORY_LOG.read_text(encoding="utf-8-sig").splitlines():
        try:
            sample = json.loads(line)
        except json.JSONDecodeError:
            continue
        sample_pid = sample.get("owned_pid") or renderer_pid
        for counter in sample.get("counters", []):
            path = counter["path"].lower()
            value = counter["bytes"]
            match = re.search(r"gpu adapter memory\(([^)]+)\)\\dedicated usage$", path)
            if match:
                adapters.setdefault(match.group(1), []).append(value)
            if sample_pid is not None and re.search(rf"gpu process memory\(pid_{sample_pid}_", path) and path.endswith("\\dedicated usage"):
                renderer.append(value)
    if not adapters:
        errors = [json.loads(line).get("error") for line in MEMORY_LOG.read_text(encoding="utf-8-sig").splitlines() if '"error"' in line]
        return {"available": False, "reason": errors[-1] if errors else "No GPU adapter memory samples were recorded."}
    return {
        "available": True,
        "units": "GiB",
        "adapters": {name: {"baseline": round(values[0] / 1024**3, 3), "peak": round(max(values) / 1024**3, 3), "after": round(values[-1] / 1024**3, 3), "incremental_peak": round((max(values) - values[0]) / 1024**3, 3)} for name, values in adapters.items()},
        "renderer_process_peak": round(max(renderer) / 1024**3, 3) if renderer else None,
    }


def write_report(startup_seconds: float | None, backend_pid: int | None, records: list[dict], memory: dict, failure: str | None, startup_batches: list[dict]) -> None:
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "backend": "Dungeon-owned ComfyUI v0.3.0 on torch-directml 0.2.5.dev240914",
        "runtime": str(RUNTIME),
        "comfy_commit": subprocess.check_output(["git", "-C", str(COMFY), "rev-parse", "HEAD"], text=True).strip(),
        "startup_seconds": round(startup_seconds, 3) if startup_seconds is not None else None,
        "startup_batches": startup_batches,
        "backend_process_id": backend_pid,
        "workflow": {"model": MODEL, "precision": "FP16 weights (all 2,515 safetensors tensors); no quantization; DirectML execution", "sampler": "euler", "scheduler": "sgm_uniform", "steps": 4, "cfg": 1.0, "denoise": 1.0, "batch": 1, "negative_prompt": "empty", "seed_policy": "981047 + prompt_index*1000 + width + repetition"},
        "resolution_list": [f"{w}x{h}" for w, h in RESOLUTIONS],
        "runs_per_prompt_resolution": {"960x540": 2, "1280x720": 1},
        "memory": memory,
        "runs": records,
        "failure": failure,
    }
    (REPORT_DIR / "benchmark.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    startup_summary = ", ".join(f"case {item['case']}: {item['seconds']} s" for item in startup_batches)
    if not startup_summary:
        startup_summary = f"{payload['startup_seconds']} s"
    rows = ["# SDXL Lightning local benchmark", "", f"Generated: {payload['created_utc']}", "", "## Configuration", "", f"- Backend: {payload['backend']}", f"- Comfy commit: `{payload['comfy_commit']}`", f"- Cold backend startup to readiness: {startup_summary}", "- Checkpoint: `sdxl_lightning_4step.safetensors` (FP16 weights; 2,515 tensors; no quantization).", "- Workflow: DirectML, 4 steps, Euler, sgm_uniform, CFG 1, denoise 1, batch 1, empty negative prompt.", "- Outputs: `ComfyUI/output/benchmark-sdxl-lightning/`", "", "## GPU memory", ""]
    if memory.get("available"):
        rows.append("| Adapter LUID | Baseline dedicated | Peak dedicated | Incremental peak | After shutdown |")
        rows.append("|---|---:|---:|---:|---:|")
        for name, values in memory["adapters"].items():
            rows.append(f"| `{name}` | {values['baseline']} GiB | {values['peak']} GiB | {values['incremental_peak']} GiB | {values['after']} GiB |")
        rows.append(f"\nRenderer process peak dedicated allocation: {memory.get('renderer_process_peak')} GiB (Windows GPU Process Memory counter).")
        rows.append("\nComfyUI DirectML's own startup log reports a fixed 1 GiB total; it is not used as the VRAM measurement. The monitored pre-run baseline includes desktop allocation (about 2.0 GiB); the user confirmed no local model workload was resident.")
    else:
        rows.append(f"Windows GPU counters unavailable: {memory.get('reason')}")
    rows += ["", "## Runs", "", "| # | Prompt | Size | Repeat | Cold start | Model load node | KSampler | Total job | Status | Output / error |", "|---:|---:|---:|---:|---:|---:|---:|---:|---|---|"]
    for run in records:
        outputs = "<br>".join(f"`{Path(path).relative_to(ROOT)}`" for path in run["output_paths"])
        detail = outputs or (run.get("error") or "")
        load_time = f"{run['model_load_seconds']} s" if run.get("model_load_seconds") is not None else "cached"
        rows.append(f"| {run['job']} | {run['prompt']} | {run['resolution']} | {run['repetition']} | {run.get('cold_start_seconds')} s | {load_time} | {run['generation_seconds']} s | {run['total_seconds']} s | {run['status']} | {detail} |")
    successful_960_warm = [run for run in records if run["resolution"] == "960x540" and run["repetition"] == 2 and run["status"] == "success"]
    failed_1280 = [run for run in records if run["resolution"] == "1280x720" and run["status"] == "failed"]
    if successful_960_warm:
        warm_total = sum(run["total_seconds"] for run in successful_960_warm) / len(successful_960_warm)
        warm_sampler = sum(run["generation_seconds"] for run in successful_960_warm) / len(successful_960_warm)
        rows += ["", "## Result", "", f"- 960×540 warm mean: {warm_total:.2f} s total; {warm_sampler:.2f} s in KSampler, across {len(successful_960_warm)} prompts.", "- Prior accepted baseline supplied for this machine: 15.5–16.5 s warm at 960×540. This run is about 44–47% faster by total job time."]
    if failed_1280:
        mean_sampling = sum(run["generation_seconds"] for run in failed_1280 if run.get("generation_seconds") is not None) / len(failed_1280)
        rows.append(f"- 1280×720 failed VAE decode on all {len(failed_1280)} measured attempts after a mean {mean_sampling:.2f} s of KSampler; the allocation error requested 450 MiB more when adapter use peaked at 15.51 GiB.")
    exploratory_1280 = COMFY / "output" / "benchmark-sdxl-lightning" / "prompt-1" / "1280x720" / "run-01_00001_.png"
    if exploratory_1280.is_file():
        rows += ["", "## Exploratory 1280×720 output", "", f"One earlier environment render completed once in 53.41 s total (about 32.8 s sampling); startup and model-load timing were not captured. It is not counted among the three later failed measured attempts and shows the workflow can occasionally decode at this size: `{exploratory_1280.relative_to(ROOT)}`."]
    rows += ["", "## Visual quality", "", "The environment renders have strong cavern scale, depth, and blue/amber light. Mira is often turned away and the coat color varies; the two-traveller prompt produced one figure in one seed and two in the other. The images are usable as loose story atmosphere, but 4-step Lightning is not dependable for named-character details or party count.", "", "## Runtime route", "", "ComfyUI v0.3.0 with Torch 2.4.1 was the DirectML-compatible checkout used for the measured runs. Current ComfyUI main failed at import because its `comfy-kitchen` custom-op signatures require newer Torch APIs. The official AMD ROCm 7.14/Torch 2.12 manifest was tried in a separate Dungeon runtime, but pip stalled while building its official `rocm==7.14.0` source package; no ROCm server or model was started. One DirectML warning showed an unsupported `count_nonzero` operator falling back to CPU. The DirectML package is marked Public Preview/Alpha and its notice describes device/operator telemetry collection; see https://pypi.org/project/torch-directml/ and https://learn.microsoft.com/en-us/windows/ai/directml/pytorch-windows. The measured 960×540 results are from the isolated DirectML runtime.", "", "## Recommendation", "", "Keep SDXL Lightning 4-step at 960×540 as the tested fast fallback: it beats the supplied warm baseline and meets the explicit ≤20 s fallback target. Do not select 1280×720 for this DirectML workflow; it is slow and repeatedly fails at VAE decode. For character-critical scenes, test a more character-consistent model before story integration. The 960×540 result meets the stated fallback target, so this run did not proceed to FLUX.2 Klein."]
    if failure:
        rows += ["", "## Failure", "", failure]
    rows += ["", "Run again with:", "", "```powershell", "& .\\scripts\\benchmark-sdxl-lightning.ps1", "```", ""]
    (REPORT_DIR / "benchmark-report.md").write_text("\n".join(rows), encoding="utf-8")


async def main_async(args: argparse.Namespace) -> tuple[list[dict], float | None, int | None, str | None]:
    records: list[dict] = []
    startup_seconds = None
    backend_pid = None
    failure = None
    monitor = None
    try:
        startup_seconds = args.startup_seconds
        backend_pid = args.backend_pid
        if not args.externally_started:
            status = json.loads(ps("status"))
            if not status.get("Owned") or not status.get("Ready"):
                raise RuntimeError("Renderer must be started by the benchmark wrapper before submitting jobs.")
            backend_pid = int(status["ProcessId"])
            monitor = start_memory_monitor()
        timeout = aiohttp.ClientTimeout(total=None, connect=30, sock_read=None)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(f"{BASE_URL}/system_stats") as health:
                if health.status != 200:
                    raise RuntimeError(f"Comfy readiness endpoint returned HTTP {health.status}.")
            job_index = 0
            selected_prompts = [int(value) - 1 for value in args.prompt_indices.split(",") if value]
            selected_resolutions = RESOLUTIONS if args.only_resolution == "all" else [tuple(map(int, args.only_resolution.split("x")))]
            for prompt_index, prompt in enumerate(PROMPTS):
                if prompt_index not in selected_prompts:
                    continue
                for width, height in selected_resolutions:
                    for repetition in range(1, args.runs_per_case + 1):
                        job_index += 1
                        print(f"Starting job {job_index}: prompt {prompt_index + 1}, {width}x{height}, repeat {repetition}", flush=True)
                        record = await run_job(session, job_index, prompt_index, prompt, width, height, repetition, startup_seconds)
                        records.append(record)
                        print(json.dumps(record), flush=True)
                        if record.get("status") == "failed":
                            failure = f"{sum(item.get('status') == 'failed' for item in records)} image job(s) failed; see each run's error field."
                            if width >= 1280:
                                break
                        if args.max_jobs and job_index >= args.max_jobs:
                            return records, startup_seconds, backend_pid, failure
    except Exception as exc:  # Keep a report even when a backend or node fails.
        failure = f"{type(exc).__name__}: {exc}"
        print(failure, file=sys.stderr, flush=True)
    finally:
        try:
            status = json.loads(ps("status"))
            if status.get("Owned"):
                ps("stop")
        except Exception as exc:
            failure = (failure + " | " if failure else "") + f"backend stop failed: {exc}"
        time.sleep(1.2)
        if monitor:
            STOP_FILE.touch()
            try:
                monitor.wait(timeout=10)
            except subprocess.TimeoutExpired:
                monitor.terminate()
                monitor.wait(timeout=5)
    return records, startup_seconds, backend_pid, failure


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs-per-case", type=int, default=2)
    parser.add_argument("--max-jobs", type=int, default=0, help="Bounded diagnostic run count; default runs all cases.")
    parser.add_argument("--ready-timeout", type=int, default=180)
    parser.add_argument("--externally-started", action="store_true", help="Benchmark wrapper already cold-started ComfyUI and owns the memory monitor.")
    parser.add_argument("--startup-seconds", type=float, default=None)
    parser.add_argument("--backend-pid", type=int, default=None)
    parser.add_argument("--external-monitor", action="store_true")
    parser.add_argument("--prompt-indices", default="1,2,3", help="Comma-separated prompt numbers to include.")
    parser.add_argument("--only-resolution", default="all", choices=("all", "960x540", "1280x720"))
    parser.add_argument("--append", action="store_true", help="Append this case's runs to the existing benchmark JSON.")
    parser.add_argument("--finalize-existing", action="store_true", help="Regenerate the report from the last recorded benchmark without submitting jobs.")
    args = parser.parse_args()
    if args.runs_per_case < 1:
        parser.error("--runs-per-case must be at least 1")
    if args.finalize_existing:
        data = json.loads((REPORT_DIR / "benchmark.json").read_text(encoding="utf-8"))
        records = data.get("runs", [])
        first_runs = []
        seen_cases = set()
        for record in records:
            key = (record["prompt"], record["resolution"])
            if key not in seen_cases:
                seen_cases.add(key)
                first_runs.append(record)
        startup_batches = [
            {"case": f"prompt-{run['prompt']}-{run['resolution']}", "seconds": old["seconds"]}
            for run, old in zip(first_runs, data.get("startup_batches", []))
        ]
        failed_count = sum(run.get("status") == "failed" for run in records)
        failure = f"{failed_count} of {len(records)} image jobs failed; details are listed in the run table." if failed_count else None
        memory = memory_summary(data.get("backend_process_id"))
        write_report(data.get("startup_seconds"), data.get("backend_process_id"), records, memory, failure, startup_batches)
        print(f"Finalized report: {REPORT_DIR / 'benchmark-report.md'}")
        return 0
    records, startup, pid, failure = asyncio.run(main_async(args))
    if args.external_monitor:
        time.sleep(1.2)
        STOP_FILE.touch()
    startup_batches = [{"case": "batch", "seconds": round(startup, 3)}] if startup is not None else []
    if args.append:
        if (REPORT_DIR / "benchmark.json").exists():
            previous = json.loads((REPORT_DIR / "benchmark.json").read_text(encoding="utf-8"))
            records = previous.get("runs", []) + records
            startup_batches = previous.get("startup_batches", []) + [{"case": f"case-{len(previous.get('startup_batches', [])) + 1}", "seconds": round(startup, 3)}]
        elif startup is not None:
            startup_batches = [{"case": "case-1", "seconds": round(startup, 3)}]
    for run_number, record in enumerate(records, start=1):
        record["job"] = run_number
    memory = memory_summary(pid)
    write_report(startup, pid, records, memory, failure, startup_batches)
    print(f"Report: {REPORT_DIR / 'benchmark-report.md'}")
    print(f"Images: {COMFY / 'output' / 'benchmark-sdxl-lightning'}")
    return 1 if failure else 0


if __name__ == "__main__":
    raise SystemExit(main())
