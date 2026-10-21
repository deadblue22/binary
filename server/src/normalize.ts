// Turns SDK messages — live ones from query() and stored ones from
// getSessionMessages() — into the Entry format clients render. Both share the
// same shapes and uuids, so entries from either source merge by uuid.

import { randomUUID } from 'node:crypto';
import { T, type Msg } from './i18n.js';

const MAX_TEXT = 16 * 1024;
const MAX_INPUT = 32 * 1024;

export interface Block {
  type: 'text' | 'thinking' | 'tool_use' | 'tool_result' | 'image';
  text?: Msg;
  id?: string;
  name?: string;
  input?: unknown;
  toolUseId?: string;
  isError?: boolean;
  truncated?: boolean;
  /** For images: key to fetch the image from /sessions/{id}/images/{key}. */
  image?: string;
}

export interface Entry {
  seq: number;
  uuid: string;
  kind: 'user' | 'assistant' | 'system' | 'result';
  time?: string;
  model?: string;
  messageId?: string;
  blocks?: Block[];
  subtype?: string;
  /** For subtype app_event: the tag the host app wrapped the message in. */
  event?: string;
  text?: Msg;
  isError?: boolean;
  costUsd?: number;
  durationMs?: number;
  numTurns?: number;
}

/** The fields we read from an SDK or session message. */
export interface RawMessage {
  type: string;
  subtype?: string;
  uuid?: string;
  timestamp?: string;
  parent_tool_use_id?: string | null;
  isMeta?: boolean;
  /** Live stream: user-role content the CLI added itself (the live form of isMeta). */
  isSynthetic?: boolean;
  isCompactSummary?: boolean;
  message?: { id?: string; model?: string; role?: string; content?: unknown };
  content?: unknown;
  // result
  is_error?: boolean;
  result?: string;
  errors?: string[];
  total_cost_usd?: number;
  duration_ms?: number;
  num_turns?: number;
}

type RawBlock = {
  type?: string;
  text?: string;
  thinking?: string;
  id?: string;
  name?: string;
  input?: unknown;
  tool_use_id?: string;
  content?: unknown;
  is_error?: boolean;
  source?: { type?: string; media_type?: string; data?: string };
};

type Partialish = Omit<Entry, 'seq' | 'uuid'>;

export function truncate(s: string, max: number): [string, boolean] {
  if (s.length <= max) return [s, false];
  return [s.slice(0, max), true];
}

/** Flattens whitespace and cuts s to n characters. */
export function preview(s: string, n: number): string {
  const flat = s.split(/\s+/).filter(Boolean).join(' ');
  const chars = [...flat];
  return chars.length > n ? chars.slice(0, n).join('') + '…' : flat;
}

export interface EntryOptions {
  /** Keep messages from inside a subagent (when reading its own transcript). */
  subagent?: boolean;
  /** Receives image data found in user messages; the key is stable per message. */
  onImage?: (key: string, mediaType: string, data: string) => void;
}

/** Converts one message; undefined for messages with nothing to show. */
export function toEntry(m: RawMessage, opts: EntryOptions = {}): Entry | undefined {
  if (m.parent_tool_use_id && !opts.subagent) return undefined; // subagent traffic in the main stream
  const uuid = m.uuid || randomUUID();
  let e: Partialish | undefined;
  switch (m.type) {
    case 'user':
      e = userEntry(m, uuid, opts.onImage);
      break;
    case 'assistant':
      e = assistantEntry(m);
      break;
    case 'system':
      e = systemEntry(m);
      break;
    case 'result':
      e = resultEntry(m);
      break;
  }
  if (!e) return undefined;
  const entry: Entry = { seq: 0, uuid, ...e };
  if (m.timestamp) entry.time = m.timestamp;
  return entry;
}

export function toEntries(msgs: RawMessage[], opts: EntryOptions = {}): Entry[] {
  const out: Entry[] = [];
  for (const m of msgs) {
    const e = toEntry(m, opts);
    if (e) out.push(e);
  }
  return out;
}

