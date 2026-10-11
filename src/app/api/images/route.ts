import { z } from "zod";
import { getChat, updateMessageGeneratedImage } from "@/lib/db";
import { discardGeneratedImage, generateSdcppVulkanImage } from "@/lib/sdcpp-vulkan";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const requestSchema = z.object({
  chatId: z.string().min(1),
  messageId: z.string().min(1),
});

export async function POST(request: Request) {
  const body = requestSchema.parse(await request.json());
  const chat = getChat(body.chatId);
  if (!chat) return Response.json({ error: "Story not found." }, { status: 404 });

  const message = chat.messages.find((item) => item.id === body.messageId);
  if (!message || message.role !== "assistant") {
    return Response.json({ error: "Story passage not found." }, { status: 404 });
  }
  if (!message.imageRequest?.needed || !message.imageRequest.prompt) {
    return Response.json({ error: "This passage has no saved image request." }, { status: 409 });
  }

  const requestedIds = new Set(message.imageRequest.characterIds || []);
  const characters = chat.characters.filter((character) => requestedIds.has(character.id)).slice(0, 2);
  let generatedImage;
  try {
    generatedImage = await generateSdcppVulkanImage({
      scenePrompt: message.imageRequest.prompt,
      characters,
    });
  } catch (error) {
    return Response.json(
      { error: error instanceof Error ? error.message : "The Vulkan image renderer failed." },
      { status: 502 },
    );
  }

  if (!updateMessageGeneratedImage(body.messageId, generatedImage)) {
    discardGeneratedImage(generatedImage.url);
    return Response.json({ error: "The image was generated, but its story passage is no longer available." }, { status: 409 });
  }

  return Response.json(generatedImage);
}
