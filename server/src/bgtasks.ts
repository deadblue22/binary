// Background tasks of a claude process Binary doesn't run, read from its
// transcript. Our own processes report theirs through the SDK
// (background_tasks_changed); a session open in a terminal, tmux or the
// desktop app only leaves this trail: the tool call that started a task, and
// the <task-notification> (or TaskStop) that ended it.

import type { BackgroundTask } from './session.js';

type Block = { type?: string; id?: string; name?: string; input?: Record<string, unknown>; tool_use_id?: string; is_error?: boolean; text?: string; content?: unknown };
type Line = {
  type?: string;
  timestamp?: string;
  content?: unknown;
  message?: { content?: unknown };
  toolUseResult?: unknown;
};

const str = (v: unknown) => (typeof v === 'string' ? v : '');

function textOf(content: unknown): string {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return (content as Block[]).map((b) => (b.type === 'text' ? str(b.text) : '')).join('\n');
}

/** Task ids a piece of user text reports as over. */
function endedIn(text: string): string[] {
  const out: string[] = [];
  for (const m of text.matchAll(/<task-notification>([\s\S]*?)<\/task-notification>/g)) {
    const body = m[1]!;
    const id = /<task-id>([^<]+)<\/task-id>/.exec(body)?.[1]?.trim();
    if (!id) continue;
    // Monitor events carry no status while the monitor keeps running.
    if (/<status>\s*\w+\s*<\/status>/.test(body) || body.includes('[Monitor expired')) out.push(id);
  }
  return out;
}

/** The task a tool call started, from its result. */
function startedBy(use: Block, result: Record<string, unknown>, at: number): BackgroundTask | undefined {
  const input = use.input ?? {};
  const description = str(input.description).trim();
  const startedAt = new Date(at).toISOString();
  if (typeof result.backgroundTaskId === 'string') {
    return { id: result.backgroundTaskId, type: 'shell', description: description || str(input.command).trim(), startedAt };
  }
  if (use.name === 'Monitor' && typeof result.taskId === 'string') {
    const t: BackgroundTask = { id: result.taskId, type: 'monitor', description, startedAt };
    if (result.persistent !== true && typeof result.timeoutMs === 'number') t.endsAt = new Date(at + result.timeoutMs).toISOString();
    return t;
  }
  if (result.status === 'async_launched' && typeof result.agentId === 'string') {
    const t: BackgroundTask = { id: result.agentId, type: 'subagent', description, startedAt };
    if (typeof input.subagent_type === 'string') t.agentType = input.subagent_type;
    return t;
  }
  return undefined;
}

/**
 * Background tasks still running according to a transcript (JSONL text).
 * Only tasks started at or after `since` count: those from before belonged
 * to an earlier process, which took them along when it exited.
 */
export function runningTasks(transcript: string, since: number, now = Date.now()): BackgroundTask[] {
  const uses = new Map<string, Block>();
  const running = new Map<string, BackgroundTask>();
  for (const raw of transcript.split('\n')) {
    if (!raw.trim()) continue;
    let line: Line;
    try {
      line = JSON.parse(raw) as Line;
    } catch {
      continue; // a line still being written
    }
    const at = Date.parse(str(line.timestamp));
    if (line.type === 'queue-operation') {
      for (const id of endedIn(str(line.content))) running.delete(id);
      continue;
    }
    const content = line.message?.content;
    if (line.type === 'assistant' && Array.isArray(content)) {
      for (const b of content as Block[]) {
        if (b.type !== 'tool_use' || !b.id) continue;
        uses.set(b.id, b);
        const stop = b.name === 'TaskStop' || b.name === 'KillShell' ? str(b.input?.task_id) || str(b.input?.shell_id) : '';
        if (stop) running.delete(stop);
      }
      continue;
    }
    if (line.type !== 'user') continue;
    for (const id of endedIn(textOf(content))) running.delete(id);
    if (!Array.isArray(content)) continue;
    const results = (content as Block[]).filter((b) => b.type === 'tool_result');
    // toolUseResult describes the line's only tool result.
    const r = line.toolUseResult;
    if (results.length !== 1 || !r || typeof r !== 'object' || results[0]!.is_error || !(at >= since)) continue;
    const use = uses.get(str(results[0]!.tool_use_id));
    const t = use && startedBy(use, r as Record<string, unknown>, at);
    if (t) running.set(t.id, t);
  }
  const at = new Date(now).toISOString();
  return [...running.values()].filter((t) => !t.endsAt || t.endsAt > at);
}