function userEntry(m: RawMessage, uuid: string, onImage?: EntryOptions['onImage']): Partialish | undefined {
  if (m.isMeta || !m.message) return undefined;
  const content = m.message.content;
  // Notes the CLI adds for the model, e.g. an image's scaling after a Read;
  // tool results and interrupt markers still show.
  if (m.isSynthetic && !hasToolResult(content) && !contentText(content).startsWith('[Request interrupted by user')) return undefined;
  if (m.isCompactSummary) {
    return { kind: 'system', subtype: 'compact_summary', text: truncate(contentText(content), MAX_TEXT)[0] };
  }
  if (typeof content === 'string') return userString(content);
  if (!Array.isArray(content)) return undefined;
  const blocks: Block[] = [];
  const events: Partialish[] = [];
  for (const [i, b] of (content as RawBlock[]).entries()) {
    switch (b.type) {
      case 'text': {
        const raw = stripContext(b.text ?? '');
        const t = raw.trim();
        if (t.startsWith('[Request interrupted by user')) {
          return { kind: 'system', subtype: 'interrupted', text: T('interrupted') };
        }
        if (!t) continue;
        const sys = userString(raw);
        if (sys?.subtype === 'app_event') {
          events.push(sys);
          continue;
        }
        if (sys?.kind === 'system') return sys;
        const [text, truncated] = truncate(raw, MAX_TEXT);
        blocks.push({ type: 'text', text, ...(truncated && { truncated }) });
        break;
      }
      case 'image': {
        const mediaType = b.source?.media_type ?? '';
        let image: string | undefined;
        if (onImage && b.source?.type === 'base64' && b.source.data) {
          image = `${uuid}-${i}`;
          onImage(image, mediaType, b.source.data);
        }
        blocks.push({ type: 'image', text: mediaType, ...(image && { image }) });
        break;
      }
      case 'document':
        blocks.push({ type: 'text', text: T('document') });
        break;
      case 'tool_result': {
        const [text, truncated] = truncate(stripContext(contentText(b.content)).trimEnd(), MAX_TEXT);
        blocks.push({
          type: 'tool_result',
          toolUseId: b.tool_use_id,
          text,
          ...(b.is_error && { isError: true }),
          ...(truncated && { truncated }),
        });
        break;
      }
    }
  }
  // An app event next to text the user wrote is context for that text.
  if (blocks.length) return { kind: 'user', blocks };
  return events[0];
}

function between(s: string, open: string, close: string): string {
  const i = s.indexOf(open);
  if (i < 0) return '';
  const rest = s.slice(i + open.length);
  const j = rest.indexOf(close);
  return j >= 0 ? rest.slice(0, j) : rest;
}

/**
 * Context the desktop app or Claude Code adds to a user message or tool
 * result for the model, not something the user wrote or the tool printed.
 */
const CONTEXT_TAGS = ['system-reminder', 'artifact-view-context'];
const CONTEXT_RE = new RegExp(`<(${CONTEXT_TAGS.join('|')})(?:\\s[^>]*)?>[\\s\\S]*?<\\/\\1>\\s*`, 'g');

function stripContext(s: string): string {
  return CONTEXT_TAGS.some((t) => s.includes(`<${t}`)) ? s.replace(CONTEXT_RE, '') : s;
}

/**
 * Messages a host app (the Claude desktop app) sends as a user turn: notices
 * about other sessions, CI, scheduled runs. Shown as a one-line notice with
 * the message below, like task notifications, instead of a user bubble.
 */
const APP_EVENTS = new Set(['side-sessions-event', 'cross-session-message', 'ci-monitor-event', 'scheduled-task']);

function appEvent(t: string): Partialish | undefined {
  const m = /^<([a-z][\w-]*)((?:\s[^>]*)?)>([\s\S]*)<\/\1>$/.exec(t);
  if (!m || !APP_EVENTS.has(m[1])) return undefined;
  const tag = m[1];
  const attrs: Record<string, string> = {};
  for (const a of m[2].matchAll(/([\w-]+)="([^"]*)"/g)) attrs[a[1]] = a[2];
  const body = m[3].trim();
  let summary: Msg;
  switch (tag) {
    case 'side-sessions-event':
      summary = T('evSideSessions');
      break;
    case 'cross-session-message':
      summary = attrs.name ? T('evCrossSession', { name: attrs.name }) : T('evCrossSessionAnon');
      break;
    case 'ci-monitor-event': {
      const pr = /([\w.-]+\/[\w.-]+) PR #(\d+)/.exec(body);
      summary = pr ? T('evCIPr', { pr: `${pr[1]}#${pr[2]}` }) : T('evCI');
      break;
    }
    default:
      summary = attrs.name ? T('evScheduled', { name: attrs.name }) : T('evScheduledAnon');
  }
  return {
    kind: 'system',
    subtype: 'app_event',
    event: tag,
    text: body ? T('withBody', { summary, body: truncate(body, MAX_TEXT)[0] }) : summary,
  };
}

