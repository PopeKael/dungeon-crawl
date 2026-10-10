# Dungeon Crawl: Local Interactive Storyteller — checkpoint 10 October 2026

## Repository and deployment

Repository: [PopeKael/dungeon-crawl](https://github.com/PopeKael/dungeon-crawl). Development branch: `phase1-text-manual-images`. Based on [Open Dungeon by newideas99](https://github.com/newideas99/open-dungeon); the original MIT licence and copyright notice are preserved. The repository name and `main` remain unchanged. The last pushed checkpoint is `cbc96a41de35d5abc7c054250c185342596d41fb`. The first Character-based multi-participant pass is now implemented locally.

Independent Windows project at `F:\AI\DungeonCrawler`. Ariadne is not a runtime dependency and was not changed. Canonical start point: `DungeonCrawler.exe`, also installed as **Dungeon Crawl** on Desktop and in the Start menu. The native tray requires adjacent Node application, scripts, assets, configuration and data. It is built locally, not distributed as an installer or release binary.

Production binds to `http://127.0.0.1:3000`; this installation uses private `https://dungeon.dia.net.au` through Synology and its NAS-only Windows bridge. No automatic startup task is installed. Exit stops the launcher-owned web process and closes the tray; shared Ollama remains running. The last lifecycle check left the game exited.

The active narrator is `qwen3.5:4b`, selected from the installed Ollama library. Ignored `.env.server` requests 65,536 tokens, disables thinking, caps custom replies at 2,048 tokens and defaults to manual image prompts. Saved story and app-wide settings can override environment defaults. Ignored `config/launcher.json` preserves the machine policy; `config/launcher.example.json` is the portable starting point.

## Currently implemented

| Area | Working behaviour and boundary |
|---|---|
| Story experience | Entrance/title/instructions, New story, Current story, Resume and separate setup view. Typed Do / Say, Random Event, Continue, Retry, Erase and passage editing. Fantasy, Mystery, Cyberpunk, Apocalyptic, Horror, Romance and custom openings. |
| Text providers | Local Ollama and custom OpenAI-compatible routes. Installed completion-model picker with Refresh and manual entry. Local testing covers Qwen 3.5 4B and 9B; other endpoints retain their existing provider route. |
| Streaming | Progressive narration deltas over NDJSON; reasoning/tool artefacts filtered from prose. Model loading, prompt prefill and compaction can delay the first token. |
| Persistence | SQLite stories, messages, settings, characters, image requests and summaries. Save & return also stores unsent input/reading position as a browser bookmark; Resume does not advance narration. |
| Deletion | Visible named destructive confirmation; deletion removes related records and browser bookmark. Deleting the selected story returns home. |
| Characters | NPC / human-controlled Player Character distinction, optional real-player display name, selectable actor chips and one-player auto-selection. New player messages save actor ID/name; history, narrator context, retry and summary input preserve character identity. Legacy characters default to NPCs; legacy messages remain unattributed. Saved descriptions, portraits, inventory, skills and spells still enter the prompt. |
| Long-story memory | Older passages outside the history budget fold into a persisted rolling summary. Best-effort summarisation retains the prior summary on failure; not guaranteed recall. The acceptance story has not triggered compaction at 64K. |
| Images | Actual image-tool calls persist with prompt, reason, aspect and character references, shown as selectable text with Copy prompt. Manual mode refuses local rendering. Retained upstream local-image/ComfyUI paths are present but not accepted on this Windows hardware in this checkpoint. |
| Voice | Speak selects a completed passage; an independent Windows helper retrieves saved passage IDs, writes the clipboard and sends fixed Alt+F1. Warren confirmed audible Speechify playback over HTTPS. No built-in local TTS, speech input or automatic narrator playback. |
| Windows lifecycle | Native EXE, icon/favicon, Desktop/Start-menu shortcuts and application ID. GPU/VRAM/RAM readiness checks. Start/Restart/Stop/Exit validate the owned web process identity. Startup policy covers 4B/64K/manual images and holds unknown profiles. |

## Context diagnosis and measured performance

The old custom Ollama route left allocation at **4,096 tokens**. The existing-story request used **4,023 prompt tokens**, leaving only **73 generation tokens**. Ollama finished at the limit with a mid-sentence result. Prefill caused the initial delay; a continuing mid-stream stall was not reproduced. Prompt assembly took about 2 ms; observed content gaps were 14–22 ms. No old 9B residency or repeated 4B loading loop was observed during story tests.

The fix routes custom URLs matching the configured Ollama server through native `/api/chat`, explicitly supplying `options.num_ctx=65536` for narration and summaries. History budgeting follows the allocation. Selected model, tools, reply cap and credentials are preserved; other servers retain their route. No global Ollama configuration or other project was changed.

| Controlled measurement on RX 7800 XT | Result |
|---|---|
| 4B short-prompt decode at 4K, warm | 98.50–100.08 tokens/sec |
| 9B short-prompt decode at 4K, warm | 70.07 tokens/sec |
| 4B GPU allocation at 4K | 3,130,009,844 bytes (~3.13 GB / 2.92 GiB) |
| 4B decode after the 64K fix | 94.36 tokens/sec |
| 4B resident allocation at 64K, fully on GPU | 5,608,885,451 bytes (~5.61 GB / 5.22 GiB) |
| Warm 64K HTTPS replay | First delta 153 ms; total 1,719 ms; longest chunk gap 13 ms |

The short-prompt comparison used the same prompt, seed, temperature, 4K context and thinking disabled. The 64K measurement is a different story workload, not a matched 64K 9B comparison. Changing allocation caused a model reload and an 8.8-second first-text wait. These are local observations, not universal requirements. Warm localhost/HTTPS traces did not identify proxy buffering as a cause.

History allowance is approximately 185,794 characters at the 2,048-token reply cap, reserving at least 8,192 tokens plus a 10% margin. This is an English-prose estimate, not exact admission; oversized instructions, attachments or passages can exceed it. The application still does not expose context-limit finish reasons as a dedicated warning.

## Previous checkpoint verification and retained evidence

This checkpoint passed `npm run lint`, `npm run build`, `npm run check:windows-launchers`, `npm run check:image-routing` and `npm run check:image-server-http` (fake rendering fixture; no GPU image generation). The native EXE rebuilt successfully. `scripts/verify-dungeon-launcher.ps1` passed nine readiness scenarios and script syntax; `node scripts/verify-ollama-context.mjs` passed routing, allocation, retry, streaming/non-streaming, output/auth preservation and history-budget checks with mocked upstream responses. `node scripts/verify-reader.mjs` passed six rejected-request boundaries without clipboard/key events. `node scripts/verify-phase1.mjs` verified saved character/image references, manual-render refusal and SQLite integrity without narration. A guarded cold start with no resident model restored 4B/64K and private HTTPS; the temporary server was stopped after checks. The final handoff records the exact pushed commit.

Native controls already verified: Readiness, Start, Stop, Restart, private HTTPS restoration, duplicate EXE launch retaining one tray/web PID, and closing/restoring the status window. Revised Exit passed while stopped and running, leaving zero tray processes, zero port-3000 listeners and no ownership file; shared Ollama stayed resident. Status window and favicon were visually inspected.

Saved Wazza Fantasy remains at **44 messages and one character**, SQLite integrity `ok`. No narration is generated for this documentation checkpoint. Two diagnostic stories were deleted after a local backup. Delete UI checks verified named confirmation and Cancel; cleanup used the delete API rather than clicking final confirmation. The story summary is still empty, so long-session summary quality remains unverified.

Ignored evidence: `logs/stream-diagnosis/`, `logs/phase1-persistence.json`, `logs/story-delete-verification.json`, `logs/launcher-last-*.json`, control screenshots and `logs/before-test-story-cleanup.sqlite`. Raw story text, diagnostics and databases are not published. Browser tooling did not expose DevTools Network body-read logs; progressive HTTP reads, backend timings and DOM growth are the available streaming evidence. External-client denial and Speechify word highlighting were not independently tested.

## First multi-participant pass and operating notes

**Implemented locally:** [Player Characters](docs/player-characters.md) use the existing Character system with no separate participant/account model. Random Event replaces Story composer mode, requests a plausible scene surprise without forcing choices or combat, and leaves drafts/attachments in place. Attach is unchanged. Accounts, Discord transport and remote multiplayer are deferred.

`npm run check:player-characters` passes against a migrated legacy SQLite fixture with captured model responses: legacy behaviour, one-player auto-selection, multiple actors, NPC/cross-story rejection, persistence/reopen, name snapshots, rename/delete/retry, Random Event streaming/retry and compaction identity. The 64K routing regression, lint and production build also pass. Browser acceptance uses a disposable database and a loopback simulated narrator, covering character creation, actor chips, attributed Do/Say, Random Event and save/resume. It verifies the UI/payload path, not live-model compliance with every narrative instruction.

The production database was backed up with SQLite's online backup to ignored `logs/before-player-characters.sqlite`; its one story, 44 messages and one character were verified unchanged. No test stories were added there. The guarded launch was held at 5.5 GiB free VRAM against an 8 GiB requirement while image tests were running; no other workload was unloaded. The additive production migration will run on the next normal application start.

The entertainment, lore-pack and narrative-rules direction is in [PRODUCT-VISION.md](docs/PRODUCT-VISION.md). World packs, integrated local voices, speech input and robust automatic state updates are roadmap items. No proprietary setting material is included.

Procedure owners: [development workflow](docs/development-workflow.md), [development log](docs/DEVELOPMENT-LOG.md), [Player Characters](docs/player-characters.md), [local text/context](docs/phase1-local.md), [Windows launcher](docs/windows-launcher.md), [Speechify/HTTPS](docs/speechify-https.md), [save/resume/delete](docs/save-resume.md), [model library](docs/model-library.md).

Stories, credentials, local launcher policy, build outputs, EXE binaries, uploads/generated content and logs stay ignored. GitHub is a source checkpoint, not a story backup. Back up data with the app stopped, or use SQLite's online backup mechanism. An Ariadne context audit remains an unverified note for that separate project; this checkpoint makes no claim about its configuration.
