import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
type Ev = { type: string; data: string };
const collect = (events: Ev[]) => (type: string, data: string) => (events.push({ type, data }), true);
import { harness, hasFlag, transcriptLine, waitFor, writeTranscript } from './helpers.js';

const lines = (s: { log: { entries: { kind: string; blocks?: { type: string; text?: unknown }[] }[] } }) =>
  s.log.entries.map((e) => `${e.kind} ${(e.blocks ?? []).map((b) => `${b.type}:${String(b.text ?? '')}`).join('|')}`.trim());

test('create, stream and merge with the stored transcript', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'hello', model: 'haiku', effort: 'low', title: 'Test title' });
    assert.equal(sum.title, 'Test title');
    const s = h.manager.session(sum.id)!;
    const events: Ev[] = [];
    await s.subscribe(0, '', collect(events));
    await waitFor('first turn', () => s.state === 'idle' && s.log.entries.length >= 3);
    assert.deepEqual(lines(s), ['user text:hello', 'assistant text:echo: hello', 'result']);

    // Output the session list isn't told about keeps the process from idling
    // out, but leaves the listed time alone: a summary taken for a client
    // opening the session matches the list's.
    const listed = h.manager.summary(sum.id)!.updatedAt;
    const active = s.lastActive;
    await new Promise((r) => setTimeout(r, 5));
    (s as unknown as { handle(m: unknown): void }).handle({ type: 'tool_progress' });
    assert.ok(s.lastActive > active);
    assert.equal(h.manager.summary(sum.id)!.updatedAt, listed);

    // The stored transcript holds the same messages under the same uuids.
    await h.manager.refreshList();
    const types = new Set(events.map((e) => e.type));
    for (const t of ['snapshot', 'entries', 'partial', 'session']) assert.ok(types.has(t), `missing ${t} event`);
    const launch = h.launches()[0];
    for (const [flag, value] of [['--session-id', sum.id], ['--model', 'haiku'], ['--effort', 'low']]) {
      assert.ok(hasFlag(launch, flag, value), `${launch} lacks ${flag} ${value}`);
    }

    // Models reported at initialize are cached for /info.
    assert.deepEqual((h.manager.models() as { value: string }[]).map((m) => m.value), ['fake']);

    // After the process ends, the transcript is reloaded without duplicates or a reset.
    const gen = s.log.gen;
    await s.stop();
    await waitFor('reload', () => !s.live);
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(s.log.gen, gen);
    assert.deepEqual(lines(s), ['user text:hello', 'assistant text:echo: hello', 'result']);
  } finally {
    await h.close();
  }
});

for (const behavior of ['allow', 'deny'] as const) {
  test(`permission request: ${behavior}`, async () => {
    const h = await harness();
    try {
      const sum = await h.manager.create({ cwd: h.cwd, prompt: 'needs permission' });
      const s = h.manager.session(sum.id)!;
      await waitFor('permission request', () => s.state === 'waiting');
      const summary = h.manager.summary(sum.id)!;
      assert.equal(summary.pending, 1);
      const events: Ev[] = [];
      await s.subscribe(0, '', collect(events));
      const snap = JSON.parse(events[0].data) as { permissions: { id: string; toolName: string; suggestions?: unknown[] }[] };
      const req = snap.permissions[0];
      assert.equal(req.toolName, 'Write');
      assert.equal(req.suggestions?.length, 1);
      s.respond(req.id, { behavior, message: 'no thanks' });
      await waitFor('turn end', () => s.state === 'idle');
      const want = behavior === 'allow' ? 'tool_result:allowed' : 'tool_result:denied: no thanks';
      assert.ok(lines(s).some((l) => l.includes(want)), lines(s).join('\n'));
      assert.throws(() => s.respond(req.id, { behavior: 'allow' }));
    } finally {
      await h.close();
    }
  });
}

test('stop and resume with changed settings', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'one' });
    const s = h.manager.session(sum.id)!;
    await waitFor('first turn', () => s.state === 'idle' && s.live && s.log.entries.length >= 3);
    await s.stop();
    assert.equal(s.live, false);
    assert.equal(s.state, 'idle');

    await h.manager.update(sum.id, { model: 'sonnet' });
    await s.send('two');
    await waitFor('second turn', () => s.state === 'idle' && lines(s).includes('assistant text:echo: two'));
    const launches = h.launches();
    assert.equal(launches.length, 2);
    assert.ok(hasFlag(launches[1], '--resume', sum.id) && hasFlag(launches[1], '--model', 'sonnet'), launches[1]);
  } finally {
    await h.close();
  }
});

