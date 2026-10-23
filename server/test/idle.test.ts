import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import { type AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { loadConfig } from '../src/config.js';
import { busyReason, waitIdle } from '../src/idle.js';

const live = (state: string, extra: object = {}) => ({ id: 'abcdef123', title: 'A session', live: true, state, ...extra });

/** A server answering /api/v1/sessions with each list in turn (the last one repeats). */
async function serving(lists: object[][], token: string): Promise<{ server: Server; port: number; asked: () => number }> {
  let n = 0;
  const server = createServer((req, res) => {
    if (req.headers.authorization !== `Bearer ${token}`) return void res.writeHead(401).end();
    const sessions = lists[Math.min(n++, lists.length - 1)];
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ sessions }));
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  return { server, port: (server.address() as AddressInfo).port, asked: () => n };
}

function config(port: number) {
  const cfg = loadConfig(mkdtempSync(join(tmpdir(), 'binaryd-idle-')));
  cfg.data.listen = `127.0.0.1:${port}`;
  return cfg;
}

test('what keeps a session from a restart', () => {
  assert.equal(busyReason(live('running')), 'turn running');
  assert.equal(busyReason(live('waiting')), 'waiting for approval');
  assert.equal(busyReason(live('idle', { tasks: [{ type: 'monitor', description: 'file watcher', ambient: true }] })), '', 'housekeeping only');
  assert.equal(busyReason(live('idle', { tasks: [{ type: 'shell', description: 'npm run dev' }] })), '1 background task (npm run dev)');
  assert.equal(busyReason(live('idle', { queued: [{}] })), 'messages queued');
  assert.equal(busyReason({ id: 'x', state: 'external', live: false }), '', 'not ours to interrupt');
  assert.equal(busyReason(live('idle')), '');
});

test('waits until two checks in a row find nothing busy, saying what it waits for', async () => {
  const probe = config(1);
  const { server, port, asked } = await serving([[live('running')], [live('idle')], [live('running')], [live('idle')]], probe.data.token);
  try {
    const cfg = config(port);
    cfg.data.token = probe.data.token;
    const said: string[] = [];
    assert.equal(await waitIdle(cfg, { everyMs: 20, log: (m) => said.push(m) }), true);
    assert.equal(asked(), 5, 'a moment of idle between turns is not enough');
    assert.equal(said.length, 1, 'the same wait is said once');
    assert.match(said[0]!, /waiting for 1 session to be idle:\n {2}A session: turn running/);
  } finally {
    server.close();
  }
});

test('gives up after the timeout; a server that does not answer has nothing to wait for', async () => {
  const probe = config(1);
  const { server, port } = await serving([[live('running')]], probe.data.token);
  try {
    const cfg = config(port);
    cfg.data.token = probe.data.token;
    assert.equal(await waitIdle(cfg, { everyMs: 20, timeoutMs: 150, log: () => {} }), false);
  } finally {
    server.close();
  }
  assert.equal(await waitIdle(config(port), { everyMs: 20, log: () => {} }), true);
});
