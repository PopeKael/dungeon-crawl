import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { createGateway } from './dungeon-gateway.mjs';

const origin = 'https://dungeon.test';
const settings = { bind: '127.0.0.1', port: 3001, allowedPeer: '127.0.0.1', origin, upstreamPort: 3000 };
for (const invalid of [{ bind: '0.0.0.0' }, { allowedPeer: '' }, { origin: 'http://dungeon.test' }, { upstreamPort: -1 }, { origin: 'https://dungeon.test/other' }]) {
  assert.throws(() => createGateway({ ...settings, ...invalid }));
}
let calls = 0;
let seen;
let releaseStream;
const backend = http.createServer(async (req, res) => {
  calls++;
  seen = { url: req.url, headers: req.headers };
  if (req.url === '/stream') {
    res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
    res.write('{"delta":"first"}\n');
    await new Promise(resolve => { releaseStream = resolve; });
    res.end('{"delta":"last"}\n');
    return;
  }
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  res.writeHead(201, { 'Content-Type': 'application/octet-stream', 'Set-Cookie': ['a=1', 'b=2'] });
  res.end(Buffer.concat(chunks));
});
backend.listen(0, '127.0.0.1'); await once(backend, 'listening');
const gateway = createGateway({ ...settings, upstreamPort: backend.address().port });
gateway.listen(0, '127.0.0.1'); await once(gateway, 'listening');
const denied = createGateway({ ...settings, allowedPeer: '127.0.0.2', upstreamPort: backend.address().port });
denied.listen(0, '127.0.0.1'); await once(denied, 'listening');

function request(server, { path = '/', headers = {}, body = Buffer.alloc(0), method = 'POST' } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: '127.0.0.1', port: server.address().port, path, method, agent: false,
      headers: { Host: 'dungeon.test', 'Content-Length': body.length, ...headers } }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
      res.on('error', reject);
    });
    req.on('error', reject); req.end(body);
  });
}

try {
  assert.equal((await request(denied, { headers: { 'X-Forwarded-For': '127.0.0.2' } })).status, 403);
  assert.equal((await request(gateway, { headers: { Host: 'unrelated.test' } })).status, 403);
  assert.equal((await request(gateway, { path: 'http://unrelated.test/' })).status, 400);
  assert.equal(calls, 0, 'Rejected peers, hosts and absolute URLs never reach the backend.');
  const bytes = Buffer.from([0, 255, 128, 13, 10, 1]);
  const response = await request(gateway, { path: '/api/upload?fixture=1', body: bytes,
    headers: { Origin: origin, 'X-Forwarded-Proto': 'http', 'X-Forwarded-For': 'untrusted', Connection: 'close, x-hop', 'X-Hop': 'remove-me' } });
  assert.equal(response.status, 201); assert.deepEqual(response.body, bytes);
  assert.deepEqual(response.headers['set-cookie'], ['a=1', 'b=2']);
  assert.equal(seen.url, '/api/upload?fixture=1'); assert.equal(seen.headers.origin, origin);
  assert.equal(seen.headers.host, 'dungeon.test'); assert.equal(seen.headers['x-forwarded-proto'], 'https');
  assert.equal(seen.headers['x-forwarded-for'], undefined); assert.equal(seen.headers['x-hop'], undefined);
  // The backend cannot finish until the client has received the first delta.
  await new Promise((resolve, reject) => {
    const req = http.get({ hostname: '127.0.0.1', port: gateway.address().port, path: '/stream', headers: { Host: 'dungeon.test' }, agent: false }, res => {
      let text = '';
      res.on('data', chunk => { text += chunk; if (text.includes('first')) releaseStream(); });
      res.on('end', () => { try { assert.match(text, /first/); assert.match(text, /last/); resolve(); } catch (error) { reject(error); } });
      res.on('error', reject);
    });
    req.setTimeout(3000, () => req.destroy(new Error('Streaming was buffered.'))); req.on('error', reject);
  });
  const occupied = createGateway({ ...settings, upstreamPort: backend.address().port });
  const collision = once(occupied, 'error');
  occupied.listen(gateway.address().port, '127.0.0.1');
  assert.equal((await collision)[0].code, 'EADDRINUSE');
  backend.closeAllConnections(); await new Promise(resolve => backend.close(resolve));
  assert.equal((await request(gateway)).status, 502, 'Backend outage is explicit, not a successful empty response.');
  console.log('Passed: gateway configuration, peer/host denial, spoofing, paths, binary bodies, headers/cookies, progressive streaming, occupied port and backend outage. No model or saved data used.');
} finally {
  releaseStream?.();
  for (const server of [gateway, denied, backend]) { server.closeAllConnections(); server.close(); }
}
