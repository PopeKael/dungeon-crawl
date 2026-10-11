// Read only the settings needed by the launcher. Never print API credentials.
import fs from 'node:fs';
import Database from 'better-sqlite3';
const env = Object.fromEntries((fs.existsSync('.env.server') ? fs.readFileSync('.env.server', 'utf8') : '')
  .split(/\r?\n/).filter(line => line && !line.trim().startsWith('#')).map(line => {
    const i = line.indexOf('='); return i < 0 ? ['', ''] : [line.slice(0, i).trim(), line.slice(i + 1).trim().replace(/^(["'])(.*)\1$/, '$2')];
  }));
let saved = {};
if (fs.existsSync('data/local-roleplay.sqlite')) {
  const db = new Database('data/local-roleplay.sqlite', { readonly: true });
  saved = JSON.parse(db.prepare('SELECT value_json FROM app_settings WHERE key=?').get('default_story_settings')?.value_json || '{}');
  db.close();
}
console.log(JSON.stringify({
  provider: saved.textProvider || env.DEFAULT_TEXT_PROVIDER || 'local',
  model: (saved.textProvider || env.DEFAULT_TEXT_PROVIDER || 'local') === 'local'
    ? saved.localTextModel || env.LOCAL_TEXT_MODEL || 'gemma4:12b-it-qat'
    : saved.customModel || env.OPENAI_COMPAT_MODEL,
  baseUrl: saved.customBaseUrl || env.OPENAI_COMPAT_BASE_URL || 'http://127.0.0.1:11434/v1',
  ollamaUrl: env.OLLAMA_BASE_URL || 'http://127.0.0.1:11434',
  context: Number(env.LOCAL_TEXT_CONTEXT || 65536),
  // The Windows launcher must budget/start the one supported local renderer.
  // Saved settings or old environment files may still say "manual".
  imageBackend: 'sd-cpp-vulkan',
}));
