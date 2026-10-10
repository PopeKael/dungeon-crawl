# Dungeon Crawl: Local Interactive Storyteller

A local interactive audiobook and illustrated story engine with AI narration, persistent characters, player-driven adventures, voice, and scene art.

**Based on [Open Dungeon by newideas99](https://github.com/newideas99/open-dungeon).** This fork preserves the [MIT licence](LICENSE) and original copyright attribution. Development currently lives on [`phase1-text-manual-images`](https://github.com/PopeKael/dungeon-crawl/tree/phase1-text-manual-images).

The idea is a book created while you play and listen: choose an action, let the storyteller advance the scene, then decide what happens next. The same opening can become a different adventure each time. Our direction centres on story, meaningful choices and continuity across sessions.

## Currently working

- **Streaming narration:** local Ollama and custom OpenAI-compatible text backends, with an installed Ollama model selector. The tested Windows narrator is `qwen3.5:4b` with an explicit **65,536-token context**.
- **Saved adventures:** a home screen with New story, Current story and Resume; automatic SQLite persistence, Save & return, and confirmed story deletion. Do / Say / Story, Continue, Retry, Erase and passage editing are available.
- **Characters:** saved descriptions, portraits, inventory, skills and spells are included in the narrator's context. These are editable fields; automatic transactional world-state management is still a future step.
- **Long-story memory:** context budgeting and a stored rolling summary fold older passages into story memory. Compaction is best-effort and can delay the next passage before streaming begins; it is not perfect recall.
- **Narration through Speechify:** Speak beneath a completed passage selects its prose and hands it to the installed Windows reader using Alt+F1. Audible playback has been confirmed over private HTTPS. This is a manual reader handoff, not built-in local speech generation or speech input.
- **Illustration requests:** the narrator can save scene prompts with aspect and character references for manual copying. Upstream local image/ComfyUI paths remain available; this Windows checkpoint uses **Manual prompt only**, with no automatic local rendering.
- **Story openings:** Fantasy, Mystery, Cyberpunk, Apocalyptic, Horror and Romance presets, plus a custom scenario.
- **Windows application:** `DungeonCrawler.exe`, Desktop/Start-menu shortcuts, an icon and native tray controls. Startup checks GPU activity, VRAM and RAM. **Exit stops the owned web process and closes the tray.** The guarded startup profile currently covers 4B / 64K / manual illustrations.

On the tested RX 7800 XT, controlled short-prompt decode measured roughly **99–100 tokens/sec for 4B versus 70 for 9B** at 4K context. The corrected 64K run measured about **94 tokens/sec**, with **5.61 GB (5.22 GiB)** of resident GPU memory. The earlier ~3.1 GB figure was the 4K allocation. These are local measurements, not hardware-independent requirements; see [checkpoint evidence and limits](PROJECT-STATUS.md).

## Run locally

On the existing Windows installation, launch **Dungeon Crawl** from Start or Desktop, or run `F:\AI\DungeonCrawler\DungeonCrawler.exe`. It opens the game in the default browser after readiness checks. Keep the EXE alongside its project files.

For a fresh checkout, use Node.js 22+ and an already installed Ollama model:

```powershell
git clone --branch phase1-text-manual-images https://github.com/PopeKael/dungeon-crawl.git
cd dungeon-crawl
npm install
```

Create your local `.env.server` from the [tested text/manual-image configuration](docs/phase1-local.md), then follow the [Windows EXE build and shortcut instructions](docs/windows-launcher.md). The EXE is built locally; this checkpoint does not publish an installer or downloadable Windows release. A terminal alternative after configuration is `npm run build` followed by `npm run start -- --hostname 127.0.0.1 --port 3000`.

Stories and settings stay in the local `data/` directory, which Git does not back up. Local text generation needs no cloud account. Remote providers and external readers have their own data handling; choosing them changes where content goes. The tested Speechify route uses private HTTPS through Synology. The app has no user authentication: keep it private and use the [deployment guide](docs/speechify-https.md) for reader setup.

## Direction / roadmap

The next feature is **local participant identity**: select who acts, optionally link them to a story character, preserve that identity in history and explicitly tell the narrator. Existing single-player stories must remain compatible. Accounts, Discord transport and remote multiplayer are outside that first pass.

Later work includes interchangeable user-supplied world/lore packs, stronger structured world-state continuity, integrated local voices and speech input, and illustrated-book scene plates at important moments. These are goals, not completed features. Mechanical resolution should serve the story, with earned consequences and continuity for established characters.

Read the fuller [product vision](docs/PRODUCT-VISION.md), the ordered [roadmap](docs/ROADMAP.md), or the [current project status](PROJECT-STATUS.md).

## Guides and attribution

| Guide | Purpose |
|---|---|
| [Local text and 64K context](docs/phase1-local.md) / [model library](docs/model-library.md) | Tested Qwen configuration, history budget and model selection |
| [Windows executable](docs/windows-launcher.md) | Build, shortcuts, readiness policy and lifecycle controls |
| [Speechify and private HTTPS](docs/speechify-https.md) | Reader handoff and deployment boundaries |
| [Save, resume and delete](docs/save-resume.md) | Story persistence and bookmarks |
| [Text backends](docs/text-backends.md) / [image generation](docs/image-generation.md) | Retained upstream provider and image options; platform-specific testing differs |

Open Dungeon's original work is by **newideas99 (Jacob Ferrari)**. The original MIT copyright notice remains intact. This fork is independently developed by Warren “Wazza” Gerdes / PopeKael. Any retained GitHub Sponsor or Ko-fi links support the **original Open Dungeon maintainer**. No proprietary world or setting source material is distributed here.

The inherited narrator prompt permits consensual adult fiction between adults. Review the prompt and choose suitable content boundaries for your own private sessions.
