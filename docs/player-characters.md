# Player Characters and Random Event

Every new story starts with a required, named **Player Character**, saved through the existing Character system before any opening narration is requested. Define its concept plus Appearance, Wearing, Equipped, Inventory, Skills, and Spells in the setup form. These saved fields are canonical context for the narrator. A blank field means that state is not established.

For an existing story with no Player Character, open Characters and choose **Add Player Character**. The character is added in place; existing messages, summaries, characters, and attribution are retained. Existing characters can also be switched to **Player Character — human controlled**. An optional player display name identifies the person in the chip tooltip; story attribution and narrator context use the character name and ID. Leave other characters as **NPC — storyteller controlled**.

The composer shows a compact chip for every Player Character. One is selected automatically when there is only one. With several, choose who acts next before sending Do or Say. NPCs never appear as actors. Save & return bookmarks the chosen actor alongside the existing draft and reading position.

New player messages persist `actorCharacterId` and `actorCharacterName`. History displays the saved character name; renaming or deleting a character does not rewrite earlier attribution. Retry uses the original message's saved identity, even if a different chip is now selected. Narrator history and rolling-summary input explicitly include attributed actors. The real player's display name is not added to narrator context.

**Random Event** replaces Story composer mode. It immediately asks for an unexpected but plausible event fitting the scene, world and tone, respecting established facts and leaving player choices open. Combat is optional. The request is saved without a player actor and can be retried. Typed drafts and pending attachments remain in the composer; Attach otherwise behaves as before. These are narrator instructions, not a deterministic rules engine.

Migration is additive SQLite only: Appearance, Wearing, and Equipped are added as empty text fields. Existing Details, inventory, skills, spells, portraits, characters, messages, attribution, and summaries are preserved; old characters remain NPCs and old messages stay unattributed. With no Player Characters, Do/Say retain the legacy input and narrator behaviour. NPC prompt rules are unchanged.

The narrator receives all six canonical fields for every saved character. For Player Characters it is explicitly instructed not to invent possessions, clothing, equipment, skills, or spells that are not established. This checkpoint does not automatically reconcile story events with character state; state changes are edited in Characters.

Run `npm run check:player-characters` for isolated SQLite migration/reopen, required Player Character on new stories, adding one to a migrated story, six-field save/reload and narrator context, legacy NPC behavior, single-player auto-selection, multiple actors, NPC and cross-story rejection, attribution, rename/delete/retry, Random Event streaming and summary identity coverage. It uses captured model responses and never writes live stories or performs inference. Also run `node scripts/verify-ollama-context.mjs`, `npm run lint` and `npm run build`.

This pass is local shared input only. It adds no accounts, networking, Discord transport or remote multiplayer.
