import { execFile } from "node:child_process";
import { mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import sharp from "sharp";
import type { GeneratedImage, StoryCharacter } from "@/lib/types";

const execFileAsync = promisify(execFile);
const ROOT = process.cwd();
const LIFECYCLE_SCRIPT = path.join(ROOT, "scripts", "dungeon-sdcpp.ps1");
const SERVER_URL = "http://127.0.0.1:18191";
const IMAGE_WIDTH = 960;
const IMAGE_HEIGHT = 536;
const ENGINE_HEIGHT = 576;
const GENERATION_TIMEOUT_MS = 6 * 60 * 1000;
const POLL_INTERVAL_MS = 400;

type LifecycleResult = { ok: boolean; error?: string };
type SdcppImage = { b64_json?: string };
type SdcppJob = {
  id?: string;
  status?: string;
  error?: string | { message?: string };
  result?: { images?: SdcppImage[] };
};

function errorMessage(value: unknown, fallback: string) {
  return value instanceof Error ? value.message : fallback;
}

async function runLifecycle(action: "Ensure" | "Stop" | "Status") {
  if (process.platform !== "win32") {
    throw new Error("The Dungeon-owned Vulkan renderer is configured for this Windows RX 7800 XT runtime.");
  }

  let stdout = "";
  try {
    const result = await execFileAsync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", LIFECYCLE_SCRIPT, "-Action", action],
      { cwd: ROOT, windowsHide: true, timeout: action === "Ensure" ? 110_000 : 20_000, maxBuffer: 1024 * 1024 },
    );
    stdout = result.stdout;
  } catch (error) {
    const result = error as Error & { stdout?: string; stderr?: string };
    stdout = result.stdout || "";
    let detail = result.stderr?.trim() || result.message;
    try {
      const payload = JSON.parse(stdout.trim().split(/\r?\n/).at(-1) || "{}") as LifecycleResult;
      detail = payload.error || detail;
    } catch {
      // Keep the process-level diagnostic when no structured result was emitted.
    }
    throw new Error(detail);
  }

  let payload: LifecycleResult;
  try {
    payload = JSON.parse(stdout.trim().split(/\r?\n/).at(-1) || "{}") as LifecycleResult;
  } catch {
    throw new Error("Dungeon's image-backend lifecycle returned an invalid response.");
  }
  if (!payload.ok) throw new Error(payload.error || "Dungeon's image backend is not ready.");
  return payload;
}

export async function ensureSdcppVulkan() {
  return runLifecycle("Ensure");
}

export async function stopSdcppVulkan() {
  return runLifecycle("Stop");
}

function makePromptSlug(prompt: string) {
  return prompt.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48) || "story-image";
}

export function buildCanonicalImagePrompt(scenePrompt: string, characters: StoryCharacter[]) {
  const canonical = characters.flatMap((character) => {
    const fields = [
      ["Appearance", character.appearance],
      ["Wearing", character.wearing],
      ["Equipped", character.equipped],
    ] as const;
    const known = fields
      .map(([label, value]) => [label, value.trim().slice(0, 1200)] as const)
      .filter(([, value]) => value.length > 0);
    if (!known.length) return [];
    return [`${character.name}:`, ...known.map(([label, value]) => `${label}: ${value}`)];
  });

  if (!canonical.length) return scenePrompt.trim();
  return [scenePrompt.trim(), "Canonical saved character details (use only the facts listed):", ...canonical].join("\n");
}

async function postJson<T>(url: string, body: unknown, timeoutMs: number): Promise<T> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
    cache: "no-store",
  });
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 1000);
    throw new Error(`stable-diffusion.cpp returned ${response.status}: ${detail}`);
  }
  return (await response.json()) as T;
}

