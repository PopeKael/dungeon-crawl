# Player Characters and Random Event

Open Characters and choose **Player Character — human controlled** for each character controlled by a person. An optional player display name identifies the person in the chip tooltip; story attribution and narrator context use the character name and ID. Leave other characters as **NPC — storyteller controlled**.

The composer shows a compact chip for every Player Character. One is selected automatically when there is only one. With several, choose who acts next before sending Do or Say. NPCs never appear as actors. Save & return bookmarks the chosen actor alongside the existing draft and reading position.

New player messages persist `actorCharacterId` and `actorCharacterName`. History displays the saved character name; renaming or deleting a character does not rewrite earlier attribution. Retry uses the original message's saved identity, even if a different chip is now selected. Narrator history and rolling-summary input explicitly include attributed actors. The real player's display name is not added to narrator context.

**Random Event** replaces Story composer mode. It immediately asks for an unexpected but plausible event fitting the scene, world and tone, respecting established facts and leaving player choices open. Combat is optional. The request is saved without a player actor and can be retried. Typed drafts and pending attachments remain in the composer; Attach otherwise behaves as before. These are narrator instructions, not a deterministic rules engine.

Migration is additive: old characters become NPCs, old messages have no actor, and no historical attribution is invented. With no Player Characters, Do/Say retain the legacy input behaviour. Mark an existing character as player-controlled when you want attributed turns.

Run `npm run check:player-characters` for isolated SQLite migration/reopen, legacy inputs, single-player auto-selection, multiple actors, NPC and cross-story rejection, attribution, rename/delete/retry, Random Event streaming and summary identity coverage. It uses captured model responses and never writes live stories or performs inference. Also run `node scripts/verify-ollama-context.mjs`, `npm run lint` and `npm run build`.

This pass is local shared input only. It adds no accounts, networking, Discord transport or remote multiplayer.
