<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## Networking

Before changing networking, inspect the complete browser-to-application path. Treat HTTPS and reverse proxy details as configurable infrastructure, not a dependency on one installation. Preserve localhost-safe defaults. Do not invent machine-global forwarding or firewall changes to make a test pass. See [the network contract](docs/NETWORKING-AND-HTTPS.md).
