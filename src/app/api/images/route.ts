import { z } from "zod";
import { getChat, listCharacters, updateMessageGeneratedImage } from "@/lib/db";
import { discardGeneratedImage, generateSdcppVulkanImage } from "@/lib/sdcpp-vulkan";
import { generateTranslatedStoryImage } from "@/lib/image-prompt-translation";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const requestSchema = z.object({
  chatId: z.string().min(1),
  messageId: z.string().min(1),
  traceId: z.string().max(100).optional(),
  sourceImageId: z.string().min(1).optional(),
  prompt: z.string().min(1).max(10_000).optional(),
});

export async function POST(request: Request) {
  const body = requestSchema.parse(await request.json());
  const startedAt = performance.now();
  const logTiming = (event: string, details: Record<string, unknown> = {}) => {
    console.info("[dungeon-image-job]", JSON.stringify({
      traceId: body.traceId || null,
      event,
      elapsedMs: Math.round(performance.now() - startedAt),
      ...details,
    }));
  };
  logTiming("image_request_received", { regeneration: body.sourceImageId !== undefined });
  const chat = getChat(body.chatId);
  if (!chat) return Response.json({ error: "Story not found." }, { status: 404 });

  const message = chat.messages.find((item) => item.id === body.messageId);
  if (!message || message.role !== "assistant") {
    return Response.json({ error: "Story passage not found." }, { status: 404 });
  }
  if (!message.imageRequest?.needed || !message.imageRequest.prompt) {
    return Response.json({ error: "This passage has no saved image request." }, { status: 409 });
  }

  const isRegeneration = body.sourceImageId !== undefined || body.prompt !== undefined;
  if (isRegeneration && (!body.sourceImageId || body.prompt === undefined)) {
    return Response.json({ error: "Choose an existing image and provide its prompt." }, { status: 400 });
  }

  const savedImages = message.generatedImages || (message.generatedImage ? [message.generatedImage] : []);
  const sourceImage = isRegeneration
    ? savedImages.find((image) => image.id === body.sourceImageId)
    : undefined;
  if (isRegeneration && !sourceImage) {
    return Response.json({ error: "The source image was not found on this passage." }, { status: 404 });
  }
  if (isRegeneration && typeof sourceImage?.seed !== "number") {
    return Response.json({ error: "The source image has no saved seed to reuse." }, { status: 409 });
  }

  let generatedImage;
  try {
    logTiming("translation_and_render_started");
    if (isRegeneration) {
      // Manual regeneration uses the user's exact edit and never invokes a text model.
      generatedImage = await generateSdcppVulkanImage({
        prompt: body.prompt,
        seed: sourceImage!.seed,
        generationSettings: sourceImage!.generationSettings,
      });
    } else {
      // The saved rich description is translated in a separate, history-free
      // request before the image generator receives only the translated text.
      const selectedCharacters = listCharacters(body.chatId).filter((character) =>
        message.imageRequest?.characterIds?.includes(character.id),
      ).slice(0, 2);
      generatedImage = await generateTranslatedStoryImage(
        message.imageRequest.prompt,
        chat.settings,
        selectedCharacters,
        message.content,
      );
    }
  } catch (error) {
    logTiming("image_job_failed", {
      errorType: error instanceof Error ? error.name : "unknown",
    });
    return Response.json(
      { error: error instanceof Error ? error.message : "The Vulkan image renderer failed." },
      { status: 502 },
    );
  }

  if (!updateMessageGeneratedImage(body.messageId, generatedImage)) {
    logTiming("image_discarded_missing_passage");
    discardGeneratedImage(generatedImage.url);
    return Response.json({ error: "The image was generated, but its story passage is no longer available." }, { status: 409 });
  }

  logTiming("image_job_completed");
  return Response.json(generatedImage);
}
