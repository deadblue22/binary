import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { appendFileSync } from 'node:fs';
import { test } from 'node:test';
import type { Msg } from '../src/i18n.js';
import { harness, transcriptLine, writeTranscript } from './helpers.js';

const render = (m: Msg): string => (typeof m === 'string' ? m : m.render('en'));

/** Stores a one-prompt transcript and returns its session id. */
function session(configDir: string, cwd: string, prompt: string): string {
  const id = randomUUID();
  writeTranscript(configDir, cwd, id, [transcriptLine(id, cwd, randomUUID(), null, 'user', prompt)]);
  return id;
}

test('a "Title:" first line becomes the session title, without the body', async () => {
  const h = await harness();
  try {
    const id = session(h.configDir, h.cwd, 'Title: Fix the flaky login test\n\nThe test fails on CI only, …');
    await h.manager.refreshList();
    const sum = h.manager.summary(id)!;
    assert.equal(render(sum.title), 'Fix the flaky login test');
    assert.equal(sum.preview, 'Title: Fix the flaky login test The test fails on CI only, …');
    assert.equal(h.manager.store.get(id)?.title, 'Fix the flaky login test', 'kept, so it need not be derived again');
  } finally {
    await h.close();
  }
});

test('without a "Title:" line the first prompt line is the title', async () => {
  const h = await harness();
  try {
    const id = session(h.configDir, h.cwd, 'Rewrite the search indexer\nand keep the API as it is');
    await h.manager.refreshList();
    assert.equal(h.manager.summary(id)?.title, 'Rewrite the search indexer');
    assert.equal(h.manager.store.get(id)?.title, 'Rewrite the search indexer');
  } finally {
    await h.close();
  }
});

test('a long first line is cut at a word boundary, not mid-word', async () => {
  const h = await harness();
  try {
    const words = Array.from({ length: 40 }, (_, i) => `word${i + 1}`);
    const id = session(h.configDir, h.cwd, words.join(' '));
    await h.manager.refreshList();
    const title = render(h.manager.summary(id)!.title);
    assert.ok([...title].length <= 80, title);
    assert.ok(title.endsWith('…'), title);
    const kept = title.slice(0, -1).split(' ');
    assert.deepEqual(kept, words.slice(0, kept.length));
  } finally {
    await h.close();
  }
});

test('an existing title is never overwritten', async () => {
  const h = await harness();
  try {
    const id = session(h.configDir, h.cwd, 'Title: Derived from the prompt\nbody');
    h.manager.store.update(id, (r) => (r.title = 'Mine'));
    await h.manager.refreshList();
    assert.equal(h.manager.summary(id)?.title, 'Mine');
    assert.equal(h.manager.store.get(id)?.title, 'Mine');
  } finally {
    await h.close();
  }
});

test('a later summary update does not rename the session', async () => {
  const h = await harness();
  try {
    const id = randomUUID();
    const file = writeTranscript(h.configDir, h.cwd, id, [transcriptLine(id, h.cwd, randomUUID(), null, 'user', 'Title: Kept title\nbody')]);
    await h.manager.refreshList();
    assert.equal(render(h.manager.summary(id)!.title), 'Kept title');
    // Claude Code rewriting the session's summary is what used to rename it.
    appendFileSync(file, JSON.stringify({ type: 'summary', summary: 'A brand new AI title', leafUuid: 'x', sessionId: id }) + '\n');
    await h.manager.refreshList();
    assert.equal(render(h.manager.summary(id)!.title), 'Kept title');
  } finally {
    await h.close();
  }
});