function userString(raw: string): Partialish | undefined {
  const s = stripContext(raw);
  const t = s.trim();
  if (!t || t.startsWith('<local-command-caveat>')) return undefined;
  if (t.startsWith('<local-command-stdout>') || t.startsWith('<local-command-stderr>')) {
    const isError = t.startsWith('<local-command-stderr>');
    const tag = isError ? 'local-command-stderr' : 'local-command-stdout';
    const out = between(t, `<${tag}>`, `</${tag}>`).trim();
    if (!out) return undefined;
    return { kind: 'system', subtype: 'local_command', text: truncate(out, MAX_TEXT)[0], ...(isError && { isError }) };
  }
  if (t.startsWith('[Request interrupted by user')) {
    return { kind: 'system', subtype: 'interrupted', text: T('interrupted') };
  }
  if (t.startsWith('<task-notification>')) {
    // Claude Code tells the model a background task or agent finished; show
    // its one-line summary, with the result (if any) below it.
    const status = between(t, '<status>', '</status>').trim();
    const summary = between(t, '<summary>', '</summary>').trim() || status;
    const result = between(t, '<result>', '</result>').trim();
    return {
      kind: 'system',
      subtype: 'task_notification',
      text: truncate(result ? `${summary}\n\n${result}` : summary, MAX_TEXT)[0],
      ...(status === 'failed' && { isError: true }),
    };
  }
  const ev = appEvent(t);
  if (ev) return ev;
  if (t.includes('<command-name>')) {
    let name = between(t, '<command-name>', '</command-name>').trim();
    const args = between(t, '<command-args>', '</command-args>').trim();
    if (!name.startsWith('/')) name = '/' + name;
    return { kind: 'user', blocks: [{ type: 'text', text: `${name} ${args}`.trim() }] };
  }
  const [text, truncated] = truncate(s, MAX_TEXT);
  return { kind: 'user', blocks: [{ type: 'text', text, ...(truncated && { truncated }) }] };
}

function assistantEntry(m: RawMessage): Partialish | undefined {
  const content = m.message?.content;
  if (!Array.isArray(content)) return undefined;
  const blocks: Block[] = [];
  for (const b of content as RawBlock[]) {
    const type = b.type ?? '';
    if (type === 'text') {
      if (!b.text?.trim()) continue;
      const [text, truncated] = truncate(b.text, MAX_TEXT * 4);
      blocks.push({ type: 'text', text, ...(truncated && { truncated }) });
    } else if (type === 'thinking') {
      if (!b.thinking?.trim()) continue;
      const [text, truncated] = truncate(b.thinking, MAX_TEXT * 4);
      blocks.push({ type: 'thinking', text, ...(truncated && { truncated }) });
    } else if (type === 'tool_use' || type === 'server_tool_use' || type === 'mcp_tool_use') {
      blocks.push({ type: 'tool_use', id: b.id, name: b.name, input: shrinkInput(b.input) });
    } else if (type.endsWith('_tool_result')) {
      const [text, truncated] = truncate(contentText(b.content), MAX_TEXT);
      blocks.push({ type: 'tool_result', toolUseId: b.tool_use_id, text, ...(truncated && { truncated }) });
    }
  }
  if (!blocks.length) return undefined;
  // Claude Code's placeholder after an interrupted turn, not a real reply.
  if (m.message?.model === '<synthetic>' && blocks.length === 1 && blocks[0].text === 'No response requested.') return undefined;
  const e: Partialish = { kind: 'assistant', blocks };
  if (m.message?.model) e.model = m.message.model;
  if (m.message?.id) e.messageId = m.message.id;
  return e;
}

