import assert from 'node:assert/strict';
import { test } from 'node:test';
import { encode, type Msg } from '../src/i18n.js';
import { shrinkInput, toEntry, toolLabel, truncate, type RawMessage } from '../src/normalize.js';

const render = (m: Msg | undefined): string => (typeof m === 'string' ? m : (m?.render('en') ?? ''));

const cases: { name: string; msg: RawMessage; kind?: string; check?: (e: NonNullable<ReturnType<typeof toEntry>>) => void }[] = [
  { name: 'user string', msg: { type: 'user', uuid: 'u1', message: { role: 'user', content: 'hi there' } }, kind: 'user', check: (e) => assert.equal(e.blocks?.[0].text, 'hi there') },
  { name: 'meta user skipped', msg: { type: 'user', uuid: 'u2', isMeta: true, message: { role: 'user', content: 'caveat' } } },
  { name: 'subagent traffic skipped', msg: { type: 'assistant', uuid: 'a0', parent_tool_use_id: 'toolu_9', message: { content: [{ type: 'text', text: 'x' }] } } },
  {
    name: 'local command output',
    msg: { type: 'user', uuid: 'u3', message: { role: 'user', content: '<local-command-stdout>Set model to sonnet</local-command-stdout>' } },
    kind: 'system',
    check: (e) => {
      assert.equal(e.subtype, 'local_command');
      assert.equal(e.text, 'Set model to sonnet');
    },
  },
  {
    name: 'slash command',
    msg: { type: 'user', uuid: 'u4', message: { role: 'user', content: '<command-name>/model</command-name>\n<command-args>sonnet</command-args>' } },
    kind: 'user',
    check: (e) => assert.equal(e.blocks?.[0].text, '/model sonnet'),
  },
  {
    name: 'interrupted',
    msg: { type: 'user', uuid: 'u5', message: { role: 'user', content: [{ type: 'text', text: '[Request interrupted by user]' }] } },
    kind: 'system',
    check: (e) => assert.equal(e.subtype, 'interrupted'),
  },
  {
    name: 'tool result',
    msg: { type: 'user', uuid: 'u6', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content: [{ type: 'text', text: 'ok' }], is_error: true }] } },
    kind: 'user',
    check: (e) => assert.deepEqual(e.blocks?.[0], { type: 'tool_result', toolUseId: 'toolu_1', text: 'ok', isError: true }),
  },
  {
    name: 'assistant blocks',
    msg: {
      type: 'assistant',
      uuid: 'a1',
      timestamp: '2026-10-20T04:00:00.000Z',
      message: {
        id: 'msg_1',
        model: 'claude-x',
        content: [
          { type: 'thinking', thinking: 'hmm' },
          { type: 'thinking', thinking: '' },
          { type: 'text', text: 'answer' },
          { type: 'tool_use', id: 'toolu_2', name: 'Bash', input: { command: 'ls' } },
        ],
      },
    },
    kind: 'assistant',
    check: (e) => {
      assert.deepEqual(e.blocks?.map((b) => b.type), ['thinking', 'text', 'tool_use']);
      assert.equal(e.model, 'claude-x');
      assert.equal(e.time, '2026-10-20T04:00:00.000Z');
    },
  },
  {
    name: 'task notification',
    msg: {
      type: 'user',
      uuid: 'u7',
      message: {
        role: 'user',
        content:
          '<task-notification>\n<task-id>a1</task-id>\n<status>failed</status>\n<summary>Agent "Survey" failed</summary>\n<result>trace</result>\n</task-notification>',
      },
    },
    kind: 'system',
    check: (e) => {
      assert.equal(e.subtype, 'task_notification');
      assert.equal(e.text, 'Agent "Survey" failed\n\ntrace');
      assert.equal(e.isError, true);
    },
  },
  {
    name: 'system reminders are not shown',
    msg: {
      type: 'user',
      uuid: 'u8',
      message: {
        role: 'user',
        content: [
          { type: 'text', text: '<system-reminder>\nThe user started your suggested task.\n</system-reminder>' },
          { type: 'text', text: 'ship it' },
        ],
      },
    },
    kind: 'user',
    check: (e) => assert.deepEqual(e.blocks, [{ type: 'text', text: 'ship it' }]),
  },
  {
    name: 'system reminder prefix stripped from a string',
    msg: { type: 'user', uuid: 'u9', message: { role: 'user', content: '<system-reminder>ctx</system-reminder>\n\nhello' } },
    kind: 'user',
    check: (e) => assert.equal(e.blocks?.[0].text, 'hello'),
  },
  {
    name: 'system reminder stripped from a tool result',
    msg: {
      type: 'user',
      uuid: 'u11',
      message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_3', content: 'done\n\n<system-reminder>Prefer batching.</system-reminder>' }] },
    },
    kind: 'user',
    check: (e) => assert.equal(e.blocks?.[0].text, 'done'),
  },
  {
    name: 'desktop session event',
    msg: { type: 'user', uuid: 'e1', message: { role: 'user', content: '<side-sessions-event>None of the sessions is working now.</side-sessions-event>' } },
    kind: 'system',
    check: (e) => {
      assert.equal(e.subtype, 'app_event');
      assert.equal(e.event, 'side-sessions-event');
      assert.equal(render(e.text), 'Update from linked sessions\n\nNone of the sessions is working now.');
    },
  },
  {
    name: 'cross-session message keeps the sender',
    msg: {
      type: 'user',
      uuid: 'e2',
      message: { role: 'user', content: '<cross-session-message from="local_1" name="Client UI">\nDone, rebuilt.\n</cross-session-message>' },
    },
    kind: 'system',
    check: (e) => assert.equal(render(e.text), 'Message from Client UI\n\nDone, rebuilt.'),
  },
  {
    name: 'CI event names the pull request',
    msg: {
      type: 'user',
      uuid: 'e3',
      message: { role: 'user', content: [{ type: 'text', text: '<ci-monitor-event>The app is watching acme/app PR #12: checks failed.</ci-monitor-event>' }] },
    },
    kind: 'system',
    check: (e) => assert.ok(render(e.text).startsWith('CI update · acme/app#12\n\n'), render(e.text)),
  },
  {
    name: 'event next to user text is context',
    msg: {
      type: 'user',
      uuid: 'e4',
      message: {
        role: 'user',
        content: [
          { type: 'text', text: '<scheduled-task name="weekly">Run the sync.</scheduled-task>' },
          { type: 'text', text: 'also check the logs' },
        ],
      },
    },
    kind: 'user',
    check: (e) => assert.deepEqual(e.blocks, [{ type: 'text', text: 'also check the logs' }]),
  },
  {
    name: 'artifact view context stripped',
    msg: { type: 'user', uuid: 'e5', message: { role: 'user', content: '<artifact-view-context artifact="a1">{"mode":"edit"}</artifact-view-context>\nfix the heading' } },
    kind: 'user',
    check: (e) => assert.equal(e.blocks?.[0].text, 'fix the heading'),
  },
  {
    name: 'other tags stay user text',
    msg: { type: 'user', uuid: 'e6', message: { role: 'user', content: '<my-widget>hello</my-widget>' } },
    kind: 'user',
    check: (e) => assert.equal(e.blocks?.[0].text, '<my-widget>hello</my-widget>'),
  },
  { name: 'reminder-only message skipped', msg: { type: 'user', uuid: 'u10', message: { role: 'user', content: '<system-reminder>ctx</system-reminder>' } } },
  { name: 'compact boundary', msg: { type: 'system', subtype: 'compact_boundary', uuid: 's1' }, kind: 'system' },
  { name: 'other system skipped', msg: { type: 'system', subtype: 'hook_started', uuid: 's2' } },
  {
    name: 'interrupted result hides diagnostics',
    msg: { type: 'result', subtype: 'error_during_execution', is_error: true, result: '[ede_diagnostic] x', uuid: 'r1' },
    kind: 'result',
    check: (e) => assert.equal(e.text, undefined),
  },
  {
    name: 'error result shows its message',
    msg: { type: 'result', subtype: 'error_max_turns', is_error: true, errors: ['too many turns'], uuid: 'r2' },
    kind: 'result',
    check: (e) => assert.equal(e.text, 'too many turns'),
  },
];

