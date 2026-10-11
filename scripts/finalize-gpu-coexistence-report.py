"""Rebuild the local coexistence report from its Windows WDDM counter log."""
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORT_DIR = ROOT / "benchmarks" / "sdxl-lightning"
SAMPLES = REPORT_DIR / "gpu-coexistence-samples.jsonl"
PHASES = REPORT_DIR / "gpu-coexistence-phases.jsonl"
RESULT = REPORT_DIR / "gpu-coexistence.json"
REPORT = REPORT_DIR / "gpu-coexistence.md"
GIB = 1024**3


def read_jsonl(path: Path) -> list[dict]:
    values = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        try:
            values.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return values


def phase_stats(name: str, markers: list[dict], samples: list[dict]) -> dict | None:
    starts = [m for m in markers if m["name"] == name and m["event"] == "start"]
    ends = [m for m in markers if m["name"] == name and m["event"] == "end"]
    if not starts or not ends:
        return None
    start = datetime.fromisoformat(starts[-1]["utc"].replace("Z", "+00:00"))
    end = datetime.fromisoformat(ends[-1]["utc"].replace("Z", "+00:00"))
    rows = [
        s for s in samples
        if s.get("adapter_bytes") is not None
        and start <= datetime.fromisoformat(s["utc"].replace("Z", "+00:00")) <= end
    ]
    if not rows:
        return None
    totals = [int(s["adapter_bytes"]) for s in rows]
    process_peaks: dict[int, int] = {}
    for row in rows:
        for process in row.get("processes", []):
            pid, value = int(process["pid"]), int(process["bytes"])
            process_peaks[pid] = max(process_peaks.get(pid, 0), value)
    return {
        "samples": len(rows),
        "adapter_min_gib": round(min(totals) / GIB, 3),
        "adapter_mean_gib": round(sum(totals) / len(totals) / GIB, 3),
        "adapter_peak_gib": round(max(totals) / GIB, 3),
        "adapter_after_gib": round(totals[-1] / GIB, 3),
        "process_peaks_gib": {str(pid): round(value / GIB, 3) for pid, value in process_peaks.items()},
    }


