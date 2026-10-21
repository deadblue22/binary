import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { SessionLister } from '../src/lister.js';
import { transcriptLine, writeTranscript } from './helpers.js';

test('session list from the worker thread', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-lister-')));
  const configDir = join(root, 'claude');
  const cwd = join(root, 'work');
  mkdirSync(join(configDir, 'projects'), { recursive: true });
  mkdirSync(cwd);
  process.env.CLAUDE_CONFIG_DIR = configDir;
  const id = randomUUID();
  writeTranscript(configDir, cwd, id, [transcriptLine(id, cwd, randomUUID(), null, 'user', 'listed off the main thread')]);
  const lister = new SessionLister();
  try {
    const infos = await lister.list();
    assert.deepEqual(infos.map((i) => i.sessionId), [id]);
    assert.equal(infos[0].firstPrompt, 'listed off the main thread');
    // A second call reuses the same worker.
    assert.equal((await lister.list()).length, 1);
    assert.equal((lister as unknown as { broken: boolean }).broken, false);
  } finally {
    lister.close();
  }
});
