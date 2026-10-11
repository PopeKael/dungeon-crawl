# Phase 1: local text and manual illustrations (historical)

This guide records the earlier manual-image acceptance setup; it is not the
current Windows image workflow. Current story illustrations use Dungeon's
headless Vulkan renderer and are enabled by default. See
[Image generation](image-generation.md) for setup and measured performance.

Use the existing Ollama server without running the upstream image setup or Windows installer prompts. No Python environment or image dependencies are needed.

Local `.env.server`:

```ini
DEFAULT_TEXT_PROVIDER=custom
OPENAI_COMPAT_BASE_URL=http://127.0.0.1:11434/v1
OPENAI_COMPAT_MODEL=qwen3.5:4b
OPENAI_COMPAT_REASONING_EFFORT=none
OPENROUTER_MAX_TOKENS=2048
LOCAL_TEXT_CONTEXT=65536
DEFAULT_IMAGE_BACKEND=manual
```

`OPENROUTER_MAX_TOKENS` is upstream's existing output-cap variable for all custom providers. The model must already exist; verify with `ollama list`.

The current installation is `F:\AI\DungeonCrawler`; fresh clones can use their own directory. Normal Windows operation now uses [DungeonCrawler.exe and the guarded tray](windows-launcher.md). These terminal commands remain a development alternative:

```powershell
npm install
npm run lint
npm run build
npm run start -- --hostname 127.0.0.1 --port 3000
```

Check port availability first; choose another port (e.g. 3100) if needed. Bind to loopback for this local experiment. Stop this app with Ctrl+C in its terminal; Ollama stays running. Avoid the upstream image smoke/setup commands during Phase 1.

In **Open story tools > Images**, enable **Image requests**, choose **Manual prompt only**, and leave **Auto image requests** enabled. Aspect remains configurable. The narrator's actual `generate_image` calls are saved in SQLite and displayed inline with the full selectable prompt, reason, aspect, character references, and **Copy prompt**. Copy errors leave text available for manual selection. No external website is opened.

The existing image-request toggle disables requests entirely. Selecting a local backend restores upstream local rendering. Existing stories and app-wide saved defaults take precedence over environment defaults. No schema migration is required: manual delivery is an additional backend choice stored in the existing settings/request JSON.

Qwen may choose no image on a particular turn; a picturesque scene is not a guaranteed tool call. An explicit request for an illustration can exercise the path without forcing every turn to produce images.

`OPENAI_COMPAT_REASONING_EFFORT` is opt-in and leaves other backends unchanged when unset. Stock Qwen requests exhausted the output allowance in the hidden reasoning channel; the documented `none` value returned normal text. See [Ollama compatibility](https://docs.ollama.com/api/openai-compatibility).

## Persistence and context boundaries

Stories, characters, settings, image requests and rolling summaries use `data/local-roleplay.sqlite` with WAL journaling. Keep the entire data folder when backing up a running app, or stop the app before copying. Data, `.env.server`, logs and generated assets are ignored by Git. Restore the data folder to recover local stories.

Dungeon Crawl explicitly requests 65,536 tokens (64K) using Ollama's native `/api/chat` API when a custom backend URL matches the configured `OLLAMA_BASE_URL`. This includes Qwen selected from the library; its saved custom-provider settings remain compatible. The selected model, manual image tools and custom reply cap are preserved; thinking is disabled. Other OpenAI-compatible servers keep their existing route.

`LOCAL_TEXT_CONTEXT=65536` in this project's ignored `.env.server` controls allocation per request, including summary calls. No global Ollama settings, model files or other projects are changed. Changing context can reload the resident model on the next turn. Confirm allocation with `ollama ps` after a game request. Windows also defaults to 64K if the variable is absent.

History compaction uses that same context setting, reserving at least 8,192 tokens for instructions, characters, summary and reply, plus a 10% margin. At the current 2,048-token reply cap, the history budget is 185,794 characters. This remains an English-prose estimate rather than exact token counting; unusually large instructions, attachments or a single oversized passage can exceed it. The context window and maximum reply length are separate settings.

Run `node scripts/verify-ollama-context.mjs` to verify request routing, allocation, retry behavior and history budgeting with mocked upstream responses and no database writes. To adjust allocation, edit only this project's `LOCAL_TEXT_CONTEXT` and restart Dungeon Crawl; do not change shared Ollama configuration. Reverting to 4096 would restore the diagnosed long-story truncation risk.

To reverse manual delivery, choose an existing local image backend or disable image requests. Keep explicit context allocation for long Qwen stories. Source is checkpointed on `phase1-text-manual-images`; `main` remains unchanged. Removing environment defaults does not clear saved story or app-wide settings.

The retained acceptance story can be checked without making another model call:

```powershell
node scripts/verify-phase1.mjs 15f4b699-0db3-4b66-a3e5-5b1694eabdbb
```

This checks the saved Phase 1 fixture, SQLite integrity, and the manual-backend refusal; it does not create or delete stories. Set APP_URL if using another port.