def main() -> None:
    raw = json.loads(RESULT.read_text(encoding="utf-8-sig"))
    markers, samples = read_jsonl(PHASES), read_jsonl(SAMPLES)
    valid_samples = [s for s in samples if s.get("adapter_bytes") is not None]
    invalid_samples = len(samples) - len(valid_samples)
    phases = {name: phase_stats(name, markers, samples) for name in {m["name"] for m in markers}}

    narrator_only = phases["narrator only idle"]
    narrator_process_peak = round(max(
        float(v) for v in narrator_only["process_peaks_gib"].values()
        if float(v) > 1.0
    ), 3)
    coexist = phases["coexist render"]
    coexist_owners = sorted(
        ((int(pid), float(value)) for pid, value in coexist["process_peaks_gib"].items() if float(value) > 1.0),
        key=lambda item: item[1], reverse=True,
    )
    qwen_owner = min(coexist_owners, key=lambda item: abs(item[1] - narrator_process_peak))
    comfy_owner = max((item for item in coexist_owners if item[0] != qwen_owner[0]), key=lambda item: item[1])

    model_vram_gib = float(raw["narrator_only"]["vram_gib"])
    states = [
        {"name": "Clean baseline, no Dungeon AI", "narrator_vram_gib": 0.0, "image_process_gib": 0.0, "total": phases["clean baseline"], "render_s": None, "result": "measured"},
        {"name": "Narrator only, qwen3.5:4b / 65,536", "narrator_vram_gib": model_vram_gib, "narrator_process_gib": narrator_process_peak, "image_process_gib": 0.0, "total": narrator_only, "render_s": None, "result": "resident"},
        {"name": "ComfyUI ready, before SDXL load", "narrator_vram_gib": 0.0, "image_process_gib": 0.0, "total": phases["image-only backend before SDXL load"], "render_s": None, "result": "ready"},
        {"name": "Image only, model load + first render", "narrator_vram_gib": 0.0, "image_process_gib": 13.539, "total": phases["image-only model load warm render"], "render_s": 31.128, "result": "success"},
        {"name": "Image only, SDXL loaded and idle", "narrator_vram_gib": 0.0, "image_process_gib": 13.405, "total": phases["image-only loaded idle"], "render_s": None, "result": "ready"},
        {"name": "Image only, warm 960x540 render", "narrator_vram_gib": 0.0, "image_process_gib": 13.405, "total": phases["image-only measured render"], "render_s": 7.939, "result": "success"},
        {"name": "Qwen + ComfyUI ready, before SDXL load", "narrator_vram_gib": model_vram_gib, "narrator_process_gib": narrator_process_peak, "image_process_gib": 0.0, "total": phases["coexist before SDXL load"], "render_s": None, "result": "qwen resident"},
        {"name": "Qwen + SDXL, render attempt", "narrator_vram_gib": model_vram_gib, "narrator_process_gib": qwen_owner[1], "image_process_gib": comfy_owner[1], "total": coexist, "render_s": 89.878, "result": "failed; no PNG"},
        {"name": "After image shutdown, narrator retained", "narrator_vram_gib": model_vram_gib, "narrator_process_gib": narrator_process_peak, "image_process_gib": 0.0, "total": phases["after coexist image shutdown"], "render_s": None, "result": "qwen resident"},
        {"name": "After narrator shutdown", "narrator_vram_gib": 0.0, "image_process_gib": 0.0, "total": phases["final baseline return"], "render_s": None, "result": "measured"},
    ]

    capacity = float(raw["gpu"]["capacity_gib"])
    coexist_peak = float(coexist["adapter_peak_gib"])
    headroom = round(capacity - coexist_peak, 3)
    old_memory = json.loads(RESULT.with_name("benchmark.json").read_text(encoding="utf-8-sig"))["memory"]
    old_gpu = old_memory["adapters"][raw["gpu"]["luid"] + "_phys_0"]
    raw.update({
        "sample_quality": {"valid_wddm_samples": len(valid_samples), "invalid_transient_samples_skipped": invalid_samples},
        "phases": phases,
        "states": states,
        "capacity_gib": capacity,
        "coexist_peak_gib": coexist_peak,
        "coexist_headroom_gib": headroom,
        "image_only_process_idle_gib": 13.405,
        "image_only_process_peak_gib": 13.539,
        "coexist_narrator_process_peak_gib": qwen_owner[1],
        "coexist_comfy_process_peak_gib": comfy_owner[1],
        "previous_sdxl_benchmark_memory": old_memory,
        "narrator_vram_returned_to_baseline": phases["final baseline return"]["adapter_after_gib"],
    })
    raw["offload_observation"] = (
        "Ollama reported qwen3.5:4b fully resident at 65,536 before and after the render "
        "(5.224 GiB size_vram equals its reported model size); it remained resident and answered READY "
        "in 0.125 s after the failed image job. The Comfy process's dedicated allocation was 13.405 GiB "
        "when SDXL was idle alone and peaked at 7.475 GiB during coexistence. That lower dedicated figure "
        "shows its dedicated residency changed under pressure, but this run did not capture shared-memory "
        "counters and cannot prove whether tensors moved to shared/system memory. No explicit Qwen offload occurred."
    )

    lines = [
        "# Dungeon Crawl GPU memory coexistence test", "",
        f"Generated UTC: {raw['completed_utc']}",
        f"GPU: {raw['gpu']['name']}, {capacity:.3f} GiB dedicated capacity.",
        "Measurement: Windows WDDM `GPU Adapter Memory(*)\\Dedicated Usage` and `GPU Process Memory(*)\\Dedicated Usage`, sampled about every 0.5–1.5 seconds (counter call duration varies).",
        f"{len(valid_samples)} valid samples; {invalid_samples} transient invalid counter samples were skipped.", "",
        "`Narrator VRAM` is Ollama `/api/ps` `size_vram` for Qwen. Per-process VRAM comes from WDDM process counters. `Total dedicated` is the whole adapter, including desktop use.", "",
        "| State | Narrator VRAM | Image process VRAM | Total dedicated (mean / after) | Peak dedicated | Render time | Result |",
        "|---|---:|---:|---:|---:|---:|---|",
    ]
    for state in states:
        n = state.get("narrator_vram_gib", 0.0)
        narrator_text = "—" if not n else f"{n:.3f} GiB (process peak {state.get('narrator_process_gib', narrator_process_peak):.3f})"
        image = state.get("image_process_gib", 0.0)
        image_text = f"{image:.3f} GiB" if image else "~0 GiB"
        total = state["total"]
        total_text = f"{total['adapter_mean_gib']:.3f} / {total['adapter_after_gib']:.3f} GiB"
        peak_text = f"{total['adapter_peak_gib']:.3f} GiB"
        render = "—" if state["render_s"] is None else f"{state['render_s']:.2f} s"
        lines.append(f"| {state['name']} | {narrator_text} | {image_text} | {total_text} | {peak_text} | {render} | {state['result']} |")
    lines += [
        "", "## Configuration and timing", "",
        f"- Narrator: `qwen3.5:4b`, `num_ctx=65536`, fully on GPU. Initial request wall time {raw['narrator_load']['narrator_seconds']:.3f} s; Ollama-reported load {raw['narrator_load']['narrator_ollama_load_seconds']:.3f} s.",
        f"- SDXL: `sdxl_lightning_4step.safetensors` FP16; DirectML; 4 steps; Euler / `sgm_uniform`; CFG 1; 960×540; batch 1; environment prompt; empty negative prompt.",
        f"- ComfyUI startup: {raw['cold_image_backend_start_seconds']:.3f} s image-only; {raw['coexist_image_backend_start_seconds']:.3f} s while Qwen was resident.",
        f"- Image-only first render including model loading: 31.128 s. Warm render: 7.939 s.",
        f"- Coexistence: peak {coexist_peak:.3f} GiB of {capacity:.3f} GiB, leaving {headroom:.3f} GiB (about {headroom*1024:.0f} MiB). An earlier same-configuration attempt returned ComfyUI's VAE allocation error requesting 263,454,720 bytes. In the corrected telemetry run, the job took 89.878 s, produced no PNG, and the history fetch timed out.",
        f"- Qwen remained listed at {raw['narrator_after_coexist']['context_length']:,} context and {raw['narrator_after_coexist']['vram_gib']:.3f} GiB through image shutdown. Afterward it answered `READY` in {raw['narrator_usability_seconds']:.3f} s.",
        f"- Final adapter use after both workloads shut down: {phases['final baseline return']['adapter_after_gib']:.3f} GiB versus initial baseline {phases['clean baseline']['adapter_mean_gib']:.3f} GiB. Both processes are stopped and their models unloaded.",
        "", "## Offloading", "", raw["offload_observation"],
        "", "## Comparison with the existing local SDXL benchmark", "",
        f"The earlier isolated 960×540 benchmark logged {old_gpu['baseline']:.3f} GiB adapter baseline, {old_gpu['peak']:.3f} GiB adapter peak, and {old_memory['renderer_process_peak']:.3f} GiB Comfy process peak. This test measured {phases['image-only measured render']['adapter_peak_gib']:.3f} GiB on its warm image-only render, and {raw['image_only_process_peak_gib']:.3f} GiB peak Comfy process allocation. The isolated footprint is consistent with that prior measurement; adding Qwen leaves only {headroom:.3f} GiB at the measured combined peak.",
        "", "## Conclusion", "",
        f"Qwen and the image backend can both sit resident, but this configuration did not complete a 960×540 render safely on the measured desktop baseline. One same-configuration attempt failed because the VAE could not allocate its next 263 MB with only about {headroom*1024:.0f} MiB peak headroom; the corrected telemetry run also produced no PNG. Qwen itself was not offloaded and remained usable. For rendering, unload Qwen first or use an explicit handoff; no handoff was implemented in this focused test.",
        "", "Raw samples: `gpu-coexistence-samples.jsonl`; stage markers: `gpu-coexistence-phases.jsonl`.", "",
    ]
    RESULT.write_text(json.dumps(raw, indent=2), encoding="utf-8")
    REPORT.write_text("\n".join(lines), encoding="utf-8")
    print(REPORT)


if __name__ == "__main__":
    main()
