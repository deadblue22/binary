// Session registry: lists stored sessions through the Agent SDK, tracks which
// ones are running elsewhere through `claude agents --json`, owns the runtime
// Session objects and fans out list changes.

import { randomUUID } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, isAbsolute, join, resolve } from 'node:path';
import {
  forkSession,
  query,
  type SDKUserMessage,
  getSessionMessages,
  getSessionInfo,
  getSubagentMessages,
  listSubagents,
  renameSession,
  tagSession,
  type EffortLevel,
  type HookCallback,
  type Options,
  type PermissionMode,
  type SDKSessionInfo,
} from '@anthropic-ai/claude-agent-sdk';
import { lastMessageAt } from './activity.js';
import { runningTasks } from './bgtasks.js';
import { resumeNote, saveInterrupted, takeInterrupted, type Interrupted } from './restart.js';
import { activeAgents, type ActiveAgent } from './claude.js';
import type { Config } from './config.js';
import { DesktopLinks } from './desktop.js';
import { holderOf, processTable, type Holder } from './holders.js';
import { createWorktree, switchBranch, worktreeName } from './git.js';
import { SessionLister } from './lister.js';
import { SessionSearch, type SearchResult } from './search.js';
import { SESSION_TOOL_SERVER, SESSION_TOOLS, sessionTools, type SessionToolHost } from './tools.js';
import { DEFAULT_LANG, encode, LocalizedError, T, type Lang, type Msg, type Text } from './i18n.js';
import { event, Subscriber, type Event, type Sink } from './log.js';
import { preview, toEntries, type Entry, type RawMessage } from './normalize.js';
import { isUnder, mainCheckout, tempRoots } from './recent.js';
import { checkImages, readPlanUsage, Session, type ImageInput, type BackgroundTask, type PlanUsage, type SessionHost, type SettingsUpdate } from './session.js';
import { LAYOUT_FIELDS, type Layout, type LayoutStamps, type Store } from './store.js';

export const EFFORT_LEVELS = ['low', 'medium', 'high', 'xhigh', 'max'];
export const PERMISSION_MODES = ['default', 'acceptEdits', 'plan', 'auto', 'dontAsk', 'bypassPermissions'];

/** Shown until a Claude Code process reports the real list. */
const FALLBACK_MODELS = [
  { value: 'default', displayName: 'Default', description: T('defaultModel') },
  { value: 'opus', displayName: 'Opus', description: '' },
  { value: 'sonnet', displayName: 'Sonnet', description: '' },
  { value: 'haiku', displayName: 'Haiku', description: '' },
];

/** PUT /layout: any of the fields, each with the time it was changed. */
export interface LayoutUpdate {
  pinned?: string[];
  archived?: string[];
  groupOrder?: string[];
  at?: Partial<LayoutStamps>;
}

export interface CreateRequest {
  cwd: string;
  prompt?: string;
  model?: string;
  effort?: string;
  permissionMode?: string;
  title?: string;
  tag?: string;
  parentId?: string;
  /** Branch to work on: the base of a new worktree, or checked out in place. */
  branch?: string;
  /** Start in a new git worktree (true: name it after the title or prompt). */
  worktree?: boolean | string;
  /** Extra environment variables for this session's claude process. */
  env?: Record<string, string>;
  /** Images to send with the first message (base64). */
  images?: unknown;
}

export interface Summary {
  id: string;
  title: Msg;
  cwd: string;
  project: string;
  gitBranch?: string;
  createdAt: string;
  updatedAt: string;
  state: string;
  live: boolean;
  activity?: Msg;
  lastSummary?: string;
  preview?: string;
  model?: string;
  effort?: string;
  /** The effort Claude Code actually applied last turn (what "default" resolves to). */
  appliedEffort?: string;
  /** How full the context window was after the latest turn Binary ran. */
  context?: { percent: number; tokens: number; max: number; at: string };
  /** Background work of the live process. */
  tasks?: BackgroundTask[];
  /** When an idle live process will be closed (idle timeout), if nothing happens before. */
  closesAt?: string;
  permissionMode: string;
  lastModel?: string;
  pending: number;
  costUsd?: number;
  messages: number;
  managed: boolean;
  error?: Msg;
  tag?: string;
  parentId?: string;
  subagentCount?: number;
  /** Worktree Binary created for this session. */
  worktree?: string;
  /** SSH host the desktop app runs this session on; it can only be viewed here. */
  sshHost?: string;
  /**
   * Held by a claude process outside binaryd, and which program holds it.
   * busy: a turn is in progress there (messages sent now wait for it);
   * background: its turn has ended and only background tasks keep it busy.
   */
  external?: { busy: boolean; background?: boolean; holder: Holder };
  /** Messages waiting for that turn to end, oldest first. */
  queued?: { id: string; text: string; images: number; at: string }[];
  /** Whether the working directory exists on this machine (absent: cwd unknown). */
  cwdExists?: boolean;
}

export interface SubagentInfo {
  id: string;
  title: string;
  prompt?: string;
  entries: number;
  startedAt?: string;
  /** Time of its latest entry. */
  updatedAt?: string;
  /** Still working: its session has a claude process and it hasn't finished. */
  running?: boolean;
}

/** An error with an HTTP status and a localizable message. */
export class HttpError extends LocalizedError {
  constructor(
    readonly status: number,
    text: ReturnType<typeof T>,
  ) {
    super(text);
  }
}

export interface ManagerOptions {
  /** Executable for `claude agents --json` and --version. */
  claudeBin: string;
  claudeVersion: string;
  /** Passed to the SDK when the user configured their own claude. */
  claudePath?: string;
  env: Record<string, string>;
  /** Claude desktop app session records, for parent links (undefined: off). */
  desktopDir?: string;
  /** Folders whose contents are scratch, left out of recent folders (default: the OS temp locations). */
  tempDirs?: string[];
  log?: (msg: string) => void;
}

const EPOCH = new Date(0).toISOString();

/** How long a finished-looking turn must stay unwritten before it counts as ended. */
const TURN_SETTLE_MS = 30_000;

const HOLDER_TEXT = {
  desktop: 'holderDesktop',
  tmux: 'holderTmux',
  terminal: 'holderTerminal',
  ide: 'holderIde',
  other: 'holderOther',
} as const satisfies Record<Holder, string>;

