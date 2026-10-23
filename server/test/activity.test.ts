import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { appendFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { lastMessageAt } from '../src/activity.js';
import { harness, transcriptLine, writeTranscript } from './helpers.js';

test('metadata lines appended to a transcript do not make the session recent', async () => {
  const id = randomUUID();
  const h = await harness();
  try {
    const dayAgo = new Date(Date.now() - 86_400_000).toISOString();
    const u1 = randomUUID();
    const a1 = randomUUID();
    const file = writeTranscript(h.configDir, h.cwd, id, [
      { ...transcriptLine(id, h.cwd, u1, null, 'user', 'old prompt'), timestamp: dayAgo },
      { ...transcriptLine(id, h.cwd, a1, u1, 'assistant', 'old reply'), timestamp: dayAgo },
    ]);
    // What Claude Code and a rename append afterwards.
    appendFileSync(file, [
      { type: 'last-prompt', lastPrompt: 'old prompt', sessionId: id },
      { type: 'custom-title', customTitle: 'renamed', sessionId: id },
      { type: 'agent-name', agentName: 'renamed', sessionId: id },
    ].map((l) => JSON.stringify(l) + '\n').join(''));
    await h.manager.refreshList();
    const at = Date.parse(h.manager.summary(id)!.updatedAt);
    assert.equal(at, Date.parse(dayAgo));
  } finally {
    await h.close();
  }
});

test('the last message is found behind a long tail of other lines', () => {
  const id = randomUUID();
  const stamp = '2026-01-02T03:04:05.000Z';
  const big = 'x'.repeat(600_000);
  const dir = mkdtempSync(join(tmpdir(), 'binaryd-activity-'));
  const file = writeTranscript(dir, '/activity-test', id, [
    { ...transcriptLine(id, '/a', randomUUID(), null, 'assistant', big), timestamp: stamp },
    { type: 'attachment', timestamp: '2026-05-05T00:00:00.000Z', attachment: { text: big } },
    { type: 'custom-title', customTitle: 'x', sessionId: id },
  ]);
  assert.equal(lastMessageAt(file), Date.parse(stamp));
  assert.equal(lastMessageAt(file + '.missing'), 0);
});
