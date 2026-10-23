import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { appendFileSync, readFileSync, utimesSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { harness, transcriptLine, waitFor, writeTranscript } from './helpers.js';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const hourAgo = () => new Date(Date.now() - 3600_000);
const old = (line: object) => ({ ...line, timestamp: hourAgo().toISOString() });
const results = (s: { log: { entries: { kind: string }[] } }) => s.log.entries.filter((e) => e.kind === 'result').length;

test('a message for a session busy elsewhere waits for that turn, then goes', async () => {
  const id = randomUUID();
  const agent = { pid: 1, cwd: '/x', kind: 'interactive', sessionId: id, status: 'busy' };
  const h = await harness({ agents: [agent] });
  try {
    const u1 = randomUUID();
    const file = writeTranscript(h.configDir, h.cwd, id, [transcriptLine(id, h.cwd, u1, null, 'user', 'outside prompt')]);
    await h.manager.refreshList();
    await h.manager.refreshAgents();
    assert.equal(h.manager.busyElsewhere(id), true);

    const first = h.manager.enqueue(id, 'first', []);
    h.manager.cancelQueued(id, first);
    h.manager.enqueue(id, 'second', []);
    assert.deepEqual(h.manager.summary(id)?.queued?.map((q) => q.text), ['second']);
    await h.manager.drainQueues();
    assert.equal(h.launches().length, 0, 'nothing is sent while the other turn runs');

    // The other program finishes its turn.
    appendFileSync(file, JSON.stringify(transcriptLine(id, h.cwd, randomUUID(), u1, 'assistant', 'outside reply')) + '\n');
    h.setAgents([{ ...agent, status: 'idle' }]);
    await h.manager.refreshAgents();
    const s = h.manager.session(id)!;
    await waitFor('the queued message is answered', () => results(s) === 1);
    assert.equal(h.manager.summary(id)?.queued, undefined);
    assert.ok(h.launches()[0].includes(`--resume=${id}`) || h.launches()[0].includes(`--resume ${id}`), h.launches()[0]);
    assert.throws(() => h.manager.cancelQueued(id, first), /already sent/);
  } finally {
    await h.close();
  }
});

test('busy only because of background tasks counts as idle', async () => {
  const done = randomUUID();
  const working = randomUUID();
  const h = await harness({
    agents: [
      { pid: 1, cwd: '/x', kind: 'interactive', sessionId: done, status: 'busy' },
      { pid: 1, cwd: '/x', kind: 'interactive', sessionId: working, status: 'busy' },
    ],
  });
  try {
    const u = randomUUID();
    const a = randomUUID();
    // Turn over: the last message is a reply with no tool call.
    const f1 = writeTranscript(h.configDir, h.cwd, done, [
      old(transcriptLine(done, h.cwd, u, null, 'user', 'start a dev server')),
      old(transcriptLine(done, h.cwd, a, u, 'assistant', 'Started it in the background.')),
    ]);
    // Mid-turn: the last message is a tool call still waiting for its result.
    const tool = { ...old(transcriptLine(working, h.cwd, randomUUID(), u, 'assistant', '')), message: { id: 'm1', model: 'fake-model', role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'npm test' } }] } };
    const f2 = writeTranscript(h.configDir, h.cwd, working, [old(transcriptLine(working, h.cwd, u, null, 'user', 'run the tests')), tool]);
    for (const f of [f1, f2]) utimesSync(f, hourAgo(), hourAgo());
    await h.manager.refreshList();
    await h.manager.refreshAgents();
    await waitFor('turn state', () => h.manager.summary(done)?.external?.background === true);
    assert.deepEqual(h.manager.summary(done)?.external, { busy: false, background: true, holder: 'other' });
    assert.equal(h.manager.busyElsewhere(done), false);
    assert.equal(h.manager.summary(working)?.external?.busy, true);
    assert.equal(h.manager.busyElsewhere(working), true);
  } finally {
    await h.close();
  }
});

test('background tasks of a session open elsewhere are listed from its transcript', async () => {
  const id = randomUUID();
  const h = await harness({ agents: [{ pid: 1, cwd: '/x', kind: 'interactive', sessionId: id, status: 'busy', startedAt: hourAgo().getTime() - 60_000 }] });
  try {
    const u = randomUUID();
    const call = { ...old(transcriptLine(id, h.cwd, randomUUID(), u, 'assistant', '')), message: { id: 'm1', model: 'fake-model', role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_1', name: 'Monitor', input: { description: 'PR 12 CI', command: 'gh pr checks 12 --watch' } }] } };
    const res = { ...old(transcriptLine(id, h.cwd, randomUUID(), u, 'user', '')), message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content: 'Monitor started' }] }, toolUseResult: { taskId: 'bmon1', persistent: true } };
    const file = writeTranscript(h.configDir, h.cwd, id, [
      old(transcriptLine(id, h.cwd, u, null, 'user', 'open the PR and wait for CI')),
      call,
      res,
      old(transcriptLine(id, h.cwd, randomUUID(), u, 'assistant', 'Waiting for CI.')),
    ]);
    utimesSync(file, hourAgo(), hourAgo());
    await h.manager.refreshList();
    await h.manager.refreshAgents();
    await waitFor('the monitor is listed', () => h.manager.summary(id)?.tasks?.length === 1);
    const sum = h.manager.summary(id)!;
    assert.equal(sum.external?.background, true);
    assert.deepEqual(sum.tasks?.map((t) => [t.id, t.type, t.description]), [['bmon1', 'monitor', 'PR 12 CI']]);
    assert.equal((sum.activity as { render(l: string): string }).render('en'), 'Open in another app, in the background: PR 12 CI');
  } finally {
    await h.close();
  }
});

test('turns taken elsewhere make Binary restart its own process before sending', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, prompt: 'one' });
    const s = h.manager.session(sum.id)!;
    await waitFor('first turn', () => results(s) === 1);
    await sleep(1800); // our own writes settle
    await s.send('two');
    await waitFor('second turn', () => results(s) === 2);
    assert.equal(h.launches().length, 1, 'no restart without outside changes');
    await sleep(1800);

    // Another program takes a turn on the same transcript.
    const file = join(h.configDir, 'projects', h.cwd.replace(/[^a-zA-Z0-9]/g, '-'), `${sum.id}.jsonl`);
    const lines = readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l) as { uuid?: string; type?: string });
    const tip = lines.findLast((l) => l.type === 'assistant')!.uuid!;
    const u = randomUUID();
    appendFileSync(
      file,
      JSON.stringify(transcriptLine(sum.id, h.cwd, u, tip, 'user', 'from the desktop')) + '\n' + JSON.stringify(transcriptLine(sum.id, h.cwd, randomUUID(), u, 'assistant', 'desktop reply')) + '\n',
    );
    await s.send('three');
    await waitFor('third turn', () => results(s) === 3);
    assert.equal(h.launches().length, 2, 'restarted to pick up the outside turn');
    assert.ok(h.launches()[1].includes('--resume'), h.launches()[1]);
  } finally {
    await h.close();
  }
});
