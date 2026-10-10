# Development and checkpoint workflow

## Source and scope

Work in `F:\AI\DungeonCrawler` on `main` for normal project checkpoints. `origin` is `PopeKael/dungeon-crawl`; `upstream` is the original Open Dungeon project. Preserve its MIT licence and attribution. `phase1-text-manual-images` is retained as a historical feature checkpoint; it is no longer the normal working branch. Use a feature branch for isolated work when useful, and integrate reviewed/tested work into `main` before declaring that the default project page is current. Do not rename branches or publish releases as part of an ordinary source checkpoint.

Inspect `git status`, the current branch and remotes before editing or committing. Read `AGENTS.md` and the relevant installed Next.js guides in `node_modules/next/dist/docs/` before changing Next.js code. Keep Ariadne and other projects outside scope. Shared Ollama, GPU workloads and reverse-proxy configuration have separate owners; do not unload or change them to make a test pass.

## Implement and verify

Use narrow changes and additive, repeatable SQLite migrations. Before touching real saved data, use SQLite online backup or back up with the application stopped. A bare copy of a running WAL database is not a reliable backup.

Use isolated databases and captured narrator responses for regression tests. Do not advance the user's saved story to test a feature. Keep temporary fixtures out of the real story library, stop only identified test processes, and retain useful evidence under ignored `logs/`.

For the Player Character/narrator path, run:

```powershell
npm run check:player-characters
node scripts/verify-ollama-context.mjs
npm run lint
npm run build
git diff --check
```

Check each command's exit code before continuing. Run launcher, reader or image checks when the corresponding boundary changes; do not load GPU models or render images for unrelated documentation work. Browser changes also need visible acceptance. Distinguish simulated protocol/UI proof from live-model behaviour and record anything blocked or untested.

Normal application entry remains `DungeonCrawler.exe`. Keep its GPU/RAM readiness checks intact. If busy workloads prevent startup, leave them alone; an isolated loopback web server with a disposable database and simulated narrator can verify the UI without inference. Do not leave such a fixture running as the user's game.

## Document and checkpoint

Update `PROJECT-STATUS.md`, the relevant feature guide and `docs/DEVELOPMENT-LOG.md` with behaviour, validation, evidence, limitations and next steps. Keep README and roadmap aligned with implemented features. Real player names are optional Character metadata, not a separate account/participant system.

Review the complete diff and explicitly stage only the reviewed paths. Verify staged filenames, whitespace and content before committing. Keep stories, databases, raw transcripts, credentials, `.env.server`, local launcher policy, generated/uploaded content, build outputs and binaries ignored. GitHub backs up source, not saved adventures.

When the user requests a checkpoint, commit and push the current development branch to `origin`. Confirm the pushed remote branch SHA with `git ls-remote`, compare it with `git rev-parse HEAD`, and check `git status --porcelain`. Completion means exact local/remote SHA parity and a clean working tree. If push fails, report a local-only checkpoint and the actual blocker.

End with the commit, branch, verification result and material limits. A source push does not establish that the app is running or that a database migration has already run. For a new chat, hand over the goal, current state, paths/entry point, completed checks, unresolved limits and next action.

## Change counters and upstream updates

A clean working tree and exact equality with the tracked GitHub branch establish source synchronization. A branch-versus-`main` review can still display all committed feature changes; that is not an unpushed-change count. Check `git status --short --branch`, `git diff --stat`, `git diff --cached --stat` and `git diff --shortstat origin/main...HEAD` before diagnosing a nonzero UI counter.

Fetch `origin` and `upstream` before assessing updates. `git log HEAD..upstream/main --oneline` lists upstream commits absent from our current branch. Review those commits and affected files before any integration; fetching alone changes no application files. Do not use GitHub's Sync fork control blindly now that this fork has its own changes. Use a separate branch to evaluate an actual upstream update, resolve conflicts deliberately, run relevant checks and integrate only reviewed changes. On 10 October 2026, upstream `main` was `b0a79f96bf852be7b4e53908dff6a7f7c179da23` (v0.4.1), already an ancestor of this fork: no upstream commits were missing.
