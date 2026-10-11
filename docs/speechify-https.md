# Speechify and private HTTPS

This is **Wazza's site-specific reference implementation**, not a universal installation requirement. The domain, addresses, Synology configuration and Windows setup below describe this installation. Dungeon Crawl can run locally without Synology or a reverse proxy. Start with [Networking and HTTPS](NETWORKING-AND-HTTPS.md) for generic deployment modes and the network contract.

Chosen origin: `https://dungeon.dia.net.au`.

## Speak implementation

A Speak button appears immediately after each narrator passage, before image prompts. It selects only the displayed prose and POSTs saved chat/message IDs to `/api/reader`. The server retrieves the saved assistant passage, removes supported emphasis delimiters, writes Unicode text to the Windows clipboard and sends fixed Alt+F1 using SendInput. Story text is passed as base64 data on stdin; no passage is evaluated as code. No dependency on Ariadne runtime, files, API, or Python.

Opt-in `.env.server`:

```ini
WINDOWS_READER_ENABLED=true
APP_ORIGIN=https://dungeon.dia.net.au
```

The helper runs in the interactive Windows user's session. From a phone/another device, it would control this desktop's clipboard/reader, not the remote device. Keep this service private. Request origins are restricted to the configured game origin and localhost:3000; arbitrary input text, player messages and invalid IDs are rejected. The button is disabled during streaming. Failures keep the prose selected and show manual Alt+F1 instructions.

The installed Windows PowerShell policy blocks script files by default. The helper launch uses a process-only `-ExecutionPolicy Bypass`, matching existing project launchers; no persistent policy change is made.

Verified: UI prose selection, exact 471-character clipboard match, Windows accepted all four fixed keystroke events, lint/build, six request-boundary tests. After activation, Warren confirmed that Speechify read the selected passage aloud on HTTPS. Word-by-word highlighting was not separately checked.

## Existing infrastructure inspected 2026-10-10

- Public authoritative DNS: Cloudflare (`hera.ns.cloudflare.com`, `major.ns.cloudflare.com`).
- `ariadne.dia.net.au` and `workshop.dia.net.au` CNAME to `klf23.synology.me`.
- Windows hosts maps Ariadne privately to Synology `192.168.1.200`.
- DSM reverse proxy has separate source hostname rules on HTTPS 443. Ariadne targets HTTPS `192.168.1.100:18765`; other sites use HTTP backends.
- Ariadne leaf certificate is valid Let's Encrypt, only SAN `ariadne.dia.net.au`.
- DSM default workshop certificate covers alicebeauty/dev/warren/workshop, not dungeon. Dedicated garage/Ariadne certificates also exist; a new separate dungeon certificate was subsequently issued.
- `dungeon.dia.net.au` initially returned NXDOMAIN.
- SSH identity is unreadable even outside sandbox. User provided logged-in DSM browser access instead. No local Ariadne files will be read further; GitHub is the reference source.

## Original deployment (2026-10-10; forwarding superseded below)

Warren approved activation of the desktop-only private route and accepted the Windows administrator prompts.

1. Cloudflare DNS-only CNAME `dungeon` -> `klf23.synology.me`, Auto TTL. Saved record verified in the dashboard and using resolver 1.1.1.1.
2. DSM issued a separate Let's Encrypt RSA/ECC certificate `dungeon.dia.net.au`, description `Dungeon private HTTPS`, expiry 8 January 2027, using the existing certificate contact. Assigned specifically to the dungeon service; existing default and other service assignments preserved.
3. DSM profile `Dungeon desktop`: allow `192.168.1.100/32`, then deny all. Attached to the active dungeon route. Existing Ariadne profile unchanged.
4. Windows TCP bridge `192.168.1.100:3001` -> `127.0.0.1:3000`. `DungeonCrawler-NAS-Allow` permits only NAS 192.168.1.200. `DungeonCrawler-Others-Block` explicitly blocks IPv4 ranges 0.0.0.0-192.168.1.199 and 192.168.1.201-255.255.255.255 on that address/port. Both rules enabled, all profiles. Listener and exact firewall filters verified after installation. Next.js remains on localhost port 3000.
5. DSM source `HTTPS dungeon.dia.net.au:443` -> `HTTP 192.168.1.100:3001`, with the desktop profile attached. TLS ends at Synology; the private upstream hop uses HTTP. Default proxy timeouts retained; a short narration request completed successfully. Long-generation behavior has not been benchmarked.
6. Desktop hosts entry: `192.168.1.200 dungeon.dia.net.au # DungeonCrawler private HTTPS`. Only this entry appended; prior file backed up in ignored logs/hosts-before-dungeon.txt. This affects only the desktop.
7. `curl` HTTPS returned 200 with certificate verification result 0 (no trust bypass). Opera loaded the saved story over HTTPS, generated and saved another narration, and successfully handed a selected passage to Speechify. Warren confirmed audible playback. Reader boundary tests 6/6 and phase 1 persistence/manual-image/SQLite checks passed through HTTPS. Story now contains 13 messages. External deny behavior is configured by DSM ACL; it has not been tested from a separate Internet client.