function systemEntry(m: RawMessage): Partialish | undefined {
  const text = contentText(m.content);
  switch (m.subtype) {
    case 'compact_boundary':
      return { kind: 'system', subtype: 'compact_boundary', text: T('compacted') };
    case 'informational':
    case 'scheduled_task_fire':
      return text ? { kind: 'system', subtype: m.subtype, text: truncate(text, MAX_TEXT)[0] } : undefined;
    case 'local_command':
    case 'local_command_output': {
      const sys = userString(text);
      if (sys?.kind === 'system') return sys;
      return text.trim() ? { kind: 'system', subtype: 'local_command', text: truncate(text, MAX_TEXT)[0] } : undefined;
    }
  }
  return undefined;
}

function resultEntry(m: RawMessage): Partialish {
  const e: Partialish = { kind: 'result', subtype: m.subtype };
  if (m.is_error) e.isError = true;
  if (m.total_cost_usd) e.costUsd = m.total_cost_usd;
  if (m.duration_ms) e.durationMs = m.duration_ms;
  if (m.num_turns) e.numTurns = m.num_turns;
  // An interrupted turn ends with error_during_execution; the "interrupted"
  // entry already says so and the result text is internal diagnostics.
  if (m.is_error && m.subtype !== 'error_during_execution') {
    e.text = truncate(m.result || (m.errors ?? []).join('; '), MAX_TEXT)[0];
  }
  return e;
}

/** First non-empty text block of a message, for previews. */
export function firstText(m: RawMessage): string {
  const c = m.message?.content;
  if (typeof c === 'string') return c;
  if (!Array.isArray(c)) return '';
  for (const b of c as RawBlock[]) {
    if (b.type === 'text' && b.text?.trim()) return b.text;
  }
  return '';
}

/** Flattens a string-or-blocks content value into text. */
function contentText(raw: unknown): string {
  if (raw == null) return '';
  if (typeof raw === 'string') return raw;
  if (Array.isArray(raw)) {
    const parts: string[] = [];
    for (const b of raw as RawBlock[]) {
      if (b.type === 'text') parts.push(b.text ?? '');
      else if (b.type === 'image') parts.push('[image]');
      else if (b.text) parts.push(b.text);
    }
    return parts.join('\n');
  }
  return JSON.stringify(raw);
}

/** Keeps tool inputs small: oversized string fields are truncated. */
export function shrinkInput(input: unknown): unknown {
  if (input == null) return {};
  const json = JSON.stringify(input);
  if (json.length <= MAX_INPUT || typeof input !== 'object' || Array.isArray(input)) {
    return json.length <= MAX_INPUT * 2 ? input : {};
  }
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input as Record<string, unknown>)) {
    out[k] = typeof v === 'string' && v.length > 4096 ? T('truncatedValue', { head: v.slice(0, 4096), n: v.length }) : v;
  }
  return JSON.stringify(out).length <= MAX_INPUT * 2 ? out : {};
}

/** One-line description of a tool call, used as the session's activity. */
export function toolLabel(name: string, input: unknown): string {
  const inp = (input ?? {}) as Record<string, unknown>;
  const str = (k: string) => (typeof inp[k] === 'string' ? (inp[k] as string) : '');
  let detail = '';
  switch (name) {
    case 'Bash':
      detail = str('description') || str('command');
      break;
    case 'Read':
    case 'Write':
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit':
      detail = shortPath(str('file_path') || str('notebook_path'));
      break;
    case 'Grep':
    case 'Glob':
      detail = str('pattern');
      break;
    case 'WebFetch':
      detail = str('url');
      break;
    case 'WebSearch':
      detail = str('query');
      break;
    case 'Task':
    case 'Agent':
      detail = str('description');
      break;
    case 'Skill':
      detail = str('skill');
      break;
  }
  return detail ? `${name} · ${preview(detail, 60)}` : name;
}

/** Keeps the last two components of a path ("pkg/file.go"). */
export function shortPath(p: string): string {
  const parts = p.replace(/\/+$/, '').split('/');
  return parts.length <= 2 ? p : parts.slice(-2).join('/');
}

function hasToolResult(content: unknown): boolean {
  return Array.isArray(content) && content.some((b) => (b as { type?: string })?.type === 'tool_result');
}
