import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { appendFileSync, mkdirSync, mkdtempSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { SessionSearch, TextIndex, snippet } from '../src/search.js';
import { transcriptLine, writeTranscript } from './helpers.js';

function setup() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-search-')));
  const configDir = join(root, 'claude');
  const cwd = join(root, 'work');
  mkdirSync(join(configDir, 'projects'), { recursive: true });
  mkdirSync(cwd);
  return { configDir, cwd, projects: join(configDir, 'projects') };
}

test('finds sessions by what was said, deep in the transcript', () => {
  const { configDir, cwd, projects } = setup();
  const a = randomUUID();
  const b = randomUUID();
  const lines = [transcriptLine(a, cwd, randomUUID(), null, 'user', 'first prompt about nothing')];
  for (let i = 0; i < 50; i++) lines.push(transcriptLine(a, cwd, randomUUID(), null, 'assistant', `filler reply ${i}`));
  const deep = randomUUID();
  lines.push(transcriptLine(a, cwd, deep, null, 'assistant', 'The Tailscale ACL blocks port 7350 from the phone.'));
  writeTranscript(configDir, cwd, a, lines);
  writeTranscript(configDir, cwd, b, [transcriptLine(b, cwd, randomUUID(), null, 'user', 'tailscale is up')]);

  const index = new TextIndex();
  index.refresh(projects);
  const both = index.search('TAILSCALE', 10);
  assert.deepEqual(new Set(both.map((r) => r.id)), new Set([a, b]));
  // Every word has to be in the same message.
  const one = index.search('tailscale  7350', 10);
  assert.equal(one.length, 1);
  assert.equal(one[0].id, a);
  assert.equal(one[0].snippets[0].uuid, deep);
  assert.equal(one[0].snippets[0].role, 'assistant');
  assert.match(one[0].snippets[0].text, /Tailscale ACL/);
  assert.deepEqual(index.search('nowhere to be found', 10), []);
});

test('reads only what was appended, and skips tool traffic and meta lines', () => {
  const { configDir, cwd, projects } = setup();
  const id = randomUUID();
  const file = writeTranscript(configDir, cwd, id, [transcriptLine(id, cwd, randomUUID(), null, 'user', 'hello')]);
  const index = new TextIndex();
  index.refresh(projects);
  assert.deepEqual(index.search('appended', 10), []);

  const tool = {
    ...transcriptLine(id, cwd, randomUUID(), null, 'user', ''),
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'appended tool output' }] },
  };
  const meta = { ...transcriptLine(id, cwd, randomUUID(), null, 'user', 'appended meta note'), isMeta: true };
  const said = randomUUID();
  appendFileSync(file, [tool, meta, transcriptLine(id, cwd, said, null, 'user', 'appended later')].map((l) => JSON.stringify(l)).join('\n') + '\n');
  // A line still being written waits for its newline.
  appendFileSync(file, JSON.stringify(transcriptLine(id, cwd, randomUUID(), null, 'user', 'appended partial')).slice(0, 40));
  index.refresh(projects);
  const r = index.search('appended', 10);
  assert.equal(r.length, 1);
  assert.equal(r[0].hits, 1);
  assert.equal(r[0].snippets[0].uuid, said);
});

test('a line longer than one read is still found', () => {
  const { configDir, cwd, projects } = setup();
  const id = randomUUID();
  const long = 'x '.repeat(3 << 20) + 'needle at the end';
  writeTranscript(configDir, cwd, id, [transcriptLine(id, cwd, randomUUID(), null, 'user', 'short'), transcriptLine(id, cwd, randomUUID(), null, 'assistant', long)]);
  const index = new TextIndex();
  index.refresh(projects);
  assert.equal(index.search('needle', 10).length, 1);
});

test('snippets show the text around the match', () => {
  const text = 'a'.repeat(200) + ' needle ' + 'b'.repeat(200);
  const s = snippet(text, text.toLowerCase(), 'needle');
  assert.ok(s.startsWith('…') && s.endsWith('…'));
  assert.ok(s.includes('needle'));
  assert.ok(s.length < 200);
});

test('search from the worker thread', async () => {
  const { configDir, cwd } = setup();
  process.env.CLAUDE_CONFIG_DIR = configDir;
  const id = randomUUID();
  writeTranscript(configDir, cwd, id, [transcriptLine(id, cwd, randomUUID(), null, 'user', '搜索更深入的内容')]);
  const search = new SessionSearch();
  try {
    const r = await search.search('深入');
    assert.deepEqual(r.map((x) => x.id), [id]);
    assert.equal((search as unknown as { broken: boolean }).broken, false);
  } finally {
    search.close();
  }
});