test('effort max restarts the process before the next turn', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'one' });
    const s = h.manager.session(sum.id)!;
    await waitFor('first turn', () => s.state === 'idle' && s.log.entries.length >= 3);
    const { warnings } = await h.manager.update(sum.id, { effort: 'max', model: 'opus' });
    assert.deepEqual(warnings, []);
    assert.equal(s.restart, true);
    await s.send('two');
    await waitFor('second turn', () => s.state === 'idle' && lines(s).includes('assistant text:echo: two'));
    const launches = h.launches();
    assert.equal(launches.length, 2);
    assert.ok(hasFlag(launches[1], '--effort', 'max'), launches[1]);
  } finally {
    await h.close();
  }
});

test('interrupt ends the turn', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'slow work' });
    const s = h.manager.session(sum.id)!;
    await waitFor('running', () => s.state === 'running' && s.live);
    await s.interrupt();
    await waitFor('idle', () => s.state === 'idle');
    assert.ok(lines(s).includes('system'), lines(s).join('\n'));
    assert.equal(s.errMsg, '');
  } finally {
    await h.close();
  }
});

test('sessions written elsewhere are listed, followed live and marked external', async () => {
  const id = randomUUID();
  const h = await harness({ agents: [{ pid: 1, cwd: '/x', kind: 'interactive', sessionId: id, status: 'busy' }] });
  try {
    const u1 = randomUUID();
    const a1 = randomUUID();
    const file = writeTranscript(h.configDir, h.cwd, id, [
      transcriptLine(id, h.cwd, u1, null, 'user', 'outside prompt'),
      transcriptLine(id, h.cwd, a1, u1, 'assistant', 'outside reply'),
    ]);
    await h.manager.refreshList();
    await h.manager.refreshAgents();
    const sum = h.manager.summary(id)!;
    assert.equal(sum.state, 'external');
    assert.equal(sum.title, 'outside prompt');

    const s = h.manager.session(id)!;
    const events: Ev[] = [];
    await s.subscribe(0, '', collect(events));
    assert.deepEqual(lines(s), ['user text:outside prompt', 'assistant text:outside reply']);

    // The other program keeps writing; polling picks it up.
    const u2 = randomUUID();
    await new Promise((r) => setTimeout(r, 1100));
    appendFileSync(file, JSON.stringify(transcriptLine(id, h.cwd, u2, a1, 'user', 'second prompt')) + '\n');
    await waitFor('appended entry', () => lines(s).includes('user text:second prompt'), 8000);
    assert.ok(events.some((e) => e.type === 'entries'));
  } finally {
    await h.close();
  }
});

test('title and tag go to the transcript once it exists', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, title: 'draft', tag: 'grp' });
    assert.equal(h.manager.summary(sum.id)!.tag, 'grp');
    const s = h.manager.session(sum.id)!;
    await s.send('hi');
    await waitFor('turn', () => s.state === 'idle' && s.log.entries.length >= 3);
    await h.manager.refreshList();
    await waitFor('tag applied', () => h.manager.summary(sum.id)?.tag === 'grp');
    const { session } = await h.manager.update(sum.id, { title: 'renamed', tag: '' });
    assert.equal(session.title, 'renamed');
    assert.equal(session.tag ?? '', '');
  } finally {
    await h.close();
  }
});

test('validation', async () => {
  const h = await harness();
  try {
    await assert.rejects(h.manager.create({ cwd: 'relative' }), /absolute path/);
    await assert.rejects(h.manager.create({ cwd: h.cwd + '/missing' }), /does not exist/);
    await assert.rejects(h.manager.create({ cwd: h.cwd, effort: 'extreme' }), /effort/);
    const sum = await h.manager.create({ cwd: h.cwd });
    assert.equal(sum.live, false);
    assert.equal(sum.state, 'idle');
    await assert.rejects(h.manager.update(sum.id, { permissionMode: 'yolo' }), /Permission mode/);
  } finally {
    await h.close();
  }
});

