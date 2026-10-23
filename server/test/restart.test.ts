import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { toEntries, type RawMessage } from '../src/normalize.js';
import { resumeNote } from '../src/restart.js';
import { harness, waitFor } from './helpers.js';

const transcript = (h: { configDir: string; cwd: string }, id: string) =>
  readFileSync(join(h.configDir, 'projects', h.cwd.replace(/[^a-zA-Z0-9]/g, '-'), `${id}.jsonl`), 'utf8');

test('a turn cut off by a restart is resumed with a note naming the stopped tasks', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'start a background server, then slow work' });
    const s = h.manager.session(sum.id)!;
    await waitFor('running with tasks', () => s.state === 'running' && s.tasks.size === 2);

    await h.restart(0);
    assert.equal(existsSync(join(h.root, 'home', 'resume.json')), false, 'the record is used once');
    const s2 = h.manager.session(sum.id)!;
    await waitFor('the note is answered', () => transcript(h, sum.id).includes('echo: <binary-restart>'));
    assert.ok(h.launches().at(-1)!.includes(`--resume=${sum.id}`), h.launches().at(-1));

    const note = transcript(h, sum.id).split('\n').filter(Boolean).map((l) => JSON.parse(l) as RawMessage)
      .find((m) => m.type === 'user' && typeof m.message?.content === 'string' && m.message.content.startsWith('<binary-restart>'))!;
    const text = note.message!.content as string;
    assert.match(text, /last turn was cut off/);
    assert.match(text, /shell: npm run dev/);
    assert.doesNotMatch(text, /file watcher/, 'housekeeping tasks are left out');
    await waitFor('idle', () => s2.state === 'idle');
  } finally {
    await h.close();
  }
});

test('a stop lets a running turn finish and holds new messages for the next start', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'slow work' });
    const old = h.manager;
    const s = old.session(sum.id)!;
    await waitFor('running', () => s.state === 'running');

    const restarting = h.restart(20_000);
    await waitFor('closing', () => old.closing);
    old.enqueue(sum.id, 'sent during the restart', []);
    assert.equal(old.summary(sum.id)?.queued?.length, 1);
    await restarting;

    const t = transcript(h, sum.id);
    assert.ok(t.includes('echo: slow work'), 'the running turn finished');
    await waitFor('the held message is answered', () => transcript(h, sum.id).includes('echo: sent during the restart'));
    assert.ok(!transcript(h, sum.id).includes('<binary-restart>'), 'nothing was cut off, so no note');
  } finally {
    await h.close();
  }
});

test('the note shows as a system line, and says only what applies', () => {
  const only = resumeNote({ id: 'x', turn: false, tasks: [{ id: 'm1', type: 'monitor', description: 'PR 12 CI', startedAt: '2026-10-23T07:28:30Z' }], queued: [] }, '2026-10-23T08:00:00Z');
  assert.doesNotMatch(only, /cut off/);
  assert.match(only, /- monitor: PR 12 CI, started 2026-10-23T07:28:30Z/);
  const [e] = toEntries([{ type: 'user', uuid: 'u1', message: { role: 'user', content: only } } as RawMessage]);
  assert.equal(e?.kind, 'system');
  assert.equal(e?.subtype, 'binary_restart');
});
