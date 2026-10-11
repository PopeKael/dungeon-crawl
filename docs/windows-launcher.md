# Dungeon Crawl Windows executable

The normal start point is **`F:\AI\DungeonCrawler\DungeonCrawler.exe`**. Desktop and Start-menu **Dungeon Crawl** shortcuts point directly to it. You can right-click the Start-menu entry to pin it. The executable, shortcuts and status window use `PopeKael.DungeonCrawler` as their Windows application ID, with an embedded dungeon-door icon matching the browser favicon.

This is a 64-bit Windows GUI executable hosting the tray in-process through the installed Windows PowerShell runtime. It opens no console window. The game remains a local Next.js web app; Node, the production build, scripts, config, assets and local data remain alongside the executable. Moving the EXE alone does not make a portable installation. No VBScript launcher is needed.

## Startup and controls

1. Measure three GPU activity samples after a warm-up sample, dedicated VRAM and available system RAM. DXGI adapter IDs join capacity to Windows GPU counters; process slices are grouped by physical engine and the busiest engine is reported.
2. Hold startup if at least two samples reach 25% on any engine or 15% on the 3D engine, free RAM is below 4 GiB, telemetry is unavailable, or VRAM cannot accommodate the selected model plus 2 GiB headroom. These are conservative configurable policies, not a claim to detect every game by name.
3. Reuse an idle matching resident 64K model allocation when possible. Otherwise start existing local Ollama if needed, verify the model is installed, load it without generating story text, and confirm its allocation is fully on GPU. Nothing is downloaded, evicted or unloaded automatically.
4. Start the loopback web process and any configured private gateway, verify the required listeners belong to the recorded processes, then verify the configured browser URL serves Open Dungeon before opening the browser. This is HTTPS in the reference installation and loopback HTTP in the example configuration. Existing unrelated/unmanaged listeners are reported and left alone. Normal startup requires no administrator elevation after gateway installation.

Tray controls: **Open game**, **Start**, **Restart**, **Stop web app**, **Check readiness**, **Show last status**, **Open launcher logs**, and **Exit**. Stop and Exit stop the owned gateway and web process; Exit then closes the tray. If stopping fails, controls remain available and display the error. The native status window provides Start, Restart, Stop web, Readiness and Exit. Closing that window hides it; the tray remains. Open game and double-click both run guarded startup and verify the configured browser URL before opening the browser, restoring a missing component rather than blindly opening a URL. A second executable launch signals the existing tray rather than creating another one.

Stop/restart/exit control only the web and gateway processes registered by this launcher, checking PID, creation time, executable path and exact command line for both before stopping either. Shared Ollama, other models, image workers, Ariadne and games are not stopped. Stop or Exit can interrupt an active web request; neither promises to release shared Ollama VRAM.

Readiness is a startup check, not a GPU reservation or continuous resource governor. Other work can start afterwards. Model changes during play are not rechecked by this harness. The current measured profile covers **qwen3.5:4b at 65,536 tokens with Manual prompt only**, with a 6 GiB model allowance. Other launch-default models, context sizes, local image backends or multiple dedicated GPUs hold startup until their policy is explicitly extended; there is no guessed allowance.

Policy: ignored `config/launcher.json`. Keep existing local policies unchanged. Fresh checkouts copy `config/launcher.example.json` and set `appUrl` for their own deployment. The example uses loopback HTTP for text play. See [Networking and HTTPS](NETWORKING-AND-HTTPS.md) for deployment choices and the current launcher's HTTPS gateway requirement; [the reader guide](speechify-https.md) records the tested Speechify/Synology setup. Saved model settings come from SQLite, with `.env.server` defaults as fallback. Runtime identity and last-operation reports are in ignored `logs/launcher-*.json`; diagnostics are in `logs/launcher-*.log`. These can include local process names and should stay local.

Background ownership/listener checks run every 15 seconds without replacing stable status text or disabling controls. A lost component updates the status with a Start recovery instruction. These checks do not continuously probe the NAS or reserve GPU memory. A failed startup retains the actual route error; see [private gateway setup](speechify-https.md#application-owned-private-gateway-11-october-2026).

The CLI boundary is `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/dungeon-worker.ps1 -Action Start|Status|Stop|Restart|Readiness`. It emits JSON and starts/stops the same owned components as the EXE. A future Ariadne integration can call this boundary after arranging model memory; it is not implemented here. The CLI does not open a browser itself; the EXE opens `Url` only after `Ok=true` from Start/Restart.

The maintenance `scripts/stop-windows.ps1` / Stop-Windows batch entry now calls that same ownership-checked Stop action. It stops both gateway and web server, not arbitrary listeners or image workers. Its pre-existing explicit `-IncludeOllama` option remains a separate request to stop shared Ollama; normal Stop does not use it.

## Build, installation and reversal

From the project folder:

```powershell
# Fresh checkout only; keep any existing local policy.
if (-not (Test-Path config/launcher.json)) { Copy-Item config/launcher.example.json config/launcher.json }
node scripts/build-dungeon-icons.mjs
npm run build
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-dungeon-launcher.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-dungeon-shortcut.ps1
.\DungeonCrawler.exe
# Show controls without starting the web app:
.\DungeonCrawler.exe --status --no-auto-start
# Policy/syntax checks (no workloads launched):
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-dungeon-launcher.ps1
```

The build uses the installed Microsoft .NET Framework compiler and Windows PowerShell hosting assembly; no new framework or compiler download is needed. Exit the tray before rebuilding the EXE. The binary is generated locally and ignored by Git; source and reproducible build instructions are tracked. Per-process execution policy does not change user/machine policy. The old `Launch-Windows.bat` normal path forwards to this executable; explicit upstream setup/CPU switches remain maintenance tools.

Before building, install Node dependencies (`npm install`), configure `.env.server` using [the text/manual-image guide](phase1-local.md), and verify `qwen3.5:4b` is installed in Ollama. Missing models are never downloaded automatically. The success message calls the route private HTTPS for the tested installation; loopback HTTP in the example is only a basic text-play route. The EXE and reader helper are Windows-specific.

To reverse installation, stop the owned web process and exit the tray, then run `scripts/install-dungeon-shortcut.ps1 -Remove`. It removes only matching project shortcuts. Keep the local data directory to preserve stories. Removing shortcuts does not alter proxy, firewall, Ollama or browser configuration.

## Verified on 10 October 2026

The native EXE compiled successfully. Both installed shortcuts target it directly, use its embedded icon and carry the matching application ID. Native status-window Readiness, Stop, Start and Restart controls passed. Stop removed the owned listener while leaving the resident 4B/64K Ollama model running; Start and Restart restored private HTTPS. A second EXE launch retained one tray process and the existing web PID. Closing the control window retained the tray, and `--status` restored the same window. The running status window was visually inspected.

The revised Exit control passed both while stopped and while running: the tray process exited, port 3000 had no listener, and the ownership file was removed. Shared Ollama remained resident. Tray and status-window Exit use the same shutdown handler. The game was left exited after this check.

Nine readiness policy scenarios, PowerShell syntax, ESLint, Windows batch launcher checks and native Ollama context regression checks passed. The production build passed with the new favicon. Saved-story verification retained 44 messages and one character with SQLite integrity `ok`; no narration was generated. Reports and the status-window capture are in ignored `logs/`.

References: [Microsoft AppUserModelIDs](https://learn.microsoft.com/en-us/windows/win32/shell/appids), [DXGI adapter description](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiadapter1-getdesc1), [Windows performance counters](https://learn.microsoft.com/en-us/windows/win32/perfctrs/about-performance-counters).
