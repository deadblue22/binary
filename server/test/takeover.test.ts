import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createServer, type Server } from 'node:http';
import { test } from 'node:test';
import { createHandler } from '../src/api.js';
import { harness, transcriptLine, waitFor, writeTranscript, type Harness } from './helpers.js';

const TOKEN = 'test-token';
const results = (s: { log: { entries: { kind: string }[] } }) => s.log.entries.filter((e) => e.kind === 'result').length;

/** The session belongs to another program, mid-turn. */
async function busyElsewhere(h: Harness): Promise<{ id: string; file: string }> {
  const id = randomUUID();
  const file = writeTranscript(h.configDir, h.cwd, id, [transcriptLine(id, h.cwd, randomUUID(), null, 'user', 'outside prompt')]);
  h.setAgents([{ pid: 1, cwd: h.cwd, kind: 'interactive', sessionId: id, status: 'busy' }]);
  await h.manager.refreshList();
  await h.manager.refreshAgents();
  assert.equal(h.manager.busyElsewhere(id), true);
  return { id, file };
}

/** An HTTP server on the harness's manager. */
async function serve(h: Harness): Promise<{ base: string; server: Server }> {
  const server = createServer(
    createHandler({ manager: h.manager, token: TOKEN, name: 'test', version: '0', claudePath: '/x', claudeVersion: '0', log: () => {} }),
  );
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const addr = server.address() as { port: number };
  return { base: `http://127.0.0.1:${addr.port}`, server };
}

async function call(base: string, method: string, path: string, body?: unknown): Promise<{ status: number; json: Record<string, unknown> }> {
  const res = await fetch(base + path, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, ...(body !== undefined && { 'Content-Type': 'application/json' }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, json: text ? JSON.parse(text) : {} };
}

test('takeover ends the other turn: interrupt works and messages stop queueing', async () => {
  const h = await harness();
  const { base, server } = await serve(h);
  try {
    const { id } = await busyElsewhere(h);
    const taken = await call(base, 'POST', `/api/v1/sessions/${id}/takeover`);
    assert.equal(taken.status, 200);
    const session = taken.json.session as Record<string, unknown>;
    assert.equal(session.id, id);
    assert.equal((session.external as { busy?: boolean } | undefined)?.busy, false, 'no turn is left there');
    assert.deepEqual(taken.json.former, { holder: 'other', pid: 1, interrupted: false });
    assert.equal(h.manager.busyElsewhere(id), false);

    // The turn was ended by the takeover, so interrupt is accepted, not 409.
    assert.equal((await call(base, 'POST', `/api/v1/sessions/${id}/interrupt`)).status, 200);

    const sent = await call(base, 'POST', `/api/v1/sessions/${id}/messages`, { text: 'from binary' });
    assert.equal(sent.status, 202);
    assert.equal(sent.json.queued, undefined, 'sent now, not queued');
    const s = h.manager.session(id)!;
    await waitFor('the message is answered', () => results(s) === 1);
    assert.equal(h.manager.summary(id)?.queued, undefined);
    assert.ok(h.launches()[0].includes(`--resume`), h.launches()[0]);
  } finally {
    server.closeAllConnections();
    server.close();
    await h.close();
  }
});

test('takeover of a session nobody else holds is a no-op', async () => {
  const h = await harness();
  const { base, server } = await serve(h);
  try {
    const created = await call(base, 'POST', '/api/v1/sessions', { cwd: h.cwd, title: 'mine' });
    const id = created.json.id as string;
    const taken = await call(base, 'POST', `/api/v1/sessions/${id}/takeover`);
    assert.equal(taken.status, 200);
    assert.equal((taken.json.session as Record<string, unknown>).title, 'mine');
    assert.equal(taken.json.former, undefined);
    assert.equal((await call(base, 'POST', '/api/v1/sessions/nope/takeover')).status, 404);
  } finally {
    server.closeAllConnections();
    server.close();
    await h.close();
  }
});