for (const c of cases) {
  test(`toEntry: ${c.name}`, () => {
    const e = toEntry(c.msg);
    if (!c.kind) {
      assert.equal(e, undefined);
      return;
    }
    assert.ok(e, 'expected an entry');
    assert.equal(e.kind, c.kind);
    assert.equal(e.uuid, c.msg.uuid);
    c.check?.(e);
  });
}

test('subagent transcripts keep their messages', () => {
  const msg: RawMessage = { type: 'assistant', uuid: 'a', parent_tool_use_id: 'toolu_1', message: { content: [{ type: 'text', text: 'inner' }] } };
  assert.equal(toEntry(msg, { subagent: true })?.blocks?.[0].text, 'inner');
});

test('truncate and shrinkInput', () => {
  assert.deepEqual(truncate('abcdef', 3), ['abc', true]);
  assert.deepEqual(truncate('ab', 3), ['ab', false]);
  const big = { file_path: '/a', content: 'x'.repeat(100_000) };
  const out = shrinkInput(big) as { file_path: string; content: unknown };
  assert.equal(out.file_path, '/a');
  const en = JSON.parse(encode(out, 'en')) as { content: string };
  assert.ok(en.content.length < 5000 && en.content.endsWith('(truncated, 100000 characters in total)'), en.content.slice(-60));
});

test('toolLabel', () => {
  assert.equal(toolLabel('Bash', { command: 'npm test', description: 'Run tests' }), 'Bash · Run tests');
  assert.equal(toolLabel('Edit', { file_path: '/repo/src/a/b.ts' }), 'Edit · a/b.ts');
  assert.equal(toolLabel('Mystery', {}), 'Mystery');
});

test('synthetic notes from the live stream are hidden, tool results are not', () => {
  const note: RawMessage = { type: 'user', isSynthetic: true, message: { role: 'user', content: '[Image: original 2600x1600, displayed at 2000x1231. Multiply coordinates by 1.30 to map to original image.]' } };
  assert.equal(toEntry(note), undefined);
  const result: RawMessage = { type: 'user', isSynthetic: true, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'ok' }] } };
  assert.ok(toEntry(result));
  const interrupted: RawMessage = { type: 'user', isSynthetic: true, message: { role: 'user', content: '[Request interrupted by user]' } };
  assert.equal(toEntry(interrupted)?.kind, 'system');
});
