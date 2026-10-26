#!/usr/bin/env node
// A stand-in for the Claude Code CLI used by the tests. It speaks the
// stream-json protocol the Agent SDK drives and writes transcripts in the
// layout getSessionMessages() reads, so the server is exercised end to end
// without calling the API.
//
// Prompts containing "permission" trigger a Write approval request.
// `agents --json` prints the file $FAKE_AGENTS_FILE when it exists, else
// $FAKE_AGENTS (default []).

import { appendFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';

const args = process.argv.slice(2);
if (args[0] === 'agents') {
  const file = process.env.FAKE_AGENTS_FILE;
  process.stdout.write(file && existsSync(file) ? readFileSync(file, 'utf8') : (process.env.FAKE_AGENTS ?? '[]'));
  process.exit(0);
}
if (args[0] === '--version') {
  process.stdout.write('9.9.9 (Fake Claude Code)\n');
  process.exit(0);
}

// The SDK passes --flag=value; a terminal user would type --flag value.
const arg = (name) => {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === name) return args[i + 1];
    if (args[i].startsWith(name + '=')) return args[i].slice(name.length + 1);
  }
  return undefined;
};
const sid = arg('--session-id') ?? arg('--resume');
const resumed = arg('--resume') !== undefined;
const cwd = process.cwd();
const configDir = process.env.CLAUDE_CONFIG_DIR;
const dir = join(configDir, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'));
mkdirSync(dir, { recursive: true });
const file = join(dir, `${sid}.jsonl`);
if (!resumed && existsSync(file)) {
  process.stderr.write('Error: session id already in use\n');
  process.exit(1);
}
appendFileSync(join(configDir, 'launches.log'), args.join(' ') + (process.env.FOO ? ` FOO=${process.env.FOO}` : '') + ` CWD=${cwd}` + '\n');

let model = arg('--model') ?? 'fake-model';
let lastUuid = null;
const emit = (o) => process.stdout.write(JSON.stringify(o) + '\n');
const persist = (o) => {
  const entry = { parentUuid: lastUuid, isSidechain: false, userType: 'external', cwd, sessionId: sid, version: '9.9.9', timestamp: new Date().toISOString(), ...o };
  lastUuid = o.uuid;
  appendFileSync(file, JSON.stringify(entry) + '\n');
};
const respond = (id, response = {}) => emit({ type: 'control_response', response: { subtype: 'success', request_id: id, response } });

const waiting = new Map();
let n = 0;
const ask = (request) =>
  new Promise((resolve) => {
    const id = `fake-${++n}`;
    waiting.set(id, resolve);
    emit({ type: 'control_request', request_id: id, request });
  });

const COMMANDS = [
  { name: 'compact', description: 'Summarize the conversation', argumentHint: '<instructions>', builtin: true },
  { name: 'review', description: 'A user command named like an alias', argumentHint: '' },
  { name: 'code-review', description: 'Review the diff', argumentHint: '[<pr#>]', aliases: ['review'], builtin: true },
  { name: 'exit', description: 'Exit the REPL', argumentHint: '', builtin: true },
  { name: '__internal', description: 'Not for people', argumentHint: '' },
  { name: 'my-skill', description: 'A user skill (user)', argumentHint: '' },
  { name: 'compact', description: 'A user command shadowed by the builtin', argumentHint: '' },
];

const turns = [];
let busy = false;
let interrupted = false;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function runTurn(msg) {
  interrupted = false;
  const content = msg.message.content;
  const text = typeof content === 'string' ? content : content.filter((b) => b.type === 'text').map((b) => b.text).join('\n');
  persist({ type: 'user', uuid: msg.uuid ?? randomUUID(), message: { role: 'user', content } });
  emit({ type: 'system', subtype: 'init', session_id: sid, model, permissionMode: 'default', terminal_slash_commands: ['exit'], uuid: randomUUID() });
  if (text.includes('new skill')) {
    emit({ type: 'system', subtype: 'commands_changed', session_id: sid, uuid: randomUUID(), commands: [...COMMANDS, { name: 'found', description: 'Found in a subfolder', argumentHint: '' }] });
  }

  if (text.includes('permission')) {
    const use = { type: 'assistant', uuid: randomUUID(), session_id: sid, parent_tool_use_id: null, message: { id: 'msg_tool', model, role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_1', name: 'Write', input: { file_path: '/tmp/x', content: 'x' } }] } };
    emit(use);
    persist({ type: 'assistant', uuid: use.uuid, message: use.message });
    const reply = await ask({ subtype: 'can_use_tool', tool_name: 'Write', input: { file_path: '/tmp/x', content: 'x' }, tool_use_id: 'toolu_1', permission_suggestions: [{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }] });
    const result = reply.behavior === 'allow' ? 'allowed' : `denied: ${reply.message}`;
    const tr = { type: 'user', uuid: randomUUID(), session_id: sid, parent_tool_use_id: null, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content: result }] } };
    emit(tr);
    persist({ type: 'user', uuid: tr.uuid, message: tr.message });
  }
  if (text.includes('background')) {
    emit({ type: 'system', subtype: 'background_tasks_changed', session_id: sid, uuid: randomUUID(), tasks: [
      { task_id: 'bash_1', task_type: 'local_bash', description: 'npm run dev' },
      { task_id: 'watch_1', task_type: 'monitor', description: 'file watcher', ambient: true },
    ] });
  }
  if (text.includes('slow')) {
    for (let i = 0; i < 50 && !interrupted; i++) await sleep(100);
  }
  if (interrupted) {
    const u = randomUUID();
    persist({ type: 'user', uuid: u, message: { role: 'user', content: [{ type: 'text', text: '[Request interrupted by user]' }] } });
    emit({ type: 'user', uuid: u, session_id: sid, parent_tool_use_id: null, message: { role: 'user', content: [{ type: 'text', text: '[Request interrupted by user]' }] } });
    emit({ type: 'result', subtype: 'error_during_execution', is_error: true, errors: [], uuid: randomUUID(), session_id: sid });
    return;
  }

  const reply = `echo: ${text}`;
  const ev = (event) => emit({ type: 'stream_event', session_id: sid, parent_tool_use_id: null, uuid: randomUUID(), event });
  ev({ type: 'message_start', message: { id: 'msg_1' } });
  ev({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
  for (const part of ['echo: ', text]) {
    ev({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: part } });
    await sleep(120);
  }
  const asst = { type: 'assistant', uuid: randomUUID(), session_id: sid, parent_tool_use_id: null, message: { id: 'msg_1', model, role: 'assistant', content: [{ type: 'text', text: reply }] } };
  emit(asst);
  persist({ type: 'assistant', uuid: asst.uuid, message: asst.message });
  ev({ type: 'content_block_stop', index: 0 });
  ev({ type: 'message_stop' });
  emit({ type: 'result', subtype: 'success', is_error: false, result: reply, total_cost_usd: 0.01, duration_ms: 5, num_turns: 1, uuid: randomUUID(), session_id: sid });
}

async function pump() {
  if (busy) return;
  busy = true;
  while (turns.length) await runTurn(turns.shift());
  busy = false;
}

const rl = createInterface({ input: process.stdin });
rl.on('line', (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  if (msg.type === 'control_request') {
    const req = msg.request ?? {};
    if (req.subtype === 'initialize') {
      respond(msg.request_id, {
        commands: COMMANDS,
        agents: [],
        output_style: 'default',
        available_output_styles: ['default'],
        models: [{ value: 'fake', displayName: 'Fake', description: 'test model' }],
        account: {},
      });
    } else if (req.subtype === 'stop_task') {
      emit({ type: 'system', subtype: 'background_tasks_changed', session_id: sid, uuid: randomUUID(), tasks: [
        { task_id: 'watch_1', task_type: 'monitor', description: 'file watcher', ambient: true },
      ] });
      respond(msg.request_id);
    } else if (req.subtype === 'interrupt') {
      interrupted = true;
      respond(msg.request_id, { still_queued: [] });
    } else {
      if (req.subtype === 'set_model') model = req.model ?? 'fake-model';
      respond(msg.request_id);
    }
  } else if (msg.type === 'control_response') {
    const r = msg.response ?? {};
    const resolve = waiting.get(r.request_id);
    if (resolve) {
      waiting.delete(r.request_id);
      resolve(r.response ?? {});
    }
  } else if (msg.type === 'user') {
    turns.push(msg);
    void pump();
  }
});
rl.on('close', async () => {
  while (busy) await sleep(20);
  process.exit(0);
});
