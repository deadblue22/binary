import assert from 'node:assert/strict';
import { test } from 'node:test';
import { harness, waitFor } from './helpers.js';

const names = (list: { name: string }[]) => list.map((c) => c.name);

test('slash commands of a live session, of a folder, without terminal-only ones', async () => {
  const h = await harness();
  try {
    // No session yet: a process starts up in the folder and answers.
    const probed = await h.manager.commands(undefined, h.cwd);
    assert.deepEqual(names(probed), ['compact', 'review', 'code-review', 'exit', 'my-skill']);
    const compact = probed.find((c) => c.name === 'compact')!;
    assert.deepEqual(compact, { name: 'compact', description: 'Summarize the conversation', argumentHint: '<instructions>', builtin: true });
    assert.deepEqual(probed.find((c) => c.name === 'code-review')!.aliases, ['review']);

    // A session's init message names the terminal-only commands.
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'hello' });
    const s = h.manager.session(sum.id)!;
    await waitFor('first turn', () => s.state === 'idle' && s.log.entries.length >= 3);
    assert.deepEqual(names(await h.manager.commands(sum.id, undefined)), ['compact', 'review', 'code-review', 'my-skill']);

    // The live process replaces its list as it changes.
    await s.send('a new skill', []);
    await waitFor('second turn', () => s.state === 'idle' && s.log.entries.length >= 6);
    assert.ok(names(await h.manager.commands(sum.id, undefined)).includes('found'));

    await assert.rejects(h.manager.commands('no-such-session', undefined), /not found/i);
  } finally {
    await h.close();
  }
});
