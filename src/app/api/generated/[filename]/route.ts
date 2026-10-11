import { readFile } from "node:fs/promises";
import path from "node:path";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type RouteContext = {
  params: Promise<{ filename: string }>;
};

export async function GET(_request: Request, context: RouteContext) {
  const { filename } = await context.params;
  if (!/^[A-Za-z0-9._-]+\.png$/i.test(filename) || filename.includes("..")) {
    return new Response("Not found.", { status: 404 });
  }

  const generatedDir = path.resolve(process.cwd(), "public", "generated");
  const imagePath = path.resolve(generatedDir, filename);
  if (!imagePath.startsWith(`${generatedDir}${path.sep}`)) {
    return new Response("Not found.", { status: 404 });
  }

  try {
    const image = await readFile(imagePath);
    return new Response(new Uint8Array(image), {
      headers: {
        "Content-Type": "image/png",
        "Content-Length": String(image.byteLength),
        "Cache-Control": "public, max-age=31536000, immutable",
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch {
    return new Response("Not found.", { status: 404 });
  }
}
