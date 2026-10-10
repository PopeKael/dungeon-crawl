import { spawn } from "node:child_process";
import path from "node:path";
import { z } from "zod";
import { getChat } from "@/lib/db";
import { serverEnv } from "@/lib/server-env";

export const runtime = "nodejs";

const schema = z.object({ chatId: z.string().uuid(), messageId: z.string().uuid() });
let reading = false;

export async function POST(request: Request) {
  // A website must not be able to trigger host keyboard input cross-origin.
  const allowedOrigins = new Set([
    "http://127.0.0.1:3000", "http://localhost:3000",
    serverEnv("APP_ORIGIN", "https://dungeon.dia.net.au"),
  ]);
  if (!allowedOrigins.has(request.headers.get("origin") || "") ||
      request.headers.get("sec-fetch-site") === "cross-site") {
    return Response.json({ error: "Reader requests must come from the game page." }, { status: 403 });
  }
  if (process.platform !== "win32" || serverEnv("WINDOWS_READER_ENABLED") !== "true") {
    return Response.json({ error: "Windows reader handoff is not enabled on this host. Press Alt+F1 with the passage selected." }, { status: 503 });
  }
  const parsed = schema.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return Response.json({ error: "Invalid passage selection." }, { status: 400 });
  const message = getChat(parsed.data.chatId)?.messages.find((item) =>
    item.id === parsed.data.messageId && item.role === "assistant");
  if (!message) return Response.json({ error: "Narrator passage not found." }, { status: 404 });
  // Match the prose renderer: remove only supported emphasis delimiters.
  const text = message.content.replace(/\*\*([^*\n]+)\*\*|\*([^*\n]+)\*/g, (_, bold, italic) => bold ?? italic).trim();
  if (!text || text.length > 100_000) {
    return Response.json({ error: "Passage is empty or too large to read." }, { status: 400 });
  }
  if (reading) return Response.json({ error: "A reader handoff is already in progress." }, { status: 409 });
  reading = true;
  try {
    const result = await new Promise<{ ok: boolean; message: string }>((resolve, reject) => {
      const child = spawn("powershell.exe", ["-NoProfile", "-NonInteractive", "-STA", "-ExecutionPolicy", "Bypass",
        "-File", path.join(process.cwd(), "scripts", "read-passage.ps1")],
      { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] });
      let output = "";
      const timer = setTimeout(() => { child.kill(); reject(new Error("Reader timed out.")); }, 15_000);
      child.stdout.setEncoding("utf8").on("data", (chunk) => { output += chunk; });
      child.stderr.resume();
      child.stdin.on("error", () => { /* Process failure is handled below. */ });
      child.on("error", (error) => { clearTimeout(timer); reject(error); });
      child.on("close", () => {
        clearTimeout(timer);
        try { resolve(JSON.parse(output.trim())); } catch { reject(new Error("Reader helper failed.")); }
      });
      child.stdin.end(JSON.stringify({ textBase64: Buffer.from(text, "utf8").toString("base64") }));
    });
    return Response.json(result, { status: result.ok ? 200 : 503 });
  } catch {
    return Response.json({ error: "Windows reader handoff failed. The prose is selected; press Alt+F1 manually." }, { status: 503 });
  } finally {
    reading = false;
  }
}
