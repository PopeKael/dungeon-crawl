# Dungeon Crawl: Local Interactive Storyteller

A local interactive audiobook and illustrated story engine with AI narration, persistent characters, player-driven adventures, voice, and scene art.

**Based on [Open Dungeon by newideas99](https://github.com/newideas99/open-dungeon).** This fork preserves the [MIT licence](LICENSE) and original copyright attribution. The current project and normal checkpoints live on [`main`](https://github.com/PopeKael/dungeon-crawl/tree/main). The original `phase1-text-manual-images` branch is retained as a historical feature checkpoint.

The idea is a book created while you play and listen: choose an action, let the storyteller advance the scene, then decide what happens next. The same opening can become a different adventure each time. Our direction centres on story, meaningful choices and continuity across sessions.

## Currently working

- **Streaming narration:** local Ollama and custom OpenAI-compatible text backends, with an installed Ollama model selector. The tested Windows narrator is `qwen3.5:4b` with an explicit **65,536-token context**.
- **Saved adventures:** a home screen with New story, Current story and Resume; automatic SQLite persistence, Save & return, and confirmed story deletion. Do / Say / Random Event, Continue, Retry, Erase and passage editing are available.
- **Characters and local shared play:** every new story defines a Player Character in the existing Character system before narration. Appearance, Wearing, Equipped, Inventory, Skills and Spells are saved and sent to the narrator as canonical character state. Existing stories can add a Player Character in place, and legacy NPCs/messages remain intact. Actor chips select who acts or speaks; automatic state reconciliation remains future work.
- **Long-story memory:** context budgeting and a stored rolling summary fold older passages into story memory. Compaction is best-effort and can delay the next passage before streaming begins; it is not perfect recall.
- **Narration through Speechify:** Speak beneath a completed passage selects its prose and hands it to the installed Windows reader using Alt+F1. Audible playback has been confirmed over private HTTPS. This is a manual reader handoff, not built-in local speech generation or speech input.
- **Story illustrations:** automatic image requests are enabled by default. The narrator compares each scene with the last illustration, aims for a new plate every 2–4 passages when the view changes, and triggers immediately for a major scene shift. Dungeon dispatches the hidden request while narration streams; the saved PNG replaces its passage placeholder. See the [image workflow](docs/image-generation.md) and [measured renderer results](docs/image-rendering-results.md).
- **Story openings:** Fantasy, Mystery, Cyberpunk, Apocalyptic, Horror and Romance presets, plus a custom scenario.
- **Windows application:** `DungeonCrawler.exe` shows a 640×480 startup splash with live stage progress, takes ownership of the local Ollama server, starts the configured Qwen 4B narrator, Dungeon-owned SDXL-Lightning Vulkan renderer and web app, then opens the configured page. The tray offers Start Dungeon, Open web page, Shut down, and Exit; Exit stays available during startup and stops Dungeon's server processes before closing the tray. Shutdown terminates the local Ollama server and releases its resident models. The startup memory check covers the 4B / 64K narrator and 6 GiB renderer together.

On the tested RX 7800 XT, controlled short-prompt decode measured roughly **99–100 tokens/sec for 4B versus 70 for 9B** at 4K context. The corrected 64K run measured about **94 tokens/sec**, with **5.61 GB (5.22 GiB)** of resident GPU memory. The earlier ~3.1 GB figure was the 4K allocation. These are local measurements, not hardware-independent requirements; see [checkpoint evidence and limits](PROJECT-STATUS.md).

## Run locally

On the existing Windows installation, launch **Dungeon Crawl** from Start or Desktop, or run `F:\AI\DungeonCrawler\DungeonCrawler.exe`. It opens the game in the default browser after readiness checks. Keep the EXE alongside its project files.

For a fresh checkout, use Node.js 22+ and an already installed Ollama model:

```powershell
git clone https://github.com/PopeKael/dungeon-crawl.git
cd dungeon-crawl
npm install
```

Create your local `.env.server` from the [tested text/manual-image configuration](docs/phase1-local.md), then follow the [Windows EXE build and shortcut instructions](docs/windows-launcher.md). The EXE is built locally; this checkpoint does not publish an installer or downloadable Windows release. A terminal alternative after configuration is `npm run build` followed by `npm run start -- --hostname 127.0.0.1 --port 3000`.

Dungeon Crawl works locally without a NAS or reverse proxy. See [Networking and HTTPS](docs/NETWORKING-AND-HTTPS.md) for local HTTP and configurable HTTPS deployment modes.

Stories and settings stay in the local `data/` directory, which Git does not back up. Local text generation needs no cloud account. Remote providers and external readers have their own data handling; choosing them changes where content goes. The tested Speechify route uses private HTTPS through Synology; its [site-specific reference implementation](docs/speechify-https.md) records reader setup. The app has no user authentication: keep it private.

## Direction / roadmap

The **local multi-participant pass** uses the existing Character system, without a separate participant or account system. Every new story defines a Player Character before narration; existing stories can add one without restarting. Appearance, Wearing, Equipped, Inventory, Skills and Spells form visible, persistent canonical state, with no automatic event reconciliation yet. Existing characters default to NPCs, and old messages retain their original behaviour. Random Event asks for a plausible scene surprise while leaving player choices open. See [Player Characters](docs/player-characters.md) for setup and verification. Accounts, Discord transport and remote multiplayer remain outside this pass.

Later work includes interchangeable user-supplied world/lore packs, stronger structured world-state continuity, integrated local voices and speech input, and illustrated-book scene plates at important moments. These are goals, not completed features. Mechanical resolution should serve the story, with earned consequences and continuity for established characters.

Read the fuller [product vision](docs/PRODUCT-VISION.md), the ordered [roadmap](docs/ROADMAP.md), or the [current project status](PROJECT-STATUS.md).

## Guides and attribution

| Guide | Purpose |
|---|---|
| [Development workflow](docs/development-workflow.md) / [development log](docs/DEVELOPMENT-LOG.md) | Validation, private-data boundaries, checkpoint and handover procedure |
| [Player Characters](docs/player-characters.md) | Actor selection, attribution, Random Event and legacy compatibility |
| [Local text and 64K context](docs/phase1-local.md) / [model library](docs/model-library.md) | Tested Qwen configuration, history budget and model selection |
| [Windows executable](docs/windows-launcher.md) | Build, shortcuts, readiness policy and lifecycle controls |
| [Networking and HTTPS](docs/NETWORKING-AND-HTTPS.md) | Generic deployment modes and browser-to-application network contract |
| [Speechify and private HTTPS](docs/speechify-https.md) | Reader handoff and Wazza's site-specific Synology reference implementation |
| [Save, resume and delete](docs/save-resume.md) | Story persistence and bookmarks |
| [Text backends](docs/text-backends.md) / [image generation](docs/image-generation.md) / [renderer results](docs/image-rendering-results.md) | Current Windows Vulkan renderer, image lifecycle and measured alternatives |

Open Dungeon's original work is by **newideas99 (Jacob Ferrari)**. The original MIT copyright notice remains intact. This fork is independently developed by Warren “Wazza” Gerdes / PopeKael. Any retained GitHub Sponsor or Ko-fi links support the **original Open Dungeon maintainer**. No proprietary world or setting source material is distributed here.

The inherited narrator prompt permits consensual adult fiction between adults. Review the prompt and choose suitable content boundaries for your own private sessions.

## Help and community

GitHub Issues is currently disabled on this fork. For now, please [open an Issue in the Garage Alchemy tracker](https://github.com/PopeKael/wazza-garage/issues) with **Dungeon Crawl:** at the start of the title to report a reproducible bug or suggest an improvement. Include the application version, model/backend, steps and observed behaviour. Do not publish private stories, personal settings or API credentials.

This fork is one of the experiments shared through [Garage Alchemy](https://garage.dia.net.au/). **Optional support for Wazza's work on this fork:** [Buy Me a Coffee](https://buymeacoffee.com/warrengerdes) · [Join the Tribe on Patreon](https://www.patreon.com/c/chanyawazza). These are not the original Open Dungeon maintainer's support links; the upstream author and MIT licence remain credited above.
