// Exercise the real story route with a captured upstream fetch and no database writes.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import ts from 'typescript';

const require = createRequire(import.meta.url);
const cache = new Map();
const env = {
  OLLAMA_BASE_URL: 'http://127.0.0.1:11434', LOCAL_TEXT_CONTEXT: '65536',
  OPENROUTER_MAX_TOKENS: '2048', OPENAI_COMPAT_REASONING_EFFORT: 'none',
};
function load(file) {
  file = path.resolve(file);
  if (cache.has(file)) return cache.get(file).exports;
  const loaded = { exports: {} }; cache.set(file, loaded);
  const localRequire = (id) => {
    if (id === '@/lib/server-env') return { serverEnv: (key, fallback = '') => env[key] || fallback };
    if (id === '@/lib/db') return new Proxy({}, { get() { return () => { throw new Error('Unexpected database access'); }; } });
    if (id.startsWith('@/')) return load(`src/${id.slice(2)}.ts`);
    return require(id);
  };
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true },
  }).outputText;
  new Function('require', 'module', 'exports', compiled)(localRequire, loaded, loaded.exports);
  return loaded.exports;
}
const { isConfiguredOllama, ollamaHistoryCharBudget } = load('src/lib/ollama-routing.ts');
assert.ok(isConfiguredOllama('http://localhost:11434/v1/', env.OLLAMA_BASE_URL));
assert.ok(isConfiguredOllama('http://127.0.0.1:11434/v1/chat/completions', env.OLLAMA_BASE_URL));
assert.ok(!isConfiguredOllama('http://127.0.0.1:8080/v1', env.OLLAMA_BASE_URL));
assert.ok(!isConfiguredOllama('https://127.0.0.1:11434/v1', env.OLLAMA_BASE_URL));
assert.ok(!isConfiguredOllama('http://127.0.0.1:11434/other/v1', env.OLLAMA_BASE_URL));
assert.ok(!isConfiguredOllama('invalid', env.OLLAMA_BASE_URL));
assert.equal(ollamaHistoryCharBudget(65536, 2048), 185794);
assert.equal(ollamaHistoryCharBudget(4096, 2048), 0, 'Small windows cannot retain the old 48K-character minimum');

const { POST } = load('src/app/api/story/route.ts');
const fixture = {
  mode: 'turn', input: 'Wait by the door.', messages: [],
  settings: {
    world: 'A fantasy library.', style: 'Concise prose.', textProvider: 'custom',
    localTextModel: 'gemma4:12b-it-qat', customBaseUrl: 'http://127.0.0.1:11434/v1',
    customModel: 'qwen3.5:4b', customApiKey: '', imageMode: 'fast', imageBackend: 'manual',
    aspect: 'landscape', imageGenerationEnabled: true, autoImages: true, proseSize: 'medium',
  },
};
const calls = [];
let rejectTools = false;
let rejectThinking = false;
const originalFetch = globalThis.fetch;
globalThis.fetch = async (url, options) => {
  const body = JSON.parse(options.body); calls.push({ url, body, headers: options.headers });
  if (rejectTools && body.tools) return new Response('does not support tools', { status: 400 });
  if (rejectThinking && body.think === false) return new Response('does not support think', { status: 400 });
  const native = url.endsWith('/api/chat');
  if (!body.stream) return Response.json(native ? { message: { content: 'Mira waits beside the door.' } } : { choices: [{ message: { content: 'Mira waits beside the door.' } }] });
  return new Response(native
    ? '{"message":{"content":"Mira waits "}}\n{"message":{"content":"beside the door."},"done":true}\n'
    : 'data: {"choices":[{"delta":{"content":"Mira waits beside the door."}}]}\n\ndata: [DONE]\n\n');
};
async function turn(settings = {}, stream = true) {
  calls.length = 0;
  const response = await POST(new Request('http://localhost/api/story', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...fixture, stream, settings: { ...fixture.settings, ...settings } }),
  }));
  const text = await response.text();
  assert.equal(response.status, 200);
  assert.ok(text.includes('Mira waits beside the door.'), text);
  if (stream) assert.ok(text.includes('"type":"done"'), text);
}
try {
  await turn({ customApiKey: 'test-key' });
  assert.equal(calls[0].url, 'http://127.0.0.1:11434/api/chat');
  assert.equal(calls[0].body.model, 'qwen3.5:4b');
  assert.deepEqual(calls[0].body.options, { temperature: 0.9, num_predict: 2048, num_ctx: 65536 });
  assert.equal(calls[0].body.think, false);
  assert.ok(calls[0].body.tools?.length);
  assert.equal(calls[0].headers.Authorization, 'Bearer test-key');
  rejectTools = true; rejectThinking = true;
  await turn();
  assert.equal(calls.length, 3);
  assert.ok(calls.every(call => call.body.options.num_ctx === 65536 && call.body.options.num_predict === 2048));
  rejectTools = false; rejectThinking = false;
  await turn({}, false); // Summaries use this same non-streaming route.
  await turn({ customBaseUrl: 'http://127.0.0.1:8080/v1' });
  assert.equal(calls[0].url, 'http://127.0.0.1:8080/v1/chat/completions');
  assert.equal(calls[0].body.max_tokens, 2048);
  assert.equal(calls[0].body.options, undefined);
  // 180K characters fit the new 64K budget but exceeded the old custom budget.
  fixture.messages = Array.from({ length: 20 }, (_, i) => ({
    id: `history-${i}`, role: i % 2 ? 'assistant' : 'user',
    content: 'x'.repeat(9000), createdAt: new Date().toISOString(),
  }));
  await turn();
  assert.equal(calls[0].body.messages.length, 22, '64K history budget used by the custom Ollama route');
  console.log('Passed: native 64K payload, model/output/auth preservation, streaming, non-streaming, retries, history budget and other-provider isolation.');
} finally {
  globalThis.fetch = originalFetch;
}
