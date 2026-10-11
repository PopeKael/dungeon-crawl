import argparse
import json
import shutil
import time
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "http://127.0.0.1:18188"
PROMPTS = [
    ("prompt1_environment", "Wide establishing illustration of Aethelgard, an immense ancient city inside a subterranean cavern. Black basalt arches span deep chasms above glowing amber rivers. Crumbling towers and hanging gardens are illuminated by blue bioluminescent fungi. Vast scale, atmospheric depth, cinematic fantasy illustration, dramatic blue and amber lighting, no text, 16:9."),
    ("prompt2_mira", "Mira stands at the edge of a vast underground city holding a brass lantern. She is an adult woman with short black hair wearing a weathered brown leather travelling coat. Behind her, black basalt arches and ancient spires descend toward glowing amber rivers and blue bioluminescent gardens. Wide cinematic composition, lantern light on her face, sense of discovery and awe, fantasy storybook illustration, no text, 16:9."),
    ("prompt3_two_travellers", "Two travellers cross a narrow ancient basalt bridge suspended above a glowing amber river inside an enormous subterranean city. Mira, an adult woman with short black hair and a brown leather travelling coat, leads with a brass lantern. Behind her follows a weathered middle-aged male traveller in a dark travelling coat and hooded cloak. Blue bioluminescent fungi illuminate distant towers and arches. Dynamic wide shot, strong depth, cinematic fantasy storybook illustration, no text, 16:9."),
]
SIZES = [(1280, 720), (960, 540)]


def get_json(path):
    with urllib.request.urlopen(BASE + path, timeout=15) as response:
        return json.loads(response.read())


def post_json(path, body):
    request = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read())


def workflow(prompt, width, height, seed, prefix):
    return {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": "flux-2-klein-4b-fp8.safetensors", "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen_3_4b.safetensors", "type": "flux2", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": "flux2-vae.safetensors"}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["2", 0]}},
        "5": {"class_type": "EmptySD3LatentImage", "inputs": {"width": width, "height": height, "batch_size": 1}},
        "6": {"class_type": "KSampler", "inputs": {"model": ["1", 0], "positive": ["4", 0], "negative": ["4", 0], "latent_image": ["5", 0], "seed": seed, "steps": 4, "cfg": 1.0, "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}},
        "7": {"class_type": "VAEDecode", "inputs": {"samples": ["6", 0], "vae": ["3", 0]}},
        "8": {"class_type": "SaveImage", "inputs": {"images": ["7", 0], "filename_prefix": prefix}},
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--repeats", type=int, default=2)
    args = parser.parse_args()
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "comfy-output").mkdir(exist_ok=True)
    rows = []
    stats = get_json("/system_stats")
    device = stats.get("devices", [{}])[0]
    vram_total = device.get("vram_total")
    vram_free = device.get("vram_free")
    for name, prompt in PROMPTS:
        for width, height in SIZES:
            for repeat in range(1, args.repeats + 1):
                seed = 540000 + width + height + repeat * 1000 + len(rows)
                prefix = f"{name}_{width}x{height}_run{repeat}"
                start_free = None
                latest_free = None
                samples = []
                prompt_started = time.perf_counter()
                queued = post_json("/prompt", {"prompt": workflow(prompt, width, height, seed, prefix), "client_id": "dungeon-flux2-benchmark"})
                prompt_id = queued["prompt_id"]
                while time.perf_counter() - prompt_started < 1800:
                    try:
                        current = get_json("/system_stats").get("devices", [{}])[0]
                        latest_free = current.get("vram_free")
                        if latest_free is not None:
                            start_free = latest_free if start_free is None else start_free
                            samples.append(latest_free)
                    except Exception:
                        pass
                    history = get_json("/history/" + urllib.parse.quote(prompt_id))
                    entry = history.get(prompt_id)
                    if entry:
                        status = entry.get("status", {})
                        if status.get("status_str") == "error":
                            raise RuntimeError(json.dumps(status.get("messages", []), ensure_ascii=False))
                        images = [image for node in entry.get("outputs", {}).values() for image in node.get("images", [])]
                        if images:
                            generation_s = time.perf_counter() - prompt_started
                            image = images[0]
                            qs = urllib.parse.urlencode({"filename": image["filename"], "subfolder": image.get("subfolder", ""), "type": image.get("type", "output")})
                            with urllib.request.urlopen(BASE + "/view?" + qs, timeout=60) as response:
                                image_bytes = response.read()
                            filename = f"{name}_{width}x{height}_run{repeat}.png"
                            target = out / filename
                            target.write_bytes(image_bytes)
                            break
                        if status.get("completed"):
                            raise RuntimeError("ComfyUI completed the prompt without returning an image")
                    time.sleep(0.25)
                else:
                    raise TimeoutError("ComfyUI job exceeded 1800 seconds")
                idle = get_json("/system_stats").get("devices", [{}])[0]
                free_after = idle.get("vram_free")
                rows.append({"prompt": name, "width": width, "height": height, "repeat": repeat, "seed": seed, "generation_seconds": round(generation_s, 3), "output": str(target), "vram_total_bytes": vram_total, "vram_free_start_bytes": start_free, "vram_free_min_sample_bytes": min(samples) if samples else None, "vram_free_after_bytes": free_after, "peak_used_sample_bytes": (vram_total - min(samples)) if vram_total and samples else None, "workflow": {"model": "FLUX.2 Klein 4B Distilled FP8", "diffusion": "flux-2-klein-4b-fp8.safetensors", "text_encoder": "qwen_3_4b.safetensors", "vae": "flux2-vae.safetensors", "precision": "ComfyUI official FP8 diffusion checkpoint; text encoder/vae as official workflow", "sampler": "euler", "scheduler": "simple", "steps": 4, "cfg": 1.0, "seed": seed, "batch": 1}})
                print(json.dumps(rows[-1], ensure_ascii=False), flush=True)
    report = {"model": "FLUX.2 Klein 4B Distilled FP8", "backend": "Dungeon-owned ComfyUI", "rows": rows}
    (out / "runs.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Wrote {out / 'runs.json'}")


if __name__ == "__main__":
    main()