Historical administrator commands (applied on 10 October; not fresh-checkout instructions). The upstream helper has since changed: its current `Install` action migrates to the owned gateway rather than installing the old portproxy. Use the current gateway section below for this site's maintenance.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File F:\AI\DungeonCrawler\scripts\configure-private-upstream.ps1 -Action Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File F:\AI\DungeonCrawler\scripts\configure-private-host.ps1 -Install
# Reversal:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File F:\AI\DungeonCrawler\scripts\configure-private-upstream.ps1 -Action Remove
```

The TCP forwarding mechanism is documented in [Microsoft netsh interface](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-interface). Use a direct private hosts mapping to `192.168.1.200` for this desktop, so DSM sees the desktop source IP rather than a router hairpin address.

Do not expose the unauthenticated game or Windows reader endpoint publicly. No router changes are needed for private use. No new domain purchase is required. Public DNS/certificate issuance and private application access are separate concerns.

## Application-owned private gateway (11 October 2026)

The domain and browser HTTPS route are unchanged. The current path is:

`browser HTTPS -> Synology certificate + desktop ACL -> HTTP 192.168.1.100:3001 (owned Node gateway, NAS peer only) -> HTTP 127.0.0.1:3000 (Next.js)`.

This follows Ariadne's application-owned gateway lifecycle. Ariadne's gateway uses TLS on its upstream hop; Dungeon retains the existing private HTTP NAS-to-desktop hop configured on DSM. Only the browser-to-Synology hop is encrypted in Dungeon's deployment. No Ariadne code, configuration, certificate or model was changed.

The launcher starts both components, records each process identity, verifies listener ownership and the actual HTTPS Dungeon page, then opens the browser. Stop/Exit close both listeners. Start restores a missing gateway or backend. The gateway checks the actual TCP peer against the NAS address and Host against the configured public origin; forwarding headers cannot grant access. It forwards streaming responses without collecting the whole body, preserves request origins and binary uploads, and restricts its backend to loopback. Its listener is an ordinary unprivileged Node process, not IP Helper. Existing Windows Firewall and DSM restrictions remain in force.

For this installation, ignored `config/launcher.json` includes:

```json
{
  "appUrl": "https://dungeon.dia.net.au/",
  "port": 3000,
  "privateGateway": { "bind": "192.168.1.100", "port": 3001, "allowedPeer": "192.168.1.200" }
}
```

These fields are added to the existing readiness policy. A loopback-only checkout can keep `config/launcher.example.json` without a privateGateway. The current Windows launcher's HTTPS startup requires the owned gateway; it does not silently fall back to the former forwarding mechanism. This is a launcher limitation, not a requirement that every HTTPS deployment use this gateway or Synology; see the [generic deployment guide](NETWORKING-AND-HTTPS.md).

One-time administrator installation/migration (normal launches do not elevate):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File F:\AI\DungeonCrawler\scripts\configure-private-upstream.ps1 -Action Install
```

This validates the existing NAS-only firewall rules, creates them if absent, and removes only the old dungeon portproxy entry if its target matches the original deployment. It does not restart IP Helper or touch other forwarding entries. `Repair` is retained as an alias for installation/migration, not recreation of a Windows bridge. `Status` is read-only. The script deliberately covers only the reviewed desktop/NAS addresses; another installation needs its own reviewed firewall scope.

Tests: `node scripts/verify-dungeon-gateway.mjs`, `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-dungeon-processes.ps1`, and `scripts/verify-dungeon-launcher.ps1`. Gateway tests use a disposable loopback backend, not saved stories or GPU inference. Reader boundary tests should also pass through HTTPS.

## Historical reboot failure

The saved portproxy rule and firewall rules can still exist while no process listens on `192.168.1.100:3001`. In that state the loopback game and GPU model can be healthy while private HTTPS times out. Confirm the listener with `Get-NetTCPConnection -LocalAddress 192.168.1.100 -LocalPort 3001 -State Listen`; a saved rule alone does not prove a working bridge.

On 11 October, an in-place refresh failed but recreating the entry restored the listener and verified HTTPS. That manual repair was superseded by the owned gateway above. The underlying reason IP Helper failed to listen after reboot was not established; the application no longer depends on that mechanism.

## Reversal

Disable `WINDOWS_READER_ENABLED` and restart to stop native handoffs. Remove only the new dungeon proxy/certificate assignment, DNS/hosts entry and game-specific network rules when reversing deployment. Preserve all existing Ariadne and other site settings.

Stop Dungeon before removing its gateway firewall protection with `configure-private-upstream.ps1 -Action Remove`. Remove only the tagged DungeonCrawler hosts line; do not overwrite the whole hosts file from an old backup. The owned gateway starts on each application launch; the firewall rules persist across Windows restarts. No new background startup task or Windows service was installed. To intentionally restore the original source checkpoint, restore its matching launcher/config and reviewed portproxy setup together; do not reintroduce the old forwarding entry while the owned gateway is listening on the same port.

Ignored evidence: logs/dungeon-dns-saved.jpg, logs/dungeon-proxy-saved.jpg, logs/dungeon-certificate.jpg, logs/dungeon-https-speak.jpg, logs/dungeon-https.html.

## Checks

```powershell
npm run lint
npm run build
node scripts/verify-reader.mjs
node scripts/verify-phase1.mjs 15f4b699-0db3-4b66-a3e5-5b1694eabdbb
```

The reader test sends only rejected requests and never writes the clipboard or sends a shortcut. Live Speak testing is performed by clicking the button in Opera.
