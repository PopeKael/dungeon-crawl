// Application-owned private edge. Synology terminates public-facing TLS.
import http from 'node:http';
import fs from 'node:fs';
import { isIP } from 'node:net';
import { pathToFileURL } from 'node:url';

const hopHeaders = new Set(['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade']);
function endToEnd(headers) {
  const omitted = new Set([...hopHeaders, ...(headers.connection || '').split(',').map(value => value.trim().toLowerCase())]);
  return Object.fromEntries(Object.entries(headers).filter(([name]) => !omitted.has(name.toLowerCase())));
}

export function createGateway({ bind, port, allowedPeer, origin, upstreamPort }) {
  if (isIP(bind) !== 4 || bind === '0.0.0.0' || isIP(allowedPeer) !== 4 || allowedPeer === '0.0.0.0' ||
      ![port, upstreamPort].every(value => Number.isInteger(value) && value > 0 && value <= 65535)) {
    throw new Error('Gateway requires explicit IPv4 bind/peer addresses and valid ports.');
  }
  const publicOrigin = new URL(origin);
  if (publicOrigin.protocol !== 'https:' || publicOrigin.username || publicOrigin.password || publicOrigin.pathname !== '/' || publicOrigin.search || publicOrigin.hash) {
    throw new Error('Gateway requires a canonical HTTPS origin.');
  }
  const server = http.createServer({ requestTimeout: 60_000, headersTimeout: 15_000 }, (request, response) => {
    // Authorize the TCP peer, never user-controlled forwarding headers.
    if (request.socket.remoteAddress !== allowedPeer || request.headers.host !== publicOrigin.host) {
      response.writeHead(403, { 'Content-Type': 'text/plain', Connection: 'close' });
      response.end('Private gateway: request denied.');
      return;
    }
    if (!request.url.startsWith('/') || request.url.startsWith('//')) {
      response.writeHead(400, { Connection: 'close' }); response.end(); return;
    }
    const headers = endToEnd(request.headers);
    headers.host = publicOrigin.host;
    headers['x-forwarded-proto'] = 'https';
    headers['x-forwarded-host'] = publicOrigin.host;
    delete headers['forwarded'];
    delete headers['x-forwarded-for'];
    const upstream = http.request({ hostname: '127.0.0.1', port: upstreamPort, method: request.method, path: request.url, headers }, incoming => {
      response.writeHead(incoming.statusCode, { ...endToEnd(incoming.headers), 'x-accel-buffering': 'no' });
      response.flushHeaders();
      incoming.on('error', () => response.destroy());
      incoming.pipe(response);
    });
    upstream.setTimeout(300_000, () => upstream.destroy(new Error('Local backend idle timeout.')));
    upstream.on('error', () => {
      if (response.headersSent) { response.destroy(); return; }
      response.writeHead(502, { 'Content-Type': 'text/plain', Connection: 'close' });
      response.end('The local Dungeon backend is unavailable.');
    });
    request.on('error', () => upstream.destroy());
    response.on('close', () => upstream.destroy());
    request.pipe(upstream);
  });
  // This production app uses HTTP streaming, not WebSocket tunnels.
  server.on('upgrade', (_request, socket) => socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'));
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, ''));
    const gateway = config.privateGateway;
    const server = createGateway({ ...gateway, origin: config.appUrl, upstreamPort: config.port });
    server.on('error', error => { console.error(`Private gateway failed: ${error.code || error.message}`); process.exit(1); });
    server.listen(gateway.port, gateway.bind, () => console.log('Dungeon private gateway ready.'));
    for (const signal of ['SIGINT', 'SIGTERM']) {
      process.on(signal, () => { server.close(); server.closeAllConnections(); });
    }
  } catch (error) {
    console.error(`Private gateway configuration failed: ${error.message}`);
    process.exit(1);
  }
}
