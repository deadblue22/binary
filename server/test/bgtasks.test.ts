import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runningTasks } from '../src/bgtasks.js';

const T0 = Date.parse('2026-10-23T07:00:00Z');
const at = (min: number) => new Date(T0 + min * 60_000).toISOString();

const call = (min: number, id: string, name: string, input: object) => ({
  type: 'assistant',
  timestamp: at(min),
  message: { role: 'assistant', content: [{ type: 'tool_use', id, name, input }] },
});
const result = (min: number, id: string, toolUseResult: object, isError = false) => ({
  type: 'user',
  timestamp: at(min),
  message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: 'ok', ...(isError && { is_error: true }) }] },
  toolUseResult,
});
const notice = (min: number, taskId: string, rest: string) => ({
  type: 'user',
  timestamp: at(min),
  message: { role: 'user', content: `<task-notification>\n<task-id>${taskId}</task-id>\n${rest}\n</task-notification>` },
});
const jsonl = (lines: object[]) => lines.map((l) => JSON.stringify(l)).join('\n') + '\n';
const ids = (text: string, since = T0, now = T0 + 10 * 60_000) => runningTasks(text, since, now).map((t) => t.id);

const started = [
  call(1, 't1', 'Bash', { command: 'npm run dev', description: 'Dev server', run_in_background: true }),
  result(1, 't1', { stdout: '', backgroundTaskId: 'bsh1' }),
  call(2, 't2', 'Monitor', { description: 'PR 12 CI', command: 'gh pr checks 12 --watch' }),
  result(2, 't2', { taskId: 'bmon1', timeoutMs: 30 * 60_000, persistent: false }),
  call(3, 't3', 'Agent', { description: 'Review PR 12', subagent_type: 'pr-reviewer', prompt: '…', run_in_background: true }),
  result(3, 't3', { isAsync: true, status: 'async_launched', agentId: 'a1' }),
];

test('background tasks a transcript started are listed with what they are', () => {
  assert.deepEqual(runningTasks(jsonl(started), T0, T0 + 10 * 60_000), [
    { id: 'bsh1', type: 'shell', description: 'Dev server', startedAt: at(1) },
    { id: 'bmon1', type: 'monitor', description: 'PR 12 CI', startedAt: at(2), endsAt: at(32) },
    { id: 'a1', type: 'subagent', description: 'Review PR 12', agentType: 'pr-reviewer', startedAt: at(3) },
  ]);
});

test('notifications with a status, monitor expiry and TaskStop end tasks; monitor events do not', () => {
  const text = jsonl([
    ...started,
    notice(4, 'bmon1', '<summary>Monitor event: "PR 12 CI"</summary>\n<event>build: fail</event>'),
    notice(5, 'a1', '<status>completed</status>\n<summary>Agent "Review PR 12" completed</summary>'),
  ]);
  assert.deepEqual(ids(text), ['bsh1', 'bmon1']);
  const later = text + jsonl([
    { type: 'queue-operation', operation: 'enqueue', timestamp: at(6), content: '<task-notification>\n<task-id>bmon1</task-id>\n<event>[Monitor expired after 5m with 1 event delivered. Re-arm it if you still need the watch.]</event>\n</task-notification>' },
    call(7, 't4', 'TaskStop', { task_id: 'bsh1' }),
  ]);
  assert.deepEqual(ids(later), []);
});

test('tasks of an earlier process, failed calls and timed-out monitors are not running', () => {
  assert.deepEqual(ids(jsonl(started), T0 + 2.5 * 60_000), ['a1'], 'started before this process');
  assert.deepEqual(ids(jsonl(started), T0, T0 + 40 * 60_000), ['bsh1', 'a1'], 'the monitor timed out');
  const failed = jsonl([call(1, 't1', 'Bash', { command: 'x' }), result(1, 't1', { backgroundTaskId: 'b' }, true)]);
  assert.deepEqual(ids(failed), []);
  assert.deepEqual(ids(jsonl(started) + '{"type":"user","mess'), ['bsh1', 'bmon1', 'a1'], 'a half-written line is skipped');
});
