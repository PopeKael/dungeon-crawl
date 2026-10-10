// Match only the configured library server, including any reverse-proxy path.
// Other OpenAI-compatible providers must retain their existing protocol.
export function isConfiguredOllama(customUrl: string, ollamaUrl: string): boolean {
  const normalize = (value: string) => {
    const url = new URL(value);
    if (url.search || url.hash || url.username || url.password) return null;
    if (url.hostname === "localhost") url.hostname = "127.0.0.1";
    url.pathname = url.pathname.replace(/\/+$/, "").replace(/\/v1(?:\/chat\/completions)?$/, "");
    return url.href.replace(/\/+$/, "");
  };
  try {
    const custom = normalize(customUrl);
    return custom !== null && custom === normalize(ollamaUrl);
  } catch {
    return false;
  }
}

// Approximate English prose budget. Reserve space for instructions, characters,
// summary and output; this is not an exact tokenizer-based admission check.
export function ollamaHistoryCharBudget(contextTokens: number, outputTokens: number): number {
  const reserve = Math.max(8_192, outputTokens + 4_096);
  return Math.max(0, Math.floor((contextTokens - reserve) * 0.9 * 3.6));
}
