import { isConfiguredOllama } from "@/lib/ollama-routing";
import { serverEnv } from "@/lib/server-env";
import { completeSdcppVulkanImage, submitSdcppVulkanImage } from "@/lib/sdcpp-vulkan";
import { localModelContextWindow } from "@/lib/text-models";
import type { GeneratedImage, StoryCharacter, StorySettings } from "@/lib/types";

const IMAGE_PROMPT_TRANSLATION_INSTRUCTION = `Create one 35–70-word storyboard prompt for a small local SDXL-Lightning image model. The completed story passage is the source of truth for what is visible in this image. The candidate storyboard may be stale or conflict with the passage; keep only details that agree with the passage and replace conflicting locations, actions, people, and objects with what the passage actually depicts. Show one frozen moment from the passage, not a future action or the previous scene.

Use this order: (1) subject and action, (2) composition and positions of characters/important objects, (3) two or three distinctive setting details, (4) shot type and viewing angle, (5) lighting, mood, and cinematic storybook style. Use clear, positive visual descriptions, prioritise the main action, and remove unnecessary complexity. Do not add facts, character biography, personality, hidden equipment, story lore, or details that cannot be seen. Do not restate canonical saved character details; Dungeon Crawl appends those separately. Output only the rewritten storyboard prompt.`;

function customChatEndpoint(baseUrl: string) {
  const url = baseUrl.trim().replace(/\/+$/, "");
  if (/\/chat\/completions$/.test(url)) return url;
  if (/\/v\d+$/.test(url)) return `${url}/chat/completions`;
  return `${url}/v1/chat/completions`;
}

export async function translateImagePrompt(
  description: string,
  settings: StorySettings,
  storyPassage?: string,
): Promise<string> {
  const userContent = storyPassage?.trim()
    ? `Completed story passage (source of truth):\n${storyPassage.trim().slice(0, 8_000)}\n\nCandidate storyboard prompt (may contain stale details; use only facts that match the passage):\n${description}`
    : description;
  const messages = [
    { role: "system", content: IMAGE_PROMPT_TRANSLATION_INSTRUCTION },
    { role: "user", content: userContent },
  ];
  const timeout = AbortSignal.timeout(120_000);

  if (settings.textProvider === "local") {
    const baseUrl = serverEnv("OLLAMA_BASE_URL", "http://127.0.0.1:11434").replace(/\/$/, "");
    const response = await fetch(`${baseUrl}/api/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: settings.localTextModel,
        messages,
        stream: false,
        keep_alive: "30m",
        think: false,
        options: {
          temperature: 0.2,
          num_predict: 256,
          num_ctx: localModelContextWindow(settings.localTextModel),
        },
      }),
      signal: timeout,
      cache: "no-store",
    });
    if (!response.ok) {
      throw new Error(`Image prompt translation failed (${response.status}).`);
    }
    const data = (await response.json()) as { message?: { content?: unknown } };
    const translated = typeof data.message?.content === "string" ? data.message.content.trim() : "";
    if (!translated) throw new Error("The text model returned an empty image prompt translation.");
    return translated;
  }

  const baseUrl = settings.customBaseUrl || serverEnv("OPENAI_COMPAT_BASE_URL");
  const configuredOllamaUrl = serverEnv("OLLAMA_BASE_URL", "http://127.0.0.1:11434");
  if (isConfiguredOllama(baseUrl, configuredOllamaUrl)) {
    const model = settings.customModel || serverEnv("OPENAI_COMPAT_MODEL");
    if (!model) throw new Error("No model name set for the configured Ollama backend.");
    const response = await fetch(`${configuredOllamaUrl.replace(/\/$/, "")}/api/chat`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...((settings.customApiKey || serverEnv("OPENAI_COMPAT_API_KEY"))
          ? { Authorization: `Bearer ${settings.customApiKey || serverEnv("OPENAI_COMPAT_API_KEY")}` }
          : {}),
      },
      body: JSON.stringify({
        model,
        messages,
        stream: false,
        keep_alive: "30m",
        think: false,
        options: { temperature: 0.2, num_predict: 256, num_ctx: localModelContextWindow(model) },
      }),
      signal: timeout,
      cache: "no-store",
    });
    if (!response.ok) throw new Error(`Image prompt translation failed (${response.status}).`);
    const data = (await response.json()) as { message?: { content?: unknown } };
    const translated = typeof data.message?.content === "string" ? data.message.content.trim() : "";
    if (!translated) throw new Error("The text model returned an empty image prompt translation.");
    return translated;
  }

  if (!baseUrl.trim()) throw new Error("No text backend URL is set for image prompt translation.");
  const isOpenRouter = /(^|\.)openrouter\.ai/i.test(baseUrl);
  const model = settings.customModel || serverEnv("OPENAI_COMPAT_MODEL") ||
    (isOpenRouter ? serverEnv("OPENROUTER_MODEL", "google/gemini-3.5-flash") : "");
  if (!model) throw new Error("No model name set for image prompt translation.");
  const apiKey = settings.customApiKey ||
    (isOpenRouter ? serverEnv("OPENROUTER_API_KEY") : "") || serverEnv("OPENAI_COMPAT_API_KEY");
  const response = await fetch(customChatEndpoint(baseUrl), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
      ...(isOpenRouter
        ? {
            "HTTP-Referer": serverEnv("OPENROUTER_APP_URL", "http://localhost:3000"),
            "X-Title": serverEnv("OPENROUTER_APP_TITLE", "Open Dungeon"),
          }
        : {}),
    },
    body: JSON.stringify({
      model,
      messages,
      temperature: 0.2,
      max_tokens: 256,
      ...(serverEnv("OPENAI_COMPAT_REASONING_EFFORT")
        ? { reasoning_effort: serverEnv("OPENAI_COMPAT_REASONING_EFFORT") }
        : {}),
    }),
    signal: timeout,
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`Image prompt translation failed (${response.status}).`);
  const data = (await response.json()) as { choices?: Array<{ message?: { content?: unknown } }> };
  const translated = typeof data.choices?.[0]?.message?.content === "string"
    ? data.choices[0].message.content.trim()
    : "";
  if (!translated) throw new Error("The text model returned an empty image prompt translation.");
  return translated;
}

export async function generateTranslatedStoryImage(
  description: string,
  settings: StorySettings,
  characters: StoryCharacter[] = [],
  storyPassage?: string,
): Promise<GeneratedImage> {
  const task = await submitTranslatedStoryImage(description, settings, characters, storyPassage);
  return completeSdcppVulkanImage(task);
}

export async function submitTranslatedStoryImage(
  description: string,
  settings: StorySettings,
  characters: StoryCharacter[] = [],
  storyPassage?: string,
) {
  const translatedPrompt = await translateImagePrompt(description, settings, storyPassage);
  return submitSdcppVulkanImage({ scenePrompt: translatedPrompt, characters });
}
