import { serverEnv } from "@/lib/server-env";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Read only the configured Ollama library; never accept a fetch URL from the browser.
export async function GET() {
  const baseUrl = serverEnv("OLLAMA_BASE_URL", "http://127.0.0.1:11434").replace(/\/$/, "");
  try {
    const response = await fetch(`${baseUrl}/api/tags`, {
      cache: "no-store", signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error("Library unavailable");
    const data = await response.json() as { models?: { name?: string }[] };
    const names = [...new Set((data.models ?? []).map(model => model.name).filter((name): name is string => typeof name === "string" && !!name))];
    const models = await Promise.all(names.map(async (name) => {
      const detailsResponse = await fetch(`${baseUrl}/api/show`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ model: name }), cache: "no-store", signal: AbortSignal.timeout(5000),
      });
      if (!detailsResponse.ok) throw new Error("Model details unavailable");
      const details = await detailsResponse.json() as { capabilities?: string[] };
      return details.capabilities?.includes("completion") ? name : null;
    }));
    return Response.json({ baseUrl, models: models.filter((name): name is string => name !== null).sort() });
  } catch {
    return Response.json({ error: "Could not read the Ollama model library. Check that Ollama is running, then refresh the list." }, { status: 503 });
  }
}
