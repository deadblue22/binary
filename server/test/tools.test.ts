import assert from 'node:assert/strict';
import { test } from 'node:test';
import { SESSION_TOOLS, sessionToolDefs, type SessionToolHost } from '../src/tools.js';
import { harness, waitFor } from './helpers.js';

type Def = { name: string; handler: (args: Record<string, string>, extra: unknown) => Promise<{ content: { text: string }[]; isError?: boolean }> };

function call(defs: unknown[], name: string, args: Record<string, string>) {
  const d = (defs as Def[]).find((x) => x.name === name)!;
  return d.handler(args, {});
}

test('session tools: self, other sessions, errors', async () => {
  const titles = new Map([['s1', 'One'], ['s2', 'Two']]);
  const host: SessionToolHost = {
    sessionInfo: (id) => (titles.has(id) ? { id, title: titles.get(id) } : undefined),
    setTitle: async (id, t) => (titles.set(id, t), t),
  };
  const defs = sessionToolDefs('s1', host);
  assert.deepEqual(SESSION_TOOLS, ['mcp__binary__get_session', 'mcp__binary__set_session_title']);
  assert.equal(JSON.parse((await call(defs, 'get_session', { session_id: 'self' })).content[0].text).title, 'One');
  assert.equal(JSON.parse((await call(defs, 'get_session', { session_id: 's2' })).content[0].text).title, 'Two');
  assert.equal((await call(defs, 'get_session', { session_id: 'nope' })).isError, true);
  assert.equal((await call(defs, 'set_session_title', { session_id: 'self', title: '  [wip] New  ' })).content[0].text, 'Renamed to: [wip] New');
  assert.equal(titles.get('s1'), '[wip] New');
  assert.equal((await call(defs, 'set_session_title', { session_id: 'self', title: ' ' })).isError, true);
  assert.equal((await call(defs, 'set_session_title', { session_id: 'nope', title: 'x' })).isError, true);
});

test('session tools go to claude, auto-allowed, and rename through the manager', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd, title: 'Before' });
    const s = h.manager.session(sum.id)!;
    const opts = await h.manager.queryOptions(s);
    assert.deepEqual(Object.keys(opts.mcpServers ?? {}), ['binary']);
    assert.deepEqual(opts.allowedTools, SESSION_TOOLS);
    assert.equal(h.manager.sessionInfo(sum.id)?.title, 'Before');
    assert.equal(await h.manager.setTitle(sum.id, 'After'), 'After');
    assert.equal(h.manager.summary(sum.id)?.title, 'After');

    // The effort Claude Code applied, from its hooks; subagents' own levels don't count.
    const stop = opts.hooks?.Stop?.[0]?.hooks[0];
    assert.ok(stop);
    const fire = (input: object) => stop({ hook_event_name: 'Stop', session_id: sum.id, transcript_path: '', cwd: h.cwd, ...input } as never, undefined, { signal: new AbortController().signal });
    await fire({ effort: { level: 'medium' } });
    assert.equal(h.manager.summary(sum.id)?.appliedEffort, 'medium');
    await fire({ effort: { level: 'max' }, agent_id: 'sub1' });
    assert.equal(h.manager.summary(sum.id)?.appliedEffort, 'medium');
    await h.manager.update(sum.id, { effort: 'low' });
    assert.equal(h.manager.summary(sum.id)?.appliedEffort, undefined);
  } finally {
    await h.close();
  }
});

test('sessions start with Claude in Chrome unless the config turns it off', async () => {
  const h = await harness();
  try {
    const sum = await h.manager.create({ cwd: h.cwd });
    const s = h.manager.session(sum.id)!;
    const opts = await h.manager.queryOptions(s);
    assert.deepEqual(opts.extraArgs, { chrome: null });
    // No allow rule: Claude Code lets the extension's site permissions decide.
    assert.deepEqual(opts.allowedTools, SESSION_TOOLS);
    await s.send('hi');
    await waitFor('the turn ends', () => s.state === 'idle' && s.log.entries.some((e) => e.kind === 'result'));
    assert.ok(h.launches()[0].split(' ').includes('--chrome'), h.launches()[0]);

    h.manager.cfg.data.chrome = false;
    assert.equal((await h.manager.queryOptions(s)).extraArgs, undefined);
  } finally {
    await h.close();
  }
});
