# Save and resume stories

The app opens on an entrance headed Open Dungeon, with a short introduction and four How to play steps covering setup, actions/dialogue, Speechify and saving. Current story, Resume story, New story and other saved stories follow. Resume opens the saved passage without advancing the narrator. New story replaces the entrance or story workspace with a dedicated setup view; Back or Cancel returns to the previous view, preserving the current story's draft and reading position.

During play, **Save & return** sits directly below Font Size in the desktop sidebar. On smaller screens it appears below the composer. It explicitly saves current settings, confirms the saved library, and returns home only on success. Completed turns and characters already live in SQLite. Saves are unavailable during narration, uploads, character saves or unfinished passage edits; errors leave the story open.

Unsent input, input mode, attached references and reading position are stored as a per-story bookmark in this browser's local storage (`local-roleplay:bookmark:<chatId>`). These bookmarks survive reloads on the same origin/browser. They are not separate database save slots and do not copy to another browser. Submitted actions discard the old unsent bookmark. The current story ID continues to use the existing selected-chat key.

No database migration, model changes or network changes were needed.

## Verification on 10 October 2026

- Lint and production build passed; served through https://dungeon.dia.net.au.
- Browser Save -> home -> reload -> Resume restored an unsent verification draft and exact reading offset (8385 pixels).
- Verification draft removed afterwards; no new narration generated.
- Existing Wazza Fantasy story retained all 35 messages, the same final passage ID/text, and character count.
- New story opened its existing setup dialog from home; cancelled without creating another story.
- Final build includes guards preventing story actions during Save and restores composer sizing on resume.
- Screenshots in ignored logs/story-home.jpg and logs/save-return-control.jpg.

To reverse the interface change, remove the home/save/bookmark additions in src/app/page.tsx. Existing SQLite stories remain usable without the bookmark keys.

## Entrance and setup verification on 10 October 2026

- Lint and production build passed after introducing the title, introduction and instructions.
- Verified the entrance and separate setup view through the HTTPS site; setup has no overlay or story content behind it.
- Back returned to the entrance. Cancel from setup opened during play restored the existing story at the same reading offset (9013 pixels).
- Save & return returned to the entrance with the same 35 messages. No new story or narration was generated during verification.
- Screenshot: ignored logs/story-entrance.jpg.

## Story deletion — 10 October 2026

The entrance shows **Delete story** beside Resume for the current story and beside each other saved story. The existing sidebar trash controls remain available. Confirmation names the story and warns that its saved messages, characters and story memory will be permanently removed; Cancel preserves it. This deletes the SQLite story records, not shared uploaded/generated asset files.

The client removes the story's browser bookmark only after a successful delete. Deleting the selected story clears the workspace and returns home without opening a different story. Errors remain visible and deletion is guarded during narration, saving or another deletion.

Verified through HTTPS: controls and Cancel in the browser; deletion API success, subsequent 404s, cascading message/character removal, SQLite integrity, and unchanged Wazza story. The two diagnostic stories were removed after an online SQLite backup to ignored `logs/before-test-story-cleanup.sqlite`. Reload confirmed only the retained story remains. Screenshot: ignored `logs/story-delete-home.png`.