/** Environment variables a client may set for a session. */
function checkEnv(env: unknown): Record<string, string> | undefined {
  if (env == null) return undefined;
  if (typeof env !== 'object' || Array.isArray(env)) throw new HttpError(400, T('envInvalid', { name: '' }));
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(env as Record<string, unknown>)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) || typeof v !== 'string') throw new HttpError(400, T('envInvalid', { name: k }));
    out[k] = v;
  }
  return Object.keys(out).length ? out : undefined;
}

export function expandPath(p: string): string {
  const t = (p ?? '').trim();
  if (!t) throw new HttpError(400, T('pathEmpty'));
  const expanded = t === '~' || t.startsWith('~/') ? join(homedir(), t.slice(1)) : t;
  if (!isAbsolute(expanded)) throw new HttpError(400, T('pathNotAbsolute', { path: t }));
  return resolve(expanded);
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/** Where Claude Code stores a session's transcript (documented layout). */
function transcriptPath(id: string, cwd: string): string {
  const base = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
  return join(base, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'), `${id}.jsonl`);
}

/** A session's transcript, also when its folder is named after another directory. */
function findTranscript(id: string, cwd: string): string {
  const path = cwd ? transcriptPath(id, cwd) : '';
  if (path && existsSync(path)) return path;
  const projects = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects');
  try {
    for (const p of readdirSync(projects)) {
      const f = join(projects, p, `${id}.jsonl`);
      if (existsSync(f)) return f;
    }
  } catch {
    // no projects folder
  }
  return '';
}

/** What Claude Code notes about a subagent in its `agent-<id>.meta.json`. */
interface SubagentMeta {
  /** The name it was launched with (the Agent tool's `description`). */
  description?: string;
  /** Set when it completes (newer Claude Code). */
  finished?: boolean;
  stoppedByUser?: boolean;
}

/**
 * The meta files Claude Code writes beside subagent transcripts, by agent id.
 * The session's folder is found by id: it is named after the directory the
 * session started in, which may not be its cwd now.
 */
function subagentMetas(id: string, cwd: string): Map<string, SubagentMeta> {
  const projects = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects');
  let dir = join(transcriptPath(id, cwd).slice(0, -'.jsonl'.length), 'subagents');
  if (!cwd || !existsSync(dir)) {
    let found = '';
    try {
      for (const p of readdirSync(projects)) {
        const d = join(projects, p, id, 'subagents');
        if (existsSync(d)) {
          found = d;
          break;
        }
      }
    } catch {
      // no projects folder
    }
    dir = found;
  }
  const out = new Map<string, SubagentMeta>();
  if (!dir) return out;
  let files: string[] = [];
  try {
    files = readdirSync(dir);
  } catch {
    return out;
  }
  for (const f of files) {
    const m = /^agent-(.+)\.meta\.json$/.exec(f);
    if (!m) continue;
    try {
      const raw = JSON.parse(readFileSync(join(dir, f), 'utf8')) as Record<string, unknown>;
      const meta: SubagentMeta = {};
      if (typeof raw.description === 'string' && raw.description.trim()) meta.description = raw.description.trim();
      if (raw.finished === true) meta.finished = true;
      if (raw.stoppedByUser === true) meta.stoppedByUser = true;
      out.set(m[1]!, meta);
    } catch {
      // unreadable or half-written
    }
  }
  return out;
}

/**
 * How long a subagent with no `finished` mark may go without writing and still
 * count as running: older Claude Code never marks one finished.
 */
const SUBAGENT_QUIET_MS = 30 * 60_000;

export class Manager implements SessionHost, SessionToolHost {
  private sessions = new Map<string, Session>();
  private infos = new Map<string, SDKSessionInfo>();
  private agents = new Map<string, ActiveAgent>();
  /** Which program holds each external claude process, by pid. */
  private holders = new Map<number, Holder>();
  /** For sessions busy elsewhere: whether the transcript shows the turn has ended. */
  /** Last real message per session, read off the transcript when its stamp changes. */
  private messageAt = new Map<string, { stamp: string; at: number }>();
  private turns = new Map<string, { stamp: string; ended: boolean; modified: number; tasks?: BackgroundTask[] }>();
  private lastTurnEnded = new Map<string, boolean>();
  private checkingTurns = new Set<string>();
  private draining = false;
  /** Shutting down: new messages are held for the next binaryd. */
  closing = false;
  private hurry = false;
  /** The account's plan usage (5-hour, weekly windows), as last read. */
  private usage?: PlanUsage;
  private usageReading?: Promise<PlanUsage | undefined>;
  private subagentCounts = new Map<string, number>();
  private pendingTitles = new Map<string, string>();
  private pendingTags = new Map<string, string>();
  private global = new Set<Subscriber>();
  private dirty = new Set<string>();
  private timers: NodeJS.Timeout[] = [];
  private listing = false;
  private polling = false;
  private agentsOk = true;
  private desktop: DesktopLinks;
  private dirChecks = new Map<string, { exists: boolean; at: number }>();
  private lister = new SessionLister();
  private searcher = new SessionSearch();
  private tempDirs: string[];
  readonly logFn: (msg: string) => void;

  constructor(
    readonly cfg: Config,
    readonly store: Store,
    readonly opts: ManagerOptions,
  ) {
    this.logFn = opts.log ?? ((m) => console.log(`${new Date().toISOString()} ${m}`));
    this.desktop = new DesktopLinks(opts.desktopDir);
    this.tempDirs = opts.tempDirs ?? tempRoots();
  }

  log(msg: string): void {
    this.logFn(msg);
  }

  get defaultMode(): string {
    return this.cfg.data.defaultPermissionMode || 'auto';
  }

  permissionModes(): string[] {
    return this.cfg.data.allowBypassPermissions ? PERMISSION_MODES : PERMISSION_MODES.filter((m) => m !== 'bypassPermissions');
  }

  models(): unknown[] {
    return this.store.models() ?? FALLBACK_MODELS;
  }

  onModels(models: unknown[]): void {
    if (models.length) this.store.setModels(models);
  }

  // ------------------------------------------------------------ loops

  async start(): Promise<void> {
    await Promise.all([this.refreshList(), this.refreshAgents()]);
    this.refreshDesktop();
    const every = (ms: number, fn: () => unknown) => {
      const t = setInterval(() => void fn(), ms);
      t.unref();
      this.timers.push(t);
    };
    every(4000, () => this.refreshList());
    every(3000, () => this.refreshAgents());
    every(10_000, () => this.refreshDesktop());
    every(200, () => this.flushDirty());
    every(1000, () => this.tick());
    every(30_000, () => this.reap());
    // The text index takes a few seconds to build: start it before the first search.
    const warm = setTimeout(() => this.searcher.warm(), 2_000);
    warm.unref();
    this.timers.push(warm);
    // Plan usage for /info, read once in the background after startup.
    setTimeout(() => void this.planUsage(), 5_000).unref();
  }

  /** Refreshes the stored-session list and marks what changed. */
  async refreshList(): Promise<void> {
    if (this.listing) return;
    this.listing = true;
    try {
      const infos = await this.lister.list();
      const next = new Map(infos.map((i) => [i.sessionId, i]));
      const changed: SDKSessionInfo[] = [];
      for (const info of next.values()) {
        const old = this.infos.get(info.sessionId);
        if (
          !old ||
          old.lastModified !== info.lastModified ||
          old.fileSize !== info.fileSize ||
          old.summary !== info.summary ||
          old.tag !== info.tag
        ) {
          changed.push(info);
        }
      }
      const removed = [...this.infos.keys()].filter((id) => !next.has(id));
      this.infos = next;
      for (const info of changed) {
        this.markDirty(info.sessionId);
        if (this.pendingTitles.get(info.sessionId) === info.customTitle) this.pendingTitles.delete(info.sessionId);
        if (this.pendingTags.get(info.sessionId) === (info.tag ?? '')) this.pendingTags.delete(info.sessionId);
        const s = this.sessions.get(info.sessionId);
        if (s && !s.cwd && info.cwd) s.cwd = info.cwd;
        this.noteMessageTime(info);
        await this.applyStoredTag(info);
      }
      for (const id of removed) this.markDirty(id);
      // Counting subagents reads one directory per session; don't hold the list on it.
      if (changed.length) this.countQueue.push(...changed);
      void this.drainCounts();
    } catch (err) {
      this.log(`listSessions failed: ${(err as Error).message}`);
    } finally {
      this.listing = false;
    }
  }

  private noteMessageTime(info: SDKSessionInfo): void {
    const stamp = `${info.lastModified}:${info.fileSize ?? ''}`;
    if (this.messageAt.get(info.sessionId)?.stamp === stamp) return;
    const file = findTranscript(info.sessionId, info.cwd ?? '');
    this.messageAt.set(info.sessionId, { stamp, at: file ? lastMessageAt(file) : 0 });
  }

  /** A tag chosen before the transcript existed is written once it does. */
  private async applyStoredTag(info: SDKSessionInfo): Promise<void> {
    const rec = this.store.get(info.sessionId);
    if (rec?.tag === undefined) return;
    try {
      await tagSession(info.sessionId, rec.tag || null);
      this.store.update(info.sessionId, (r) => delete r.tag);
    } catch (err) {
      this.log(`tagSession ${info.sessionId}: ${(err as Error).message}`);
    }
  }

  private countQueue: SDKSessionInfo[] = [];
  private counting = false;

  private async drainCounts(): Promise<void> {
    if (this.counting) return;
    this.counting = true;
    try {
      while (this.countQueue.length) await this.refreshSubagentCounts(this.countQueue.splice(0, 64));
    } finally {
      this.counting = false;
    }
  }

  private async refreshSubagentCounts(infos: SDKSessionInfo[]): Promise<void> {
    const queue = [...infos];
    const worker = async () => {
      for (let info = queue.shift(); info; info = queue.shift()) {
        try {
          const ids = await listSubagents(info.sessionId);
          if ((this.subagentCounts.get(info.sessionId) ?? 0) !== ids.length) {
            this.subagentCounts.set(info.sessionId, ids.length);
            this.markDirty(info.sessionId);
          }
        } catch {
          // no subagents directory
        }
      }
    };
    await Promise.all(Array.from({ length: 8 }, worker));
  }

  /** Which sessions Claude Code reports as running on this machine. */
  async refreshAgents(): Promise<void> {
    if (this.polling) return;
    this.polling = true;
    try {
      const list = await activeAgents(this.opts.claudeBin, this.opts.env);
      const next = new Map(list.map((a) => [a.sessionId, a]));
      if (list.some((a) => !this.holders.has(a.pid))) {
        const table = await processTable();
        for (const a of list) if (!this.holders.has(a.pid)) this.holders.set(a.pid, holderOf(a.pid, table));
      }
      const pids = new Set(list.map((a) => a.pid));
      for (const pid of this.holders.keys()) if (!pids.has(pid)) this.holders.delete(pid);
      for (const id of new Set([...next.keys(), ...this.agents.keys()])) {
        const a = this.agents.get(id);
        const b = next.get(id);
        if (a?.status !== b?.status || a?.pid !== b?.pid) this.markDirty(id);
      }
      this.agents = next;
      this.agentsOk = true;
      for (const id of this.turns.keys()) if (next.get(id)?.status !== 'busy') this.turns.delete(id);
      for (const a of list) if (a.status === 'busy') void this.checkTurn(a.sessionId);
      void this.drainQueues();
    } catch (err) {
      if (this.agentsOk) this.log(`claude agents --json failed: ${(err as Error).message}`);
      this.agentsOk = false;
    } finally {
      this.polling = false;
    }
  }

  /**
   * `claude agents` calls a session busy while anything runs in it, including
   * a background shell (a dev server, a watcher) long after the turn ended.
   * The transcript tells the two apart: a turn has ended when its last message
   * is a reply with no tool call pending, and nothing was written for a while.
   */
  private async checkTurn(id: string): Promise<void> {
    if (this.checkingTurns.has(id)) return;
    this.checkingTurns.add(id);
    try {
      const info = await getSessionInfo(id);
      if (!info) return;
      const stamp = `${info.lastModified}:${info.fileSize ?? ''}`;
      const known = this.turns.get(id);
      // Still being written: the turn can't count as ended yet, so skip the read.
      if (Date.now() - info.lastModified < TURN_SETTLE_MS) {
        if (known && known.stamp !== stamp) this.turns.delete(id);
      } else if (known?.stamp !== stamp) {
        const msgs = (await getSessionMessages(id)) as unknown as RawMessage[];
        const last = msgs.findLast((m) => (m.type === 'user' || m.type === 'assistant') && !m.parent_tool_use_id);
        const content = last?.message?.content;
        const ended = last?.type === 'assistant' && Array.isArray(content) && !content.some((b) => (b as { type?: string }).type === 'tool_use');
        // What keeps it busy once the turn is over: the process doesn't say, the transcript does.
        const tasks = ended ? this.externalTasks(id, info.cwd ?? '') : undefined;
        this.turns.set(id, { stamp, ended, modified: info.lastModified, ...(tasks?.length && { tasks }) });
        this.markDirty(id);
      }
      const ended = this.turnEnded(id);
      if (ended !== this.lastTurnEnded.get(id)) {
        this.lastTurnEnded.set(id, ended);
        this.markDirty(id);
        if (ended) void this.drainQueues();
      }
    } catch {
      // unreadable for now; keep the last answer
    } finally {
      this.checkingTurns.delete(id);
    }
  }

  private externalTasks(id: string, cwd: string): BackgroundTask[] {
    const file = findTranscript(id, cwd);
    if (!file) return [];
    try {
      return runningTasks(readFileSync(file, 'utf8'), this.agents.get(id)?.startedAt ?? 0);
    } catch {
      return [];
    }
  }

  private turnEnded(id: string): boolean {
    const t = this.turns.get(id);
    return !!t && t.ended && Date.now() - t.modified > TURN_SETTLE_MS;
  }

  /** Whether another program is in the middle of a turn on this session. */
  busyElsewhere(id: string): boolean {
    const agent = this.agents.get(id);
    const s = this.sessions.get(id);
    const ours = s && (s.live || Date.now() - s.lastExit < 10_000);
    return !!agent && !ours && agent.status === 'busy' && !this.turnEnded(id);
  }

  /**
   * Holds a message until the other program's turn ends, or while binaryd
   * shuts down until the next one starts; see drainQueues.
   */
  enqueue(id: string, text: string, images: ImageInput[]): string {
    const s = this.session(id);
    if (!s) throw new HttpError(404, T('sessionNotFound'));
    const item = { id: randomUUID(), text, images, at: new Date().toISOString() };
    s.queued.push(item);
    this.log(`session ${id}: message queued until ${this.closing ? 'binaryd restarts' : "the other program's turn ends"}`);
    this.markDirty(id);
    return item.id;
  }

  async stopTask(id: string, taskId: string): Promise<void> {
    const s = this.sessions.get(id);
    if (!s || !(await s.stopTask(taskId))) throw new HttpError(404, T('taskNotFound'));
  }

  cancelQueued(id: string, qid: string): void {
    const s = this.sessions.get(id);
    const i = s?.queued.findIndex((q) => q.id === qid) ?? -1;
    if (!s || i < 0) throw new HttpError(404, T('queuedNotFound'));
    s.queued.splice(i, 1);
    this.markDirty(id);
  }

  /** Sends queued messages whose session is no longer busy elsewhere, in order. */
  async drainQueues(): Promise<void> {
    if (this.draining || this.closing) return;
    this.draining = true;
    try {
      for (const s of this.sessions.values()) {
        if (!s.queued.length || this.busyElsewhere(s.id)) continue;
        for (const item of s.queued.splice(0)) {
          this.markDirty(s.id);
          await s.send(item.text, item.images).catch((err) => this.log(`session ${s.id}: sending a queued message failed: ${(err as Error).message}`));
        }
      }
    } finally {
      this.draining = false;
    }
  }

  onTurnEnd(s: Session): void {
    if (s.context) this.store.update(s.id, (r) => (r.context = s.context));
    // Plan usage moves with every turn; re-read it now and then.
    if (!this.usage || Date.now() - Date.parse(this.usage.at) > 120_000) void this.planUsage(true);
  }

  /** Last known plan usage, read again when older than maxAgeMs. */
  async planUsage(refresh = false, maxAgeMs = 300_000): Promise<PlanUsage | undefined> {
    if (!refresh && this.usage && Date.now() - Date.parse(this.usage.at) < maxAgeMs) return this.usage;
    this.usageReading ??= this.readUsage().finally(() => (this.usageReading = undefined));
    return this.usageReading;
  }

  cachedUsage(): PlanUsage | undefined {
    return this.usage;
  }

  // ------------------------------------------------------------ layout

  /** Pinned, archived and group order, as clients last set them. */
  layout(): Layout {
    return this.store.layout();
  }

  /**
   * Sets the given fields. Each carries the time the client changed it
   * (`at`, its clock, ms; now when left out): a field older than the one
   * stored is ignored, so a client that was offline can't undo newer changes.
   */
  updateLayout(req: LayoutUpdate): Layout {
    const l = this.store.layout();
    let changed = false;
    for (const f of LAYOUT_FIELDS) {
      const v = req[f];
      if (v === undefined) continue;
      if (!Array.isArray(v) || v.length > 10_000 || v.some((x) => typeof x !== 'string' || x.length > 500)) {
        throw new HttpError(400, T('layoutInvalid', { field: f }));
      }
      const at = typeof req.at?.[f] === 'number' && Number.isFinite(req.at[f]) ? req.at[f] : Date.now();
      if (at < l.at[f]) continue;
      l[f] = [...new Set(v)];
      l.at[f] = at;
      changed = true;
    }
    if (changed) {
      this.store.setLayout(l);
      this.broadcastGlobal(event('layout', { layout: l }));
    }
    return l;
  }

  /**
   * Through any live process; with none, a short-lived one that only starts
   * up and answers (no prompt, no model call).
   */
  private async readUsage(): Promise<PlanUsage | undefined> {
    let u: PlanUsage | undefined;
    for (const s of this.sessions.values()) {
      if (s.live && (u = await s.planUsage())) break;
    }
    if (!u) {
      const input = { async *[Symbol.asyncIterator]() { await new Promise(() => undefined); } } as AsyncIterable<SDKUserMessage>;
      const q = query({
        prompt: input,
        options: {
          cwd: homedir(),
          env: this.opts.env,
          systemPrompt: { type: 'preset', preset: 'claude_code' },
          ...(this.opts.claudePath ? { pathToClaudeCodeExecutable: this.opts.claudePath } : {}),
        },
      });
      try {
        await Promise.race([q.initializationResult(), new Promise((_, no) => setTimeout(() => no(new Error('timeout')), 60_000).unref())]);
        u = await readPlanUsage(q);
      } catch (err) {
        this.log(`reading plan usage failed: ${(err as Error).message}`);
      } finally {
        q.close();
      }
    }
    if (u) {
      this.usage = u;
      this.broadcastGlobal(event('usage', { usage: u }));
    }
    return u ?? this.usage;
  }

  /** Parent links from the desktop app's session records. */
  refreshDesktop(): void {
    try {
      for (const id of this.desktop.refresh()) this.markDirty(id);
    } catch (err) {
      this.log(`reading desktop session records failed: ${(err as Error).message}`);
    }
  }

  private tick(): void {
    for (const s of this.sessions.values()) {
      if (s.subs.size) {
        void s.poll();
      } else if (s.loaded && !s.live && Date.now() - s.lastView > 5 * 60_000) {
        s.unload();
      }
    }
  }

  private reap(): void {
    const minutes = this.cfg.data.idleTimeoutMinutes;
    if (!minutes || minutes <= 0) return;
    for (const s of this.sessions.values()) {
      // Background work (a dev server, a monitor, a subagent) keeps it open.
      if (s.live && s.state === 'idle' && s.pendingCount === 0 && s.busyTasks === 0 && Date.now() - s.lastActive > minutes * 60_000) {
        this.log(`session ${s.id} idle for ${minutes}m, stopping claude`);
        void s.stop();
      }
    }
  }

  /**
   * Stops binaryd's claude processes. Turns already running get up to graceMs
   * to end (one waiting for approval won't); messages arriving meanwhile are
   * queued. Whatever is still cut off (a turn, background tasks, queued
   * messages) is recorded for resumeInterrupted in the next binaryd.
   */
  async shutdown(graceMs = 0): Promise<void> {
    this.closing = true;
    for (const t of this.timers) clearInterval(t);
    this.lister.close();
    this.searcher.close();
    const turning = () => [...this.sessions.values()].filter((s) => s.live && (s.state === 'running' || s.state === 'starting'));
    const deadline = Date.now() + graceMs;
    if (graceMs > 0 && turning().length) this.log(`waiting up to ${Math.round(graceMs / 1000)}s for ${turning().length} running turn(s) to end`);
    while (!this.hurry && Date.now() < deadline && turning().length) await new Promise((r) => setTimeout(r, 200));
    const cut: Interrupted[] = [];
    for (const s of this.sessions.values()) {
      const turn = s.live && (s.state === 'running' || s.state === 'starting' || s.state === 'waiting');
      const tasks = s.live ? [...s.tasks.values()].filter((t) => !t.ambient) : [];
      if (turn || tasks.length || s.queued.length) cut.push({ id: s.id, turn, tasks, queued: s.queued });
    }
    try {
      saveInterrupted(this.cfg.dir, cut);
      if (cut.length) this.log(`recorded ${cut.length} session(s) to resume after restart`);
    } catch (err) {
      this.log(`could not record sessions to resume: ${(err as Error).message}`);
    }
    await Promise.all([...this.sessions.values()].filter((s) => s.live).map((s) => s.stop()));
    for (const sub of this.global) sub.close();
    this.store.flush();
  }

  /** Stop waiting for running turns (a second signal). */
  hurryShutdown(): void {
    this.hurry = true;
  }

  /**
   * Picks up what the previous binaryd cut off: each such session gets a note
   * on what happened, then its queued messages, in order.
   */
  async resumeInterrupted(): Promise<void> {
    const prev = takeInterrupted(this.cfg.dir);
    if (!prev) return;
    for (const r of prev.sessions) {
      const s = this.session(r.id);
      if (!s) continue;
      const queued = Array.isArray(r.queued) ? r.queued : [];
      const tasks = Array.isArray(r.tasks) ? r.tasks : [];
      const items = queued.filter((q) => q && typeof q.text === 'string').map((q) => ({ ...q, images: Array.isArray(q.images) ? q.images : [] }));
      if (r.turn || tasks.length) {
        items.unshift({ id: randomUUID(), text: resumeNote({ ...r, tasks }, prev.stoppedAt), images: [], at: new Date().toISOString() });
      }
      s.queued.push(...items);
      this.markDirty(s.id);
      this.log(`session ${s.id}: resuming after restart (${r.turn ? 'turn cut off' : 'no turn'}, ${tasks.length} task(s), ${queued.length} queued)`);
    }
    await this.drainQueues();
  }

  // ------------------------------------------------------------ sessions

  /** The runtime object for a known session (stored transcript or Binary record). */
  session(id: string): Session | undefined {
    let s = this.sessions.get(id);
    if (s) return s;
    const info = this.infos.get(id);
    const rec = this.store.get(id);
    if (!info && !rec) return undefined;
    s = new Session(id, this);
    s.cwd = this.cwdFor(id);
    this.sessions.set(id, s);
    return s;
  }

  /** Whether Claude Code has stored this session (anywhere: its cwd may have changed). */
  private async transcriptExists(id: string, cwd: string): Promise<boolean> {
    if (this.infos.has(id) || existsSync(transcriptPath(id, cwd))) return true;
    try {
      return (await getSessionInfo(id)) !== undefined;
    } catch {
      return false;
    }
  }

  async queryOptions(s: Session): Promise<Options> {
    const rec = this.store.get(s.id);
    const cwd = this.cwdFor(s.id) || s.cwd;
    const why = this.cannotRun(s.id, cwd);
    if (why) throw new LocalizedError(why);
    s.cwd = cwd;
    const exists = await this.transcriptExists(s.id, cwd);
    const mode = this.modeFor(s.id);
    return {
      cwd,
      ...(exists ? { resume: s.id } : { sessionId: s.id }),
      ...(rec?.model && rec.model !== 'default' ? { model: rec.model } : {}),
      ...(rec?.effort ? { effort: rec.effort as EffortLevel } : {}),
      permissionMode: mode as PermissionMode,
      allowDangerouslySkipPermissions: this.cfg.data.allowBypassPermissions,
      // Without this the SDK uses a minimal prompt; match the CLI instead.
      systemPrompt: { type: 'preset', preset: 'claude_code' },
      includePartialMessages: true,
      env: { ...this.opts.env, ...(rec?.env ?? {}) },
      ...(this.opts.claudePath ? { pathToClaudeCodeExecutable: this.opts.claudePath } : {}),
      ...(!exists && rec?.title ? { title: rec.title } : {}),
      // get_session / set_session_title, as the Claude desktop app gives its sessions.
      mcpServers: { [SESSION_TOOL_SERVER]: sessionTools(s.id, this) },
      allowedTools: SESSION_TOOLS,
      // Hook inputs carry the effort Claude Code applies to the turn, after its
      // own defaults and model limits: the only place an SDK host can read it.
      hooks: { PreToolUse: [{ hooks: [this.effortHook(s)] }], Stop: [{ hooks: [this.effortHook(s)] }] },
      // Clients list background tasks with a stop button each, so an
      // interrupt only ends the turn and leaves them running.
      perTaskStopAffordance: true,
    };
  }

  private effortHook(s: Session): HookCallback {
    return async (input) => {
      const level = input.agent_id ? undefined : input.effort?.level; // subagents have their own
      if (level && level !== s.appliedEffort) {
        s.appliedEffort = level;
        this.store.update(s.id, (r) => (r.appliedEffort = level));
        this.markDirty(s.id);
      }
      return {};
    };
  }

  /** get_session: a session's metadata, with its text rendered. */
  sessionInfo(id: string): Record<string, unknown> | undefined {
    const sum = this.summary(id);
    if (!sum) return undefined;
    const { title, cwd, gitBranch, worktree, model, lastModel, effort, permissionMode, state, tag, parentId, createdAt, updatedAt } = sum;
    const info = { id, title, cwd, gitBranch, worktree, model: model || lastModel, effort, permissionMode, state, group: tag, parentSessionId: parentId, createdAt, updatedAt };
    return JSON.parse(encode(info, 'en')) as Record<string, unknown>;
  }

  /** set_session_title: the same rename a client does. */
  async setTitle(id: string, title: string): Promise<string> {
    const { session } = await this.update(id, { title });
    return typeof session.title === 'string' ? session.title : session.title.render('en');
  }

  /**
   * The folder a session runs in: Binary's own record; else the folder the
   * claude process holding it elsewhere was started in (the transcript's
   * first cwd can be another machine's, for a session moved here); else the
   * folder the desktop app starts it in (the session may have cd'd into a
   * worktree that is gone since, which is what Claude Code reports as its
   * cwd); else that.
   */
  cwdFor(id: string): string {
    const rec = this.store.get(id);
    if (rec?.cwd) return rec.cwd;
    const held = this.agents.get(id)?.cwd;
    if (held && this.dirExists(held)) return held;
    const desk = this.desktop.cwdOf(id);
    if (desk && this.dirExists(desk)) return desk;
    return this.infos.get(id)?.cwd || '';
  }

  /**
   * The permission mode a session runs in when Binary starts it: one chosen in
   * Binary, unless the desktop app has changed its own since; otherwise the
   * desktop app's; otherwise the server default.
   */
  modeFor(id: string): string {
    const rec = this.store.get(id);
    const desk = this.desktop.modeOf(id);
    const deskOk = desk && PERMISSION_MODES.includes(desk) ? desk : undefined;
    let mode = rec?.permissionMode && (!deskOk || rec.desktopModeAtChoice === deskOk) ? rec.permissionMode : deskOk || rec?.permissionMode || this.defaultMode;
    if (mode === 'bypassPermissions' && !this.cfg.data.allowBypassPermissions) mode = 'default';
    return mode;
  }

  /** Why a session cannot run on this machine, if it cannot. */
  cannotRun(id: string, cwd = this.cwdFor(id) || this.sessions.get(id)?.cwd || ''): Text | undefined {
    const host = this.desktop.sshHostOf(id);
    if (host) return T('sshSession', { host });
    if (!cwd) return T('cwdUnknown');
    if (!isDir(cwd)) return T('cwdMissing', { path: cwd });
    this.dirChecks.set(cwd, { exists: true, at: Date.now() });
    return undefined;
  }

  /** Cached isDir for summaries, which are built for every session often. */
  private dirExists(dir: string): boolean {
    const hit = this.dirChecks.get(dir);
    if (hit && Date.now() - hit.at < 30_000) return hit.exists;
    const exists = isDir(dir);
    this.dirChecks.set(dir, { exists, at: Date.now() });
    return exists;
  }

  // ------------------------------------------------------------ summaries

  markDirty(id: string): void {
    this.dirty.add(id);
  }

  private flushDirty(): void {
    if (!this.dirty.size) return;
    const ids = [...this.dirty];
    this.dirty.clear();
    for (const id of ids) {
      const sum = this.summary(id);
      const ev = sum ? event('session', { session: sum }) : event('removed', { id });
      this.broadcastGlobal(ev);
      if (sum) this.sessions.get(id)?.broadcast(ev);
    }
  }

  summaryJSON(s: Session): unknown {
    return this.summary(s.id);
  }

  summary(id: string): Summary | undefined {
    const info = this.infos.get(id);
    const rec = this.store.get(id);
    const s = this.sessions.get(id);
    if (!info && !rec) return undefined;

    const cwd = this.cwdFor(id) || s?.cwd || '';
    const created = info?.createdAt ?? (rec?.createdAt ? Date.parse(rec.createdAt) : 0);
    const lastMsg = this.messageAt.get(id)?.at;
    let updated = Math.max(lastMsg || info?.lastModified || 0, created || 0, s?.listedActive ?? 0);
    const title =
      rec?.title?.trim() ||
      this.pendingTitles.get(id) ||
      info?.summary?.trim() ||
      (info?.firstPrompt ? preview(info.firstPrompt, 80) : '') ||
      T('newSession');
    const tag = this.pendingTags.get(id) ?? rec?.tag ?? info?.tag;

    const sum: Summary = {
      id,
      title,
      cwd,
      project: cwd ? basename(cwd) : '',
      createdAt: created ? new Date(created).toISOString() : EPOCH,
      updatedAt: EPOCH,
      state: 'idle',
      live: false,
      permissionMode: this.modeFor(id),
      pending: 0,
      messages: 0,
      managed: rec !== undefined,
    };
    if (info?.gitBranch || rec?.branch) sum.gitBranch = info?.gitBranch || rec?.branch;
    if (rec?.worktree) sum.worktree = rec.worktree;
    const sshHost = this.desktop.sshHostOf(id);
    if (sshHost) sum.sshHost = sshHost;
    if (cwd) sum.cwdExists = this.dirExists(cwd);
    if (rec?.model) sum.model = rec.model;
    if (rec?.effort) sum.effort = rec.effort;
    const context = s?.context ?? rec?.context;
    if (context) sum.context = context;
    const applied = s?.appliedEffort ?? rec?.appliedEffort;
    if (applied) sum.appliedEffort = applied;
    if (tag) sum.tag = tag;
    const parentId = rec?.parentId || this.desktop.parentOf(id);
    if (parentId && (this.infos.has(parentId) || this.store.get(parentId))) sum.parentId = parentId;
    const subagents = this.subagentCounts.get(id);
    if (subagents) sum.subagentCount = subagents;

    if (s) {
      sum.state = s.state;
      sum.live = s.live;
      if (s.live && s.liveMode) sum.permissionMode = s.liveMode;
      if (s.activity) sum.activity = s.activity;
      if (s.lastSummary) sum.lastSummary = s.lastSummary;
      if (s.preview) sum.preview = s.preview;
      if (s.lastModel) sum.lastModel = s.lastModel;
      if (s.costUsd) sum.costUsd = s.costUsd;
      if (s.errMsg) sum.error = s.errMsg;
      if (s.live && s.tasks.size) sum.tasks = [...s.tasks.values()];
      const minutes = this.cfg.data.idleTimeoutMinutes;
      if (s.live && s.state === 'idle' && s.busyTasks === 0 && minutes > 0 && s.lastActive) {
        sum.closesAt = new Date(s.lastActive + minutes * 60_000).toISOString();
      }
      sum.pending = s.pendingCount;
      sum.messages = s.messageCount;
    }
    if (!sum.preview && info?.firstPrompt) sum.preview = preview(info.firstPrompt, 140);

    // Held by a claude process in the desktop app, a terminal, tmux or an IDE, not ours.
    // Such processes often stay open for days doing nothing: only a busy one is activity.
    const agent = this.agents.get(id);
    const ours = s && (s.live || Date.now() - s.lastExit < 10_000);
    if (agent && !ours && (sum.state === 'idle' || sum.state === 'error')) {
      const background = agent.status === 'busy' && this.turnEnded(id);
      const busy = agent.status === 'busy' && !background;
      const holder = this.holders.get(agent.pid) ?? 'other';
      sum.state = 'external';
      sum.external = { busy, ...(background && { background }), holder };
      const now = new Date().toISOString();
      const tasks = background ? (this.turns.get(id)?.tasks ?? []).filter((t) => !t.endsAt || t.endsAt > now) : [];
      const holderText = T(HOLDER_TEXT[holder]);
      if (tasks.length) {
        sum.tasks = tasks;
        const task = tasks.at(-1)!.description || tasks.at(-1)!.type;
        sum.activity = tasks.length === 1
          ? T('externalBackgroundTask', { holder: holderText, task })
          : T('externalBackgroundTasks', { holder: holderText, task, count: tasks.length });
      } else {
        sum.activity = T(busy ? 'externalBusy' : background ? 'externalBackground' : 'externalOpen', { holder: holderText });
      }
      if (busy && agent.startedAt) updated = Math.max(updated, agent.startedAt);
    }
    if (s?.queued.length) sum.queued = s.queued.map((q) => ({ id: q.id, text: preview(q.text, 200), images: q.images.length, at: q.at }));
    sum.updatedAt = updated ? new Date(updated).toISOString() : sum.createdAt;
    return sum;
  }

  /** Sessions whose messages contain every word of q, latest match first. */
  async search(q: string, limit: number): Promise<SearchResult[]> {
    const found = await this.searcher.search(q, limit);
    return found.filter((r) => this.infos.has(r.id) || this.sessions.has(r.id));
  }

  summaries(): Summary[] {
    const ids = new Set([...this.infos.keys(), ...this.store.all().map((r) => r.id)]);
    const out: Summary[] = [];
    for (const id of ids) {
      const s = this.summary(id);
      if (s) out.push(s);
    }
    return out.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  subscribeGlobal(sink: Sink, lang: Lang = DEFAULT_LANG): Subscriber {
    const sub: Subscriber = new Subscriber(sink, () => this.global.delete(sub), lang);
    sub.send(event('sessions', { sessions: this.summaries() }));
    sub.send(event('layout', { layout: this.store.layout() }));
    this.global.add(sub);
    return sub;
  }

  private broadcastGlobal(ev: Event): void {
    for (const sub of [...this.global]) sub.send(ev);
  }

  // ------------------------------------------------------------ mutations

  private validate(effort?: string, mode?: string): void {
    if (effort && !EFFORT_LEVELS.includes(effort)) throw new HttpError(400, T('unknownEffort', { value: effort }));
    if (mode && !this.permissionModes().includes(mode)) throw new HttpError(400, T('modeNotAllowed', { value: mode }));
  }

  async create(req: CreateRequest): Promise<Summary> {
    const given = expandPath(req.cwd);
    if (!isDir(given)) throw new HttpError(400, T('dirMissing', { path: given }));
    // Claude Code records (and names project folders after) the resolved path.
    let cwd = realpathSync(given);
    this.validate(req.effort, req.permissionMode);
    if (req.parentId && !this.summary(req.parentId)) throw new HttpError(400, T('parentNotFound', { id: req.parentId }));
    const images = checkImages(req.images);
    const env = checkEnv(req.env);

    // Git setup last, once everything else is known to be valid.
    let branch = req.branch?.trim() || undefined;
    let worktree: string | undefined;
    if (req.worktree) {
      const name = typeof req.worktree === 'string' && req.worktree.trim() ? req.worktree.trim() : worktreeName(req.title || req.prompt || basename(cwd));
      const wt = await createWorktree(cwd, name, branch);
      cwd = wt.cwd;
      branch = wt.branch;
      worktree = wt.path;
      this.log(`created worktree ${wt.path} (${wt.branch})`);
    } else if (branch) {
      await switchBranch(cwd, branch);
    }

    const id = randomUUID();
    this.store.update(id, (r) => {
      r.cwd = cwd;
      r.created = true;
      if (req.title?.trim()) r.title = req.title.trim();
      if (req.model) r.model = req.model;
      if (req.effort) r.effort = req.effort;
      if (req.permissionMode) r.permissionMode = req.permissionMode;
      if (req.tag) r.tag = req.tag;
      if (req.parentId) r.parentId = req.parentId;
      if (env) r.env = env;
      if (branch) r.branch = branch;
      if (worktree) r.worktree = worktree;
    });
    const s = this.session(id)!;
    s.loaded = true; // nothing stored yet
    if (req.prompt?.trim() || images.length) {
      s.state = 'starting';
      s.activity = T('starting');
      s.send(req.prompt ?? '', images).catch((err) => this.log(`session ${id}: ${(err as Error).message}`));
    }
    this.markDirty(id);
    return this.summary(id)!;
  }

  /**
   * Continues a session in a copy (SDK forkSession: new id, same history), so
   * a session another program holds open is left to it. The copy runs in the
   * same folder with the same settings and group, nested under the original.
   */
  async fork(id: string, req: { title?: string; text?: string; images?: unknown }): Promise<Summary> {
    const s = this.session(id);
    if (!s) throw new HttpError(404, T('sessionNotFound'));
    const why = this.cannotRun(id);
    if (why) throw new HttpError(409, why);
    const images = checkImages(req.images);
    const src = this.store.get(id);
    const info = this.infos.get(id);
    let forked: string;
    try {
      forked = (await forkSession(id, req.title?.trim() ? { title: req.title.trim() } : {})).sessionId;
    } catch (err) {
      throw new HttpError(502, T('forkFailed', { detail: (err as Error).message }));
    }
    const tag = this.pendingTags.get(id) ?? src?.tag ?? info?.tag;
    this.store.update(forked, (r) => {
      r.cwd = this.cwdFor(id) || s.cwd;
      r.created = true;
      r.parentId = id;
      if (src?.model) r.model = src.model;
      if (src?.effort) r.effort = src.effort;
      if (src?.permissionMode) r.permissionMode = src.permissionMode;
      if (src?.env) r.env = src.env;
      if (src?.branch) r.branch = src.branch;
      if (src?.worktree) r.worktree = src.worktree;
      if (tag) r.tag = tag; // written to the copy's transcript on the next list refresh
    });
    await this.refreshList();
    this.log(`forked ${id} into ${forked}`);
    const copy = this.session(forked)!;
    await copy.ensureLoaded(); // the copied history, before anything new
    if (req.text?.trim() || images.length) {
      copy.send(req.text ?? '', images).catch((err) => this.log(`session ${forked}: ${(err as Error).message}`));
    }
    this.markDirty(forked);
    return this.summary(forked)!;
  }

  async update(id: string, u: SettingsUpdate): Promise<{ session: Summary; warnings: Msg[] }> {
    const s = this.session(id);
    if (!s) throw new HttpError(404, T('sessionNotFound'));
    this.validate(u.effort, u.permissionMode);
    const info = this.infos.get(id);
    this.store.update(id, (r) => {
      if (!r.cwd) r.cwd = this.cwdFor(id) || undefined;
      if (u.model !== undefined) r.model = u.model || undefined;
      if (u.effort !== undefined) {
        r.effort = u.effort || undefined;
        delete r.appliedEffort; // known again after the next turn
      }
      if (u.permissionMode !== undefined) {
        r.permissionMode = u.permissionMode || undefined;
        r.desktopModeAtChoice = this.desktop.modeOf(id);
      }
    });
    if (u.effort !== undefined) s.appliedEffort = undefined;
    const warnings = await s.applyUpdate(u, this.defaultMode);
    const cwd = s.cwd || info?.cwd || '';
    const stored = cwd ? await this.transcriptExists(id, cwd) : false;
    if (u.title !== undefined && u.title.trim()) {
      const title = u.title.trim();
      if (stored) {
        await renameSession(id, title);
        await s.noteOwnWrite();
        this.pendingTitles.set(id, title);
        this.store.update(id, (r) => delete r.title);
      } else {
        this.store.update(id, (r) => (r.title = title));
      }
    }
    if (u.tag !== undefined) {
      const tag = u.tag.trim();
      if (stored) {
        await tagSession(id, tag || null);
        await s.noteOwnWrite();
        this.pendingTags.set(id, tag);
        this.store.update(id, (r) => delete r.tag);
      } else {
        this.store.update(id, (r) => (r.tag = tag));
      }
    }
    this.markDirty(id);
    return { session: this.summary(id)!, warnings };
  }

  // ------------------------------------------------------------ subagents

  async subagents(id: string): Promise<SubagentInfo[]> {
    const s = this.session(id);
    if (!s) throw new HttpError(404, T('sessionNotFound'));
    const ids = await listSubagents(id).catch(() => [] as string[]);
    const metas = ids.length ? subagentMetas(id, this.cwdFor(id) || s.cwd) : new Map<string, SubagentMeta>();
    // Only a claude process on the session (ours or another program's) runs its subagents.
    const alive = s.live || this.agents.has(id);
    const out: SubagentInfo[] = [];
    for (const agentId of ids) {
      const msgs = (await getSubagentMessages(id, agentId).catch(() => [])) as unknown as RawMessage[];
      const entries = toEntries(msgs, { subagent: true });
      const firstText = entries.find((e) => e.kind === 'user' && typeof e.blocks?.[0]?.text === 'string')?.blocks?.[0]?.text;
      const prompt = typeof firstText === 'string' ? firstText : '';
      const last = entries.findLast((e) => e.time)?.time;
      const meta = metas.get(agentId);
      const running =
        alive &&
        !meta?.finished &&
        !meta?.stoppedByUser &&
        (s.tasks.has(agentId) || (!!last && Date.now() - Date.parse(last) < SUBAGENT_QUIET_MS));
      out.push({
        id: agentId,
        title: meta?.description || preview(prompt || agentId, 80),
        // Lets clients match a Task/Agent tool call to its subagent exactly.
        ...(prompt && { prompt: prompt.slice(0, 4000) }),
        entries: entries.length,
        ...(entries[0]?.time && { startedAt: entries[0].time }),
        ...(last && { updatedAt: last }),
        ...(running && { running }),
      });
    }
    return out.sort((a, b) => (a.startedAt ?? '').localeCompare(b.startedAt ?? ''));
  }

  async subagentEntries(id: string, agentId: string): Promise<Entry[]> {
    const s = this.session(id);
    if (!s) throw new HttpError(404, T('sessionNotFound'));
    const msgs = (await getSubagentMessages(id, agentId)) as unknown as RawMessage[];
    return toEntries(msgs, { subagent: true }).map((e, i) => ({ ...e, seq: i + 1 }));
  }

  // ------------------------------------------------------------ misc

  /**
   * Folders of recent sessions that still exist, newest first: a worktree
   * counts as its main repository, and scratch folders are left out.
   */
  recentDirs(limit: number): string[] {
    const items: { cwd: string; at: number }[] = [];
    for (const r of this.store.all()) if (r.created && r.cwd) items.push({ cwd: r.cwd, at: Date.parse(r.createdAt) });
    for (const i of this.infos.values()) if (i.cwd) items.push({ cwd: i.cwd, at: i.lastModified });
    items.sort((a, b) => b.at - a.at);
    const seen = new Set<string>();
    const out: string[] = [];
    for (const { cwd } of items) {
      if (seen.has(cwd)) continue;
      seen.add(cwd);
      // Mapped lazily: only as many folders as the list needs are looked at.
      // A repository is checked once however many worktrees map to it, which
      // matters for folders that are slow to stat (autofs /home on macOS).
      const dir = mainCheckout(cwd);
      if (dir !== cwd) {
        if (seen.has(dir)) continue;
        seen.add(dir);
      }
      if (isUnder(dir, this.tempDirs) || !isDir(dir)) continue;
      out.push(dir);
      if (out.length >= limit) break;
    }
    return out;
  }
}
