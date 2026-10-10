# Dungeon Crawler — checkpoint 10 October 2026

## Current state

Repository: https://github.com/PopeKael/dungeon-crawl. Branch: `phase1-text-manual-images`.
Independent Windows project at `F:\AI\DungeonCrawler`; Ariadne is not a runtime dependency and was not changed.

The production app runs on `http://127.0.0.1:3000`, served privately at `https://dungeon.dia.net.au` through Synology. Restarted into the verified build (PID 30648 at this checkpoint). No automatic startup task has been installed.

Default narrator: `qwen3.5:4b`, selected from the existing Ollama library. This project's ignored `.env.server` requests a 65,536-token context, disables thinking, caps custom replies at 2,048 tokens and defaults to manual image prompts. Saved story settings take precedence over environment defaults.

## Completed

- Manual illustration requests: actual model tool calls persist as selectable prompts with reason, aspect, character references and Copy prompt; local image generation is blocked in manual mode.
- Speechify Speak control beneath each narrator passage: selects prose and sends saved passage IDs to the independent Windows clipboard/Alt+F1 helper. Warren confirmed audible playback through HTTPS.
- Private HTTPS: dedicated DNS name, Synology certificate/proxy and desktop-only access rule; NAS-only Windows bridge to the loopback app. Existing services preserved.
- Entrance with title and instructions, Current story, Resume, New story and a separate story setup view.
- Save & return below Font Size; completed messages remain in SQLite, while unsent input and reading position use a browser bookmark. Resume does not advance narration.
- Installed Ollama text-model selector with Refresh and manual entry fallback.
- Explicit per-request 64K allocation: custom connections matching the configured Ollama library now use native `/api/chat`; history budgeting follows that allocation. No shared/global Ollama settings changed.
- Visible Delete story controls on the entrance for current and other stories, reusing the sidebar's confirmation dialog and deletion API. The confirmation names the story and warns that messages, characters and story memory are permanently removed. Successful deletion removes its browser bookmark; deleting the selected story returns home without opening another story.

## Verification and cleanup

- `npm run lint`, `npm run build`, `git diff --check` passed.
- `node scripts/verify-ollama-context.mjs`: native 64K payload, selected model, output limit, auth preservation, retries, streaming/non-streaming, history budget and other-provider isolation passed using mocked upstream requests.
- `node scripts/verify-phase1.mjs 15f4b699-0db3-4b66-a3e5-5b1694eabdbb`: saved manual prompt, character reference, continuation, manual rendering guard and SQLite integrity passed.
- Browser verification through HTTPS: entrance delete controls, named confirmation and Cancel preserving the story. API deletion of the two diagnostic stories returned success, subsequent reads/deletes returned 404, related messages/characters were removed, and SQLite integrity remained `ok`. Reload showed only Wazza's story. The final destructive confirmation click was not used for this UI check; cleanup used the same application delete API.
- Wazza Fantasy remains at 44 messages and one character, unchanged by context verification and cleanup. No new main-story narration was generated for this checkpoint.
- Diagnostic story IDs removed: `3bcf979c-75aa-425c-9408-73b5ca437152` and `a67aeecf-aaae-4f53-8dee-e71141681ed3`.
- Local pre-cleanup backup: ignored `logs/before-test-story-cleanup.sqlite`. Evidence: ignored `logs/story-delete-verification.json`, `logs/story-delete-home.png`, `logs/stream-diagnosis/`.

## Context diagnosis

The old route left Ollama at 4,096 tokens. The long story used 4,023 prompt tokens plus 73 generated tokens, exhausting that window. Prefill caused the initial wait; generation and browser/proxy streaming were smooth. Controlled native decode measured roughly 99–100 tokens/sec for 4B and 70 tokens/sec for warm 9B.

After correction, Ollama confirmed `n_ctx_slot=65536`, a 4,400-token prompt and no truncation. Warm HTTPS replay began in 153 ms, completed in 1,719 ms, and had a longest chunk gap of 13 ms. Native decode was 94.36 tokens/sec. Resident memory was 5,608,885,451 bytes, entirely GPU. First text after changing allocation took 8.8 seconds while the model reloaded. Manual image-tool generation also passed; that request produced a tool-only response and the existing placeholder narration.

History budgeting remains an English-prose estimate, not exact token admission. Extremely large instructions, attachments or individual passages may exceed the budget. Browser tooling did not expose raw DevTools Network chunks; direct HTTP body timing and DOM growth independently verified streaming. External-client denial and Speechify word highlighting were not independently tested.

## Documentation and next session

- [Local setup and context policy](docs/phase1-local.md)
- [Speechify and private HTTPS, including reversal](docs/speechify-https.md)
- [Save, resume and delete](docs/save-resume.md)
- [Model library](docs/model-library.md)

Local SQLite stories, backups, logs, generated/uploaded files and `.env.server` are ignored and are not part of the GitHub checkpoint. Back up the local data directory separately; stop the app first or use SQLite's online backup mechanism.

Next session: resume normal play and assess longer sessions. No further optimization is pending for tonight.

Ariadne follow-up, unverified: when working in that separate project later, audit whether each inference route explicitly requests its intended context allocation and aligns history budgeting. This note does not establish that Ariadne has the same defect.
