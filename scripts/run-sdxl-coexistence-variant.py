"""Submit one fixed SDXL-Lightning job to the local Dungeon ComfyUI backend."""
from __future__ import annotations

import argparse
import asyncio
import json
import struct
import time
import uuid
from pathlib import Path

import aiohttp

ROOT = Path(__file__).resolve().parents[1]
COMFY = ROOT / "runtime" / "sdxl-lightning" / "ComfyUI"
PROMPT = (
    "Wide establishing illustration of Aethelgard, an immense ancient city inside a subterranean cavern. "
    "Black basalt arches span deep chasms above glowing amber rivers. Crumbling towers and hanging gardens "
    "are illuminated by blue bioluminescent fungi. Vast scale, atmospheric depth, cinematic fantasy "
    "illustration, dramatic blue and amber lighting, no text, 16:9."
)
MODEL = "sdxl_lightning_4step.safetensors"


def make_graph(seed: int, prefix: str, vae_node: str, tile_size: int, overlap: int) -> dict:
    vae_inputs = {"samples": ["5", 0], "vae": ["1", 2]}
    if vae_node == "VAEDecodeTiled":
        vae_inputs.update(tile_size=tile_size, overlap=overlap)
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": MODEL}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": PROMPT, "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "", "clip": ["1", 1]}},
        "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 960, "height": 540, "batch_size": 1}},
        "5": {
            "class_type": "KSampler",
            "inputs": {
                "model": ["1", 0], "positive": ["2", 0], "negative": ["3", 0],
                "latent_image": ["4", 0], "seed": seed, "steps": 4, "cfg": 1.0,
                "sampler_name": "euler", "scheduler": "sgm_uniform", "denoise": 1.0,
            },
        },
        "6": {"class_type": vae_node, "inputs": vae_inputs},
        "7": {"class_type": "ImageScale", "inputs": {"image": ["6", 0], "upscale_method": "lanczos", "width": 960, "height": 540, "crop": "disabled"}},
        "8": {"class_type": "SaveImage", "inputs": {"images": ["7", 0], "filename_prefix": prefix}},
    }


async def submit(args: argparse.Namespace) -> dict:
    base_url = f"http://127.0.0.1:{args.port}"
    client_id = str(uuid.uuid4())
    graph = make_graph(args.seed, args.prefix, args.vae_node, args.tile_size, args.overlap)
    timeout = aiohttp.ClientTimeout(total=300)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        await session.get(f"{base_url}/system_stats")
        ws = await session.ws_connect(f"{base_url}/ws?clientId={client_id}", heartbeat=30)
        started = time.perf_counter()
        node_starts: dict[str, float] = {}
        node_seconds: dict[str, float] = {}
        active_node: str | None = None
        prompt_id = None
        failure = None
        try:
            async with session.post(f"{base_url}/prompt", json={"prompt": graph, "client_id": client_id}) as response:
                body = await response.json()
                if response.status >= 400:
                    raise RuntimeError(f"Comfy rejected job: {body}")
                prompt_id = body["prompt_id"]
            async for message in ws:
                if message.type != aiohttp.WSMsgType.TEXT:
                    if message.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSED):
                        failure = f"WebSocket closed: {message.data}"
                        break
                    continue
                event = json.loads(message.data)
                data = event.get("data", {})
                if data.get("prompt_id") != prompt_id:
                    continue
                now = time.perf_counter()
                if event.get("type") == "executing":
                    node = data.get("node")
                    if node is None:
                        if active_node is not None and active_node in node_starts:
                            node_seconds[active_node] = now - node_starts[active_node]
                        break
                    node = str(node)
                    if active_node is not None and active_node in node_starts:
                        node_seconds[active_node] = now - node_starts[active_node]
                    node_starts[node] = now
                    active_node = node
                elif event.get("type") == "executed":
                    node = str(data.get("node"))
                    if node in node_starts:
                        node_seconds[node] = now - node_starts[node]
                elif event.get("type") == "execution_error":
                    failure = data.get("exception_message") or data.get("exception_type") or "Comfy execution failed"
                    break
        finally:
            await ws.close()
        elapsed = time.perf_counter() - started
        if not prompt_id:
            raise RuntimeError("Comfy did not return a prompt id")
        try:
            async with session.get(f"{base_url}/history/{prompt_id}") as response:
                history = await response.json()
        except Exception as exc:
            history = {}
            failure = failure or f"Could not read prompt history: {exc}"

    job = history.get(prompt_id, {})
    images = []
    for output in job.get("outputs", {}).values():
        for item in output.get("images", []):
            path = COMFY / "output" / item.get("subfolder", "") / item["filename"]
            if path.is_file():
                images.append(path)
    valid = False
    dimensions = None
    if images:
        try:
            from PIL import Image

            with Image.open(images[0]) as image:
                image.verify()
            with images[0].open("rb") as file:
                header = file.read(24)
            if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
                raise ValueError("PNG signature or IHDR is invalid")
            dimensions = struct.unpack(">II", header[16:24])
            valid = dimensions == (960, 540)
        except Exception as exc:
            failure = failure or f"PNG validation failed: {exc}"
    if not images and not failure:
        failure = f"Job produced no saved image; history status={job.get('status')}"
    return {
        "seed": args.seed,
        "prompt": PROMPT,
        "model": MODEL,
        "resolution": "960x540",
        "vae_node": args.vae_node,
        "total_seconds": round(elapsed, 3),
        "sampling_seconds": round(node_seconds.get("5", 0), 3) or None,
        "vae_decode_seconds": round(node_seconds.get("6", 0), 3) or None,
        "output": str(images[0]) if images else None,
        "png_valid": valid,
        "output_file_valid": bool(images and dimensions is not None),
        "png_dimensions": dimensions,
        "failure": failure,
        "node_seconds": node_seconds,
        "prompt_id": prompt_id,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18189)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--vae-node", choices=("VAEDecode", "VAEDecodeTiled"), default="VAEDecode")
    parser.add_argument("--tile-size", type=int, default=512)
    parser.add_argument("--overlap", type=int, default=64)
    args = parser.parse_args()
    result = asyncio.run(submit(args))
    print(json.dumps(result, ensure_ascii=False), flush=True)
    if not result["png_valid"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
