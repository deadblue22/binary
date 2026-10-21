import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { createServer, request, type IncomingHttpHeaders, type Server } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createGunzip, gunzipSync } from 'node:zlib';
import { after, before, test } from 'node:test';
import { createHandler } from '../src/api.js';
import { harness, transcriptLine, writeTranscript, type Harness } from './helpers.js';

let h: Harness;
let server: Server;
let base: string;
const TOKEN = 'test-token';

before(async () => {
  // Sending launches a claude that does not exist: failures must be reported.
  h = await harness({ claudePath: '/nonexistent/claude' });
  server = createServer(
    createHandler({ manager: h.manager, token: TOKEN, name: 'test', version: '0', claudePath: '/x', claudeVersion: '0', log: () => {} }),
  );
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const addr = server.address() as { port: number };
  base = `http://127.0.0.1:${addr.port}`;
});

after(async () => {
  server.closeAllConnections();
  server.close();
  await h.close();
});

async function call(method: string, path: string, body?: unknown, token: string | null = TOKEN): Promise<{ status: number; json: Record<string, unknown> }> {
  const res = await fetch(base + path, {
    method,
    headers: { ...(token && { Authorization: `Bearer ${token}` }), ...(body !== undefined && { 'Content-Type': 'application/json' }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, json: text ? JSON.parse(text) : {} };
}

test('auth', async () => {
  assert.equal((await call('GET', '/api/v1/info', undefined, null)).status, 401);
  assert.equal((await call('GET', '/api/v1/info', undefined, 'wrong')).status, 401);
  const info = await call('GET', '/api/v1/info');
  assert.equal(info.status, 200);
  assert.equal(info.json.name, 'test');
  assert.ok(Array.isArray(info.json.effortLevels));
  assert.equal((await call('GET', '/healthz', undefined, null)).status, 200);
  const q = await fetch(`${base}/api/v1/info?token=${TOKEN}`);
  assert.equal(q.status, 200);
});

test('create, list, update and errors', async () => {
  const created = await call('POST', '/api/v1/sessions', { cwd: h.cwd, title: 't1', effort: 'high' });
  assert.equal(created.status, 201);
  const id = created.json.id as string;
  assert.equal(created.json.title, 't1');
  assert.equal(created.json.effort, 'high');
  assert.equal(created.json.live, false);
  assert.equal(typeof created.json.createdAt, 'string');

  assert.equal((await call('POST', '/api/v1/sessions', { cwd: 'relative/path' })).status, 400);
  assert.equal((await call('POST', '/api/v1/sessions', '{bad')).status, 400);
  const list = await call('GET', '/api/v1/sessions');
  assert.equal((list.json.sessions as unknown[]).length, 1);
  assert.equal((await call('GET', '/api/v1/sessions/nope')).status, 404);
  assert.equal((await call('POST', `/api/v1/sessions/${id}/interrupt`)).status, 409);
  assert.equal((await call('POST', `/api/v1/sessions/${id}/permissions/x`, { behavior: 'maybe' })).status, 400);
  assert.equal((await call('POST', `/api/v1/sessions/${id}/permissions/x`, { behavior: 'allow' })).status, 409);
  assert.equal((await call('DELETE', `/api/v1/sessions/${id}`)).status, 405);

  const patched = await call('PATCH', `/api/v1/sessions/${id}`, { model: 'opus', tag: 'g1' });
  assert.equal(patched.status, 200);
  assert.equal((patched.json.session as Record<string, unknown>).model, 'opus');
  assert.equal((patched.json.session as Record<string, unknown>).tag, 'g1');

  // claude can't be launched here: the error is returned and kept on the session.
  const sent = await call('POST', `/api/v1/sessions/${id}/messages`, { text: 'hi' });
  assert.equal(sent.status, 502);
  const sum = await call('GET', `/api/v1/sessions/${id}`);
  assert.equal(sum.json.state, 'error');
  assert.ok(sum.json.error);
  assert.equal((await call('POST', `/api/v1/sessions/${id}/messages`, { text: '  ' })).status, 400);

  const subs = await call('GET', `/api/v1/sessions/${id}/subagents`);
  assert.deepEqual(subs.json, { subagents: [] });
  assert.equal((await call('GET', '/api/v1/sessions/nope/subagents')).status, 404);
});

test('event stream starts with a snapshot', async () => {
  const ctrl = new AbortController();
  const res = await fetch(`${base}/api/v1/events`, { headers: { Authorization: `Bearer ${TOKEN}` }, signal: ctrl.signal });
  assert.match(res.headers.get('content-type') ?? '', /^text\/event-stream/);
  const reader = res.body!.getReader();
  let buf = '';
  for (;;) {
    const { value, done } = await reader.read();
    assert.ok(!done, 'stream ended without events');
    buf += new TextDecoder().decode(value);
    const line = buf.split('\n').find((l) => l.startsWith('data: '));
    if (line) {
      assert.equal(JSON.parse(line.slice(6)).type, 'sessions');
      break;
    }
  }
  ctrl.abort();
});

test('directory browsing', async () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-dirs-')));
  mkdirSync(join(dir, 'repo', '.git'), { recursive: true });
  mkdirSync(join(dir, '.hidden'));
  writeFileSync(join(dir, 'file.txt'), '');
  const listing = await call('GET', `/api/v1/fs/dirs?path=${encodeURIComponent(dir)}`);
  assert.deepEqual(listing.json.entries, [{ name: 'repo', path: join(dir, 'repo'), isGit: true }]);
  const withHidden = await call('GET', `/api/v1/fs/dirs?path=${encodeURIComponent(dir)}&hidden=1`);
  assert.equal((withHidden.json.entries as unknown[]).length, 2);
  const made = await call('POST', '/api/v1/fs/mkdir', { path: join(dir, 'new', 'nested') });
  assert.equal(made.status, 201);
  assert.ok(statSync(join(dir, 'new', 'nested')).isDirectory());
  assert.equal((await call('GET', '/api/v1/fs/dirs?path=relative')).status, 400);
});

test('text follows Accept-Language', async () => {
  const get = (lang?: string) =>
    fetch(`${base}/api/v1/sessions/nope`, { headers: { Authorization: `Bearer ${TOKEN}`, ...(lang && { 'Accept-Language': lang }) } }).then(
      async (r) => ({ lang: r.headers.get('content-language'), body: (await r.json()) as { error: string } }),
    );
  assert.deepEqual(await get('en'), { lang: 'en', body: { error: 'Session not found' } });
  const zh = await get('zh-CN');
  assert.equal(zh.lang, 'zh');
  assert.notEqual(zh.body.error, 'Session not found');
  assert.deepEqual(await get(), { lang: 'en', body: { error: 'Session not found' } });
  const r = await fetch(`${base}/api/v1/info`, { headers: { Authorization: 'Bearer wrong', 'Accept-Language': 'en' } });
  assert.deepEqual(await r.json(), { error: 'Invalid token' });
});

test('sending to a session whose folder is gone is refused', async () => {
  const id = randomUUID();
  const gone = join(h.root, 'gone');
  writeTranscript(h.configDir, gone, id, [transcriptLine(id, gone, randomUUID(), null, 'user', 'old')]);
  await h.manager.refreshList();
  const list = await call('GET', '/api/v1/sessions');
  const sum = (list.json.sessions as { id: string; cwdExists?: boolean }[]).find((s) => s.id === id);
  assert.equal(sum?.cwdExists, false);
  const res = await call('POST', `/api/v1/sessions/${id}/messages`, { text: 'hi' });
  assert.equal(res.status, 409);
  assert.match(res.json.error as string, new RegExp(`${gone}$`));
});

/** Opens an SSE stream and resolves with the first event of the given type (and the response headers). */
function firstEvent(path: string, type: string, headers: Record<string, string> = {}): Promise<{ data: Record<string, unknown>; headers: IncomingHttpHeaders }> {
  return new Promise((resolve, reject) => {
    const req = request(base + path, { headers: { Authorization: `Bearer ${TOKEN}`, ...headers } }, (res) => {
      const body = res.headers['content-encoding'] === 'gzip' ? res.pipe(createGunzip()) : res;
      let buf = '';
      body.on('data', (chunk: Buffer) => {
        buf += chunk.toString();
        const m = new RegExp(`event: ${type}\\ndata: (.*)\\n\\n`).exec(buf);
        if (m) {
          resolve({ data: JSON.parse(m[1]) as Record<string, unknown>, headers: res.headers });
          req.destroy();
        }
      });
      body.on('error', () => undefined);
    });
    req.on('error', (err) => (err.message.includes('socket hang up') ? undefined : reject(err)));
    req.end();
    setTimeout(() => reject(new Error(`no ${type} event`)), 5000).unref();
  });
}

test('gzip, snapshot size, resuming from cached uuids and paging by uuid', async () => {
  const id = randomUUID();
  const uuids = Array.from({ length: 6 }, () => randomUUID());
  writeTranscript(
    h.configDir,
    h.cwd,
    id,
    uuids.map((u, i) => transcriptLine(id, h.cwd, u, i ? uuids[i - 1] : null, i % 2 ? 'assistant' : 'user', `message ${i} ` + 'x'.repeat(400))),
  );
  await h.manager.refreshList();

  // Plain JSON replies are gzipped only for clients that take it.
  const raw = (headers: Record<string, string>) =>
    new Promise<{ encoding?: string; json: { entries: { uuid: string }[] } }>((resolve, reject) => {
      request(base + `/api/v1/sessions/${id}/entries`, { headers: { Authorization: `Bearer ${TOKEN}`, ...headers } }, (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c: Buffer) => chunks.push(c));
        res.on('end', () => {
          const body = Buffer.concat(chunks);
          const text = res.headers['content-encoding'] === 'gzip' ? gunzipSync(body).toString() : body.toString();
          resolve({ encoding: res.headers['content-encoding'], json: JSON.parse(text) });
        });
      })
        .on('error', reject)
        .end();
    });
  const zipped = await raw({ 'Accept-Encoding': 'gzip, deflate' });
  assert.equal(zipped.encoding, 'gzip');
  assert.equal(zipped.json.entries.length, 6);
  assert.equal((await raw({})).encoding, undefined);

  // A gzipped event stream still delivers events as they happen.
  const snap = await firstEvent(`/api/v1/sessions/${id}/events?tail=2&compress=gzip`, 'snapshot', { 'Accept-Encoding': 'gzip' });
  assert.equal(snap.headers['content-encoding'], 'gzip');
  assert.deepEqual((snap.data.entries as { uuid: string }[]).map((e) => e.uuid), uuids.slice(4));
  assert.equal(snap.data.hasMore, true);

  // From a cache: only what follows the newest uuid the log still has.
  const delta = await firstEvent(`/api/v1/sessions/${id}/events?tail=60&after=${randomUUID()},${uuids[3]},${uuids[1]}`, 'delta');
  assert.equal(delta.data.anchor, uuids[3]);
  assert.deepEqual((delta.data.entries as { uuid: string }[]).map((e) => e.uuid), uuids.slice(4));
  assert.ok(delta.data.session);
  // Unknown uuids, or more new entries than the tail: a snapshot instead.
  const unknown = await firstEvent(`/api/v1/sessions/${id}/events?tail=3&after=${randomUUID()}`, 'snapshot');
  assert.equal((unknown.data.entries as unknown[]).length, 3);
  const tooMany = await firstEvent(`/api/v1/sessions/${id}/events?tail=2&after=${uuids[0]}`, 'snapshot');
  assert.equal((tooMany.data.entries as unknown[]).length, 2);

  // Older entries by the uuid of the oldest one the client has.
  const page = await call('GET', `/api/v1/sessions/${id}/entries?beforeUuid=${uuids[3]}&limit=2`);
  assert.deepEqual((page.json.entries as { uuid: string }[]).map((e) => e.uuid), uuids.slice(1, 3));
  assert.equal(page.json.hasMore, true);
  const gone = await call('GET', `/api/v1/sessions/${id}/entries?beforeUuid=${randomUUID()}`);
  assert.deepEqual(gone.json.entries, []);
});

test('files a conversation points at, relative to the session folder', async () => {
  const created = await call('POST', '/api/v1/sessions', { cwd: h.cwd, title: 'files' });
  const id = created.json.id as string;
  mkdirSync(join(h.cwd, 'out'), { recursive: true });
  writeFileSync(join(h.cwd, 'out', 'page.html'), '<h1>hi</h1>');
  const get = (p: string) => fetch(`${base}/api/v1/sessions/${id}/file?path=${encodeURIComponent(p)}`, { headers: { Authorization: `Bearer ${TOKEN}` } });
  const page = await get('out/page.html');
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type') ?? '', /^text\/html/);
  assert.equal(await page.text(), '<h1>hi</h1>');
  assert.equal((await get(join(h.cwd, 'out', 'page.html'))).status, 200);
  assert.equal((await get('out')).status, 404);
  assert.equal((await get('missing.png')).status, 404);
});
