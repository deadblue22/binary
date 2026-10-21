import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, utimesSync } from 'node:fs';
import { test } from 'node:test';
import { harness, transcriptLine, waitFor, writeTranscript } from './helpers.js';

test('a session held elsewhere is reported as idle-but-held, and forks into a copy', async () => {
  const id = randomUUID();
  const h = await harness({ agents: [{ pid: 1, cwd: '/x', kind: 'interactive', sessionId: id, status: 'idle', startedAt: Date.now() }] });
  try {
    const u1 = randomUUID();
    const a1 = randomUUID();
    const hourAgo = new Date(Date.now() - 3600_000);
    const old = (line: object) => ({ ...line, timestamp: hourAgo.toISOString() });
    const file = writeTranscript(h.configDir, h.cwd, id, [
      old(transcriptLine(id, h.cwd, u1, null, 'user', 'outside prompt')),
      old(transcriptLine(id, h.cwd, a1, u1, 'assistant', 'outside reply')),
    ]);
    const before = readFileSync(file, 'utf8');
    utimesSync(file, hourAgo, hourAgo);
    await h.manager.refreshList();
    await h.manager.refreshAgents();
    const held = h.manager.summary(id)!;
    assert.equal(held.state, 'external');
    assert.deepEqual(held.external, { busy: false, holder: 'other' });
    // A process that was opened just now but is idle is not activity.
    assert.ok(Date.parse(held.updatedAt) < Date.now() - 3000_000, held.updatedAt);

    await h.manager.update(id, { tag: 'grp' });
    const copy = await h.manager.fork(id, { text: 'continue here' });
    assert.notEqual(copy.id, id);
    assert.equal(copy.parentId, id);
    assert.equal(copy.cwd, h.cwd);
    assert.equal(copy.external, undefined);
    const s = h.manager.session(copy.id)!;
    await waitFor('the copy answers', () => s.state === 'idle' && s.log.entries.some((e) => e.kind === 'result'));
    const texts = s.log.entries.flatMap((e) => (e.blocks ?? []).map((b) => `${e.kind}:${String(b.text ?? '')}`));
    assert.ok(texts.includes('user:outside prompt') && texts.includes('user:continue here'), texts.join(' | '));
    assert.ok(h.launches().some((l) => l.includes(`--resume=${copy.id}`) || l.includes(`--resume ${copy.id}`)), h.launches().join('\n'));
    // The original transcript gets nothing new from the fork (apart from the tag written above).
    const after = readFileSync(file, 'utf8');
    assert.ok(after.startsWith(before) && !after.includes('continue here'));
    await h.manager.refreshList();
    assert.equal(h.manager.summary(copy.id)?.tag, 'grp');

    await assert.rejects(h.manager.fork('nope', {}), /not found/);
  } finally {
    await h.close();
  }
});