test('a session that changed directory midway still loads (transcript under its first cwd)', async () => {
  const h = await harness();
  try {
    const id = randomUUID();
    const moved = join(h.root, 'worktree');
    mkdirSync(moved);
    const u1 = randomUUID();
    const a1 = randomUUID();
    // Stored under the starting directory's project folder; later lines carry the new cwd.
    writeTranscript(h.configDir, h.cwd, id, [
      transcriptLine(id, h.cwd, u1, null, 'user', 'start here'),
      transcriptLine(id, moved, a1, u1, 'assistant', 'now in the worktree'),
    ]);
    const agentDir = join(h.configDir, 'projects', h.cwd.replace(/[^a-zA-Z0-9]/g, '-'), id, 'subagents');
    mkdirSync(agentDir, { recursive: true });
    const s1 = randomUUID();
    writeFileSync(
      join(agentDir, 'agent-abc123.jsonl'),
      JSON.stringify({ ...transcriptLine(id, moved, s1, null, 'user', 'subagent prompt'), isSidechain: true, agentId: 'abc123' }) + '\n',
    );
    // A subagent with its launch name, which beats the prompt as a title.
    writeFileSync(
      join(agentDir, 'agent-def456.jsonl'),
      JSON.stringify({ ...transcriptLine(id, moved, randomUUID(), null, 'user', 'second prompt'), isSidechain: true, agentId: 'def456' }) + '\n',
    );
    writeFileSync(join(agentDir, 'agent-def456.meta.json'), JSON.stringify({ agentType: 'Explore', description: 'Find the config' }));
    await h.manager.refreshList();
    const s = h.manager.session(id)!;
    await s.subscribe(0, '', () => true);
    assert.deepEqual(lines(s), ['user text:start here', 'assistant text:now in the worktree']);
    const subs = await h.manager.subagents(id);
    assert.deepEqual(
      subs.map((a) => [a.id, a.title, a.prompt, a.running]).sort(),
      [
        // Not running: no claude process holds the session.
        ['abc123', 'subagent prompt', 'subagent prompt', undefined],
        ['def456', 'Find the config', 'second prompt', undefined],
      ],
    );
    assert.ok(subs[0].updatedAt && subs[0].updatedAt === subs[0].startedAt, JSON.stringify(subs[0]));
  } finally {
    await h.close();
  }
});

test('create in a new worktree with environment variables', async () => {
  const h = await harness();
  try {
    const g = (...args: string[]) => execFileSync('git', ['-C', h.cwd, ...args], { stdio: 'pipe' });
    g('init', '-q', '-b', 'main');
    g('-c', 'user.email=t@example.com', '-c', 'user.name=T', 'commit', '-q', '--allow-empty', '-m', 'init');
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'hello', worktree: true, title: 'Try worktree', env: { FOO: 'bar' } });
    assert.match(sum.cwd, /\/\.claude\/worktrees\/try-worktree-[0-9a-f]{6}$/);
    assert.equal(sum.worktree, sum.cwd);
    assert.match(sum.gitBranch ?? '', /^claude\/try-worktree-/);
    const s = h.manager.session(sum.id)!;
    await waitFor('turn', () => s.state === 'idle' && s.log.entries.length >= 3);
    const launch = h.launches()[0];
    assert.ok(launch.includes('FOO=bar') && launch.includes(`CWD=${sum.cwd}`), launch);
    await assert.rejects(h.manager.create({ cwd: h.cwd, env: { 'BAD-NAME': 'x' } }), /environment variable/);
  } finally {
    await h.close();
  }
});

test('images go to Claude and can be fetched back', async () => {
  const h = await harness();
  try {
    const png = Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex').toString('base64');
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'what is this', images: [{ mediaType: 'image/png', data: png }] });
    const s = h.manager.session(sum.id)!;
    await waitFor('turn', () => s.state === 'idle' && s.log.entries.length >= 3);
    const user = s.log.entries[0];
    assert.deepEqual(user.blocks?.map((b) => b.type), ['image', 'text']);
    const key = user.blocks?.[0].image;
    assert.ok(key);
    assert.equal(s.image(key)?.bytes.toString('base64'), png);
    // After a reload from the transcript the same key still resolves.
    await s.stop();
    s.unload();
    await s.ensureLoaded();
    assert.equal(s.log.entries[0].blocks?.[0].image, key);
    assert.equal(s.image(key)?.mediaType, 'image/png');
    // Unsupported types and oversized images are refused before anything starts.
    await assert.rejects(h.manager.create({ cwd: h.cwd, prompt: 'x', images: [{ mediaType: 'image/bmp', data: png }] }), /Unsupported image/);
    const big = Buffer.alloc(6 << 20).toString('base64');
    await assert.rejects(h.manager.create({ cwd: h.cwd, prompt: 'x', images: [{ mediaType: 'image/png', data: big }] }), /Image too large/);
  } finally {
    await h.close();
  }
});

test('background tasks are listed, keep the process open and can be stopped', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'start a background server' });
    const s = h.manager.session(sum.id)!;
    await waitFor('turn', () => s.state === 'idle' && s.tasks.size === 2);
    const listed = h.manager.summaries().find((x) => x.id === sum.id)!;
    assert.deepEqual(listed.tasks?.map((t) => [t.id, t.type, t.ambient ?? false]), [['bash_1', 'shell', false], ['watch_1', 'monitor', true]]);
    // Busy with background work: no idle close time.
    assert.equal(listed.closesAt, undefined);
    assert.equal(s.busyTasks, 1);

    await h.manager.stopTask(sum.id, 'bash_1');
    await waitFor('stopped', () => s.busyTasks === 0);
    // Only housekeeping left: it closes on the idle timeout again.
    assert.ok(h.manager.summaries().find((x) => x.id === sum.id)!.closesAt);
    await assert.rejects(h.manager.stopTask(sum.id, 'bash_1'));
  } finally {
    await h.close();
  }
});
