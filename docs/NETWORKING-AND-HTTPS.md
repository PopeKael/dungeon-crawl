# Networking and HTTPS

Dungeon Crawl can run locally without a NAS, Synology, reverse proxy or public domain. Its application server and its browser-facing HTTPS edge are separate concerns. Choose the edge for your deployment; Wazza's home network is not part of the product contract.

For basic local play, run the application on loopback HTTP, normally `http://127.0.0.1:3000`. After configuring the application and building it, the terminal start command is:

```powershell
npm run start -- --hostname 127.0.0.1 --port 3000
```

See [local configuration](phase1-local.md) and [Windows launcher setup](windows-launcher.md) for the other prerequisites. Loopback binds the application to the machine running it. Another computer's `127.0.0.1` refers to that other computer, not to the Dungeon Crawl host.

## Deployment modes

### 1. Local-only

```text
Browser on the same machine -> HTTP localhost Dungeon Crawl
```

No HTTPS is required for basic local play. Keep the listener on loopback. Browser features and external integrations have their own secure-origin requirements; do not assume that every integration accepts HTTP merely because local text play works.

### 2. Private/home network HTTPS

```text
Browser -> HTTPS reverse proxy/gateway -> Dungeon Crawl loopback service
```

HTTPS is the preferred browser-facing architecture when accessing the application from another device, exposing it beyond localhost, or using browser features/services that require a secure origin. Configure a hostname, a certificate trusted by the client, and an explicit route to the application.

A proxy on the application host can connect directly to its loopback listener. A proxy on another machine, including a NAS, cannot connect to the application's loopback address directly. It needs a deliberately configured private ingress on the application host, such as an application-owned gateway restricted to the proxy peer. That gateway can relay to the loopback application. Do not solve this by silently exposing the application on all interfaces.

Internal HTTP between the TLS edge and application is acceptable when appropriately isolated: for example, loopback or a controlled private network restricted to the intended proxy. A private address alone does not establish isolation. Use encryption for an upstream hop crossing an untrusted network.

### 3. Self-contained single-machine stack

```text
Browser -> local HTTPS proxy/gateway -> local Dungeon Crawl application
```

The proxy/gateway can run in Docker, a lightweight VM, or another local service. This trades RAM and startup time for a more packaged deployment. Container and VM loopback addresses belong to their own network environments; configure an explicit, restricted route to the application rather than assuming their `127.0.0.1` reaches the host.

Any gateway owned by Dungeon Crawl must have configurable addresses, ports and routing, start with the application when required, be health-checked, and stop through the application's lifecycle controls. An externally managed proxy can retain its own lifecycle, with Dungeon Crawl checking its configured browser-facing route.

### 4. Existing infrastructure

TLS may terminate at Synology, Caddy, nginx, Traefik, another reverse proxy, a secure tunnel, a Docker-hosted proxy, a VM, or an application-owned gateway with TLS support. The choice does not change the application's basic loopback service contract. A tunnel is a transport choice; it does not itself make an unauthenticated application safe to publish.

[Speechify and private HTTPS](speechify-https.md) records **Wazza's site-specific Synology implementation**, including its current Windows gateway, addresses, domain and historical migration. Synology is a reference implementation, not a product dependency. Do not copy that installation's network values or administrator commands into an unrelated deployment.

### 5. Future packaged product

Dungeon Crawl should eventually start and supervise its required application-level services without requiring knowledge of Wazza's network. Configuration should describe the local listener, browser URL and any required gateway; startup should report which component failed and recover missing owned services through normal application controls.

This is a packaging direction, not a claim that every topology above has a turnkey installer today. The current Windows launcher supports loopback HTTP and the owned private gateway used by the reference installation. Its HTTPS startup currently requires `privateGateway` configuration. An externally managed HTTPS edge can front the normally started application server, but using that topology through the launcher may require future launcher work. The current reference gateway provides private HTTP ingress; Synology terminates TLS in that installation.

## Network contract

| Concern | Contract |
|---|---|
| Local application listener | Default to loopback HTTP, normally `127.0.0.1:3000`. Configure ports deliberately; do not broaden binding just to make a probe succeed. |
| Canonical/public URL | The URL the browser uses, chosen for the deployment. It can be localhost HTTP for local play or a configured HTTPS hostname. “Public URL” does not imply public Internet access. Keep application origin checks and integration configuration aligned with it. |
| TLS termination | Identify the component presenting the certificate and handling HTTPS. Its certificate must match the browser hostname and be trusted by the intended clients. |
| Gateway/reverse proxy | Document each hop, listener and allowed peer. Keep owned gateways configurable and lifecycle-managed; distinguish externally managed infrastructure. |
| Health checking | Check the local application, any required gateway and the complete browser-facing route, including TLS and application identity. An open port alone is insufficient. Report the failing hop. |
| Streaming | Preserve incremental response delivery, cancellation and suitable timeouts. Avoid buffering the complete narration before forwarding it. Verify streaming through the deployed edge. |
| Forwarded headers | Preserve the intended browser-facing Host and protocol through the chain, using the appropriate Host and forwarded-header configuration. Trusted proxies must replace or sanitize client-supplied forwarding information; applications must not blindly trust arbitrary clients' headers. |
| Security boundary | Keep the application and Windows reader private. Restrict ingress to intended users/proxy peers and protect any remote access with an appropriate authenticated access boundary. HTTPS encrypts traffic; it does not provide user authorization. |

## Configuration and private data

Do not expose an unauthenticated Dungeon Crawl or Windows reader endpoint directly to the public Internet. The reader can invoke software on the Windows host, so its boundary includes the desktop, not just story text. Preserve its origin checks and existing restrictions.

Avoid machine-global forwarding hacks, firewall changes or certificate changes unless a deployment explicitly requires them and documents their scope, ownership, verification and reversal. Do not invent these changes to make a test pass. Prefer localhost-safe defaults and explicit application-level infrastructure.

Generated stories, credentials and private configuration must remain local and ignored by Git. The repository already ignores `data/`, generated media, logs, `.env.server` and `config/launcher.json`. Use tracked examples without secrets for shared configuration. Verify ignore coverage before creating additional deployment files or certificate keys; do not assume every private filename is automatically ignored. Local persistence does not prevent a selected external provider or reader from receiving content; review its data handling separately.
