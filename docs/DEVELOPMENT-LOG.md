# Development log

## 10 October 2026 — Character-based local shared storytelling

Implemented the first multi-participant input pass using existing Characters. Characters now distinguish NPCs and human-controlled Player Characters, with an optional real-player display name. The composer excludes NPCs, automatically selects a sole Player Character, and requires a choice when several are available. Do/Say messages persist actor ID and a character-name snapshot; history, narrator context, summaries and Retry retain the original identity after renaming or deletion.

Random Event replaces Story composer mode. It requests an unexpected plausible scene event while respecting established facts, preserving player choice and not requiring combat. It is saved without an actor and leaves unsent drafts/attachments intact. Save/resume bookmarks the selected actor. Attach and the existing narrator/provider paths remain intact. No accounts, participant table, networking, Discord integration or remote multiplayer were added.

Validation passed: isolated legacy-schema migration and database reopen, legacy input behaviour, single/multiple player selection, NPC/cross-story rejection, attribution, rename/delete/retry, Random Event streaming/retry and summary identity; existing 64K routing regression; ESLint; production build; whitespace checks. Browser acceptance on loopback port 3010 with a disposable database and simulated narrator verified character creation, chips, attributed Do/Say, progressive prose, Random Event draft retention and save/home/reload/resume restoring actor and draft. This does not prove live-model obedience to every narrative constraint.

The normal launcher held startup while image tests were using GPU memory: 5.5 GiB free against an 8 GiB readiness requirement. No workloads were unloaded and no proxy/global Ollama settings changed. Temporary acceptance services were stopped after verification. The final production build is ready for the normal launcher; a new live-model acceptance run was not performed.

SQLite online backup: ignored `logs/before-player-characters.sqlite`. A row comparison confirmed the production database's one story, 44 messages and one character unchanged. No new test stories were added to that database. Existing characters become NPCs and old messages remain unattributed when the additive migration runs on the next normal start. Earlier source can read the extra columns, but will not display or maintain new actor semantics; restore the backup only if intentionally discarding subsequent saved changes.

Local evidence: ignored `logs/player-characters-ui.png`, `logs/player-ui.sqlite` and `logs/player-ui-requests.ndjson`. Test fixture data and raw model payloads are excluded from GitHub. The previous synchronized source checkpoint was `cbc96a41de35d5abc7c054250c185342596d41fb`; the Character feature and these maintenance notes form the next source checkpoint. The final handoff records the new SHA and remote parity.

Next: launch normally when GPU capacity is available, mark intended protagonists as Player Characters, and assess the real narrator's separation of actors. Stronger world-state continuity remains future work; accounts and transport stay deferred. See [workflow](development-workflow.md), [feature guide](player-characters.md), [status](../PROJECT-STATUS.md) and [roadmap](ROADMAP.md).