async function getJob(jobId: string): Promise<SdcppJob> {
  const response = await fetch(`${SERVER_URL}/sdcpp/v1/jobs/${encodeURIComponent(jobId)}`, {
    cache: "no-store",
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    throw new Error(`stable-diffusion.cpp job lookup returned ${response.status}. The image request can be retried.`);
  }
  return (await response.json()) as SdcppJob;
}

export async function generateSdcppVulkanImage(options: {
  scenePrompt: string;
  characters: StoryCharacter[];
}): Promise<GeneratedImage> {
  const lifecycleStartedAt = Date.now();
  await ensureSdcppVulkan();

  const prompt = buildCanonicalImagePrompt(options.scenePrompt, options.characters);
  const seed = crypto.getRandomValues(new Uint32Array(1))[0] % 2_147_483_647;
  const startedAt = Date.now();
  const accepted = await postJson<{ id?: string }>(`${SERVER_URL}/sdcpp/v1/img_gen`, {
    prompt,
    negative_prompt: "",
    clip_skip: -1,
    width: IMAGE_WIDTH,
    height: IMAGE_HEIGHT,
    strength: 1,
    seed,
    batch_count: 1,
    sample_params: {
      scheduler: "sgm_uniform",
      sample_method: "euler",
      sample_steps: 4,
      guidance: { txt_cfg: 1 },
    },
    vae_tiling_params: { enabled: false, tile_size_w: 256, tile_size_h: 256, target_overlap: 0.5 },
    preview: "none",
    output_format: "png",
    output_compression: 100,
  }, 30_000);

  if (!accepted.id) throw new Error("stable-diffusion.cpp accepted no image job ID.");
  const deadline = Date.now() + GENERATION_TIMEOUT_MS;
  let job: SdcppJob | null = null;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
    job = await getJob(accepted.id);
    if (["failed", "error", "cancelled"].includes((job.status || "").toLowerCase())) {
      const error = typeof job.error === "string" ? job.error : job.error?.message;
      throw new Error(error || "stable-diffusion.cpp could not generate this image. You can retry from the passage.");
    }
    if ((job.status || "").toLowerCase() === "completed") break;
  }

  if (!job || (job.status || "").toLowerCase() !== "completed") {
    throw new Error("Image generation timed out. The story is saved; retry this image from its passage.");
  }

  const encoded = job.result?.images?.[0]?.b64_json;
  if (!encoded) throw new Error("The renderer completed without returning a PNG.");
  const sourceBytes = Buffer.from(encoded.replace(/^data:image\/png;base64,/, ""), "base64");
  const metadata = await sharp(sourceBytes, { failOn: "error" }).metadata();
  if (metadata.format !== "png" || !metadata.width || !metadata.height) {
    throw new Error("The renderer returned an invalid PNG image.");
  }

  let outputBytes: Buffer;
  if (metadata.width === IMAGE_WIDTH && metadata.height === ENGINE_HEIGHT) {
    outputBytes = await sharp(sourceBytes)
      .extract({ left: 0, top: 20, width: IMAGE_WIDTH, height: IMAGE_HEIGHT })
      .png()
      .toBuffer();
  } else if (metadata.width === IMAGE_WIDTH && metadata.height === IMAGE_HEIGHT) {
    outputBytes = sourceBytes;
  } else {
    throw new Error(`The renderer returned ${metadata.width}×${metadata.height}; expected 960×576 before crop.`);
  }

  const generatedDir = path.join(ROOT, "public", "generated");
  mkdirSync(generatedDir, { recursive: true });
  const id = crypto.randomUUID();
  const filename = `${Date.now()}-${seed}-sdcpp-${makePromptSlug(prompt)}-${id.slice(0, 8)}.png`;
  const outputPath = path.join(generatedDir, filename);
  try {
    writeFileSync(outputPath, outputBytes, { flag: "wx" });
  } catch (error) {
    throw new Error(`Could not save the generated image: ${errorMessage(error, "file write failed")}`);
  }

  return {
    id,
    url: `/api/generated/${filename}`,
    prompt,
    mode: "fast",
    backend: "sd-cpp-vulkan",
    aspect: "landscape",
    width: IMAGE_WIDTH,
    height: IMAGE_HEIGHT,
    elapsedSeconds: Math.round((Date.now() - startedAt) / 100) / 10,
    seed,
    warnings: Date.now() - lifecycleStartedAt > 30_000 ? ["Image backend startup was unusually slow."] : undefined,
  };
}

export function discardGeneratedImage(url: string) {
  const prefix = url.startsWith("/api/generated/")
    ? "/api/generated/"
    : url.startsWith("/generated/")
      ? "/generated/"
      : null;
  if (!prefix) return;
  const generatedDir = path.resolve(ROOT, "public", "generated");
  const imagePath = path.resolve(generatedDir, url.slice(prefix.length));
  if (!imagePath.startsWith(`${generatedDir}${path.sep}`)) return;
  try { unlinkSync(imagePath); } catch { /* best effort cleanup after persistence failure */ }
}
