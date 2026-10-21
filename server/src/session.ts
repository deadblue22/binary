// The runtime side of one Claude session: its SDK query (if live), its merged
// log and its viewers. Everything Claude-facing goes through the official
// Agent SDK: query() for live sessions, getSessionMessages()/getSessionInfo()
// for stored transcripts.

import { randomUUID } from 'node:crypto';
import {
  query,
  getSessionInfo,
  getSessionMessages,
  type Options,
  type PermissionMode,
  type PermissionResult,
  type PermissionUpdate,
  type Query,
  type SDKUserMessage,
} from '@anthropic-ai/claude-agent-sdk';
import { DEFAULT_LANG, errorText, LocalizedError, render, T, Text, type Lang, type Msg } from './i18n.js';
import { event, Log, Subscriber, type Event, type Sink } from './log.js';
import { firstText, toEntries, toEntry, toolLabel, preview, type Entry, type RawMessage } from './normalize.js';

export type State = 'idle' | 'starting' | 'running' | 'waiting' | 'error' | 'external';

export interface PermissionRequest {
  id: string;
  toolName: string;
  displayName?: string;
  title?: string;
  description?: string;
  input: unknown;
  suggestions?: PermissionUpdate[];
  blockedPath?: string;
  decisionReason?: string;
  toolUseId?: string;
  createdAt: string;
}

export interface Decision {
  behavior: 'allow' | 'deny';
  message?: string;
  updatedInput?: Record<string, unknown>;
  remember?: boolean;
  interrupt?: boolean;
}

export interface PartialBlock {
  messageId: string;
  index: number;
  type: 'text' | 'thinking' | 'tool_use';
  name?: string;
  text?: string;
  size: number;
}

/** An image attached to a user message, as base64. */
export interface ImageInput {
  mediaType: string;
  data: string;
}

export const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];
const MAX_IMAGES = 20;
const MAX_IMAGE_MB = 5;
/** Image data kept per session for clients to display. */
const IMAGE_CACHE_BYTES = 48 << 20;

/** Validates attachments before anything else happens. */
export function checkImages(images: unknown): ImageInput[] {
  if (images == null) return [];
  if (!Array.isArray(images)) throw new LocalizedError(T('imageInvalid'));
  if (images.length > MAX_IMAGES) throw new LocalizedError(T('tooManyImages', { max: MAX_IMAGES }));
  return images.map((img: unknown) => {
    const { mediaType, data } = (img ?? {}) as Partial<ImageInput>;
    if (typeof mediaType !== 'string' || !IMAGE_TYPES.includes(mediaType) || typeof data !== 'string' || !/^[A-Za-z0-9+/]+=*$/.test(data)) {
      throw new LocalizedError(T('imageInvalid'));
    }
    if ((data.length * 3) / 4 > MAX_IMAGE_MB << 20) throw new LocalizedError(T('imageTooLarge', { max: MAX_IMAGE_MB }));
    return { mediaType, data };
  });
}

export interface SettingsUpdate {
  model?: string;
  effort?: string;
  permissionMode?: string;
  title?: string;
  tag?: string;
}

/** What a session needs from the manager. */
export interface SessionHost {
  queryOptions(s: Session): Promise<Options>;
  onModels(models: unknown[]): void;
  markDirty(id: string): void;
  summaryJSON(s: Session): unknown;
  log(msg: string): void;
  /** A turn ended: context usage changed, and plan usage may have. */
  onTurnEnd?(s: Session): void;
}

const SNAPSHOT_ENTRIES = 300;

/** A client's requested snapshot size, within reason. */
const tail = (n: number | undefined) => (n && n > 0 ? Math.min(n, 2000) : SNAPSHOT_ENTRIES);

export interface ContextUsage {
  percent: number;
  tokens: number;
  max: number;
  at: string;
}

/** Plan usage windows (5 hours, 7 days, per model), from Claude Code's /usage data. */
export interface PlanUsage {
  available: boolean;
  windows: { kind: string; percent: number; resetsAt?: string }[];
  at: string;
}

export interface QueuedMessage {
  id: string;
  text: string;
  images: ImageInput[];
  at: string;
}

export class NotLiveError extends LocalizedError {
  constructor() {
    super(T('notLive'));
  }
}

/** The user messages fed to query(); stays open for the life of the process. */
class InputQueue implements AsyncIterable<SDKUserMessage> {
  private items: SDKUserMessage[] = [];
  private wake?: () => void;
  private done = false;

  push(m: SDKUserMessage): void {
    this.items.push(m);
    this.wake?.();
  }

  end(): void {
    this.done = true;
    this.wake?.();
  }

  async *[Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    for (;;) {
      while (this.items.length) yield this.items.shift()!;
      if (this.done) return;
      await new Promise<void>((r) => (this.wake = r));
      this.wake = undefined;
    }
  }
}

interface Proc {
  q: Query;
  input: InputQueue;
  gen: number;
  stderr: string[];
  closing: boolean;
  done: Promise<void>;
}

interface Pending {
  req: PermissionRequest;
  settle: (r: PermissionResult) => void;
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function stderrHint(lines: string[]): string {
  const tail = lines.join('').trim().split('\n').slice(-6).join('\n');
  return tail ? '\n' + tail : '';
}

function withTimeout<V>(p: Promise<V>, ms: number, what?: Text): Promise<V> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(what ? new LocalizedError(what) : new Error('timeout')), ms);
    p.then(
      (v) => {
        clearTimeout(t);
        resolve(v);
      },
      (e) => {
        clearTimeout(t);
        reject(e);
      },
    );
  });
}

/** A background task of the live process, as clients show it. */
export interface BackgroundTask {
  id: string;
  /** shell, subagent, monitor, workflow… */
  type: string;
  description: string;
  agentType?: string;
  /** Housekeeping (watchers and the like), not activity. */
  ambient?: boolean;
  startedAt: string;
}

export class Session {
  // live process
  private proc?: Proc;
  private gen = 0;
  private spawning?: Promise<Proc>;
  state: State = 'idle';
  activity: Msg = '';
  lastSummary = '';
  errMsg: Msg = '';
  costUsd = 0;
  liveMode = '';
  lastModel = '';
  /** Effort Claude Code applied to the latest turn (from its hooks). */
  appliedEffort?: string;
  /** How full the context window is, as of the latest turn. */
  context?: ContextUsage;
  /** Background work the process is running (shells, subagents, monitors…), by task id. */
  tasks = new Map<string, BackgroundTask>();
  /** Messages waiting for another program's turn on this session to end. */
  queued: QueuedMessage[] = [];
  /** Conversation messages our own processes wrote (by uuid). */
  private ownUuids = new Set<string>();
  /** Transcript stamp as our process last left it. */
  private ownStamp = '';
  preview = '';
  lastActive = 0;
  lastExit = 0;
  /** User and assistant messages, as of the last time the log was read; kept after unload. */
  messageCount = 0;
  /** A setting changed that only a fresh process picks up. */
  restart = false;
  /** Working directory, known once the manager resolved it. */
  cwd = '';

  // transcript
  log = new Log();
  loaded = false;
  private loading?: Promise<void>;
  private stamp = '';
  private lastReloadAt = 0;
  private reloadCost = 0;
  private busyReading = false;
  lastView = 0;

  // streaming
  private partial?: PartialBlock;
  private partialText = '';
  private partialTimer?: NodeJS.Timeout;

  private pending = new Map<string, Pending>();
  readonly subs = new Set<Subscriber>();

  // image data seen in this session's messages, oldest evicted first
  private images = new Map<string, { mediaType: string; data: string }>();
  private imageBytes = 0;
  private readonly collectImage = (key: string, mediaType: string, data: string): void => {
    if (this.images.has(key)) return;
    this.images.set(key, { mediaType, data });
    this.imageBytes += data.length;
    for (const [k, v] of this.images) {
      if (this.imageBytes <= IMAGE_CACHE_BYTES || this.images.size <= 1) break;
      this.images.delete(k);
      this.imageBytes -= v.data.length;
    }
  };
  private readonly entryOpts = { onImage: this.collectImage };

  /** An image from this session's messages, if still cached. */
  image(key: string): { mediaType: string; bytes: Buffer } | undefined {
    const img = this.images.get(key);
    return img ? { mediaType: img.mediaType, bytes: Buffer.from(img.data, 'base64') } : undefined;
  }

  constructor(
    readonly id: string,
    private readonly host: SessionHost,
  ) {}

  get live(): boolean {
    return this.proc !== undefined;
  }

  get pendingCount(): number {
    return this.pending.size;
  }

  // ------------------------------------------------------------ transcript

  /** Reads the stored transcript once and merges anything a live process produced. */
  async ensureLoaded(): Promise<void> {
    if (this.loaded) return;
    if (!this.loading) {
      this.loading = (async () => {
        const t0 = performance.now();
        const [msgs, stamp] = await Promise.all([this.readMessages(), this.readStamp()]);
        this.reloadCost = performance.now() - t0;
        this.lastReloadAt = Date.now();
        this.stamp = stamp;
        const merged = new Log();
        for (const e of toEntries(msgs, this.entryOpts)) merged.append(e);
        for (const e of this.log.entries) merged.append(e);
        this.log = merged;
        this.loaded = true;
        this.deriveFromLog();
      })().finally(() => (this.loading = undefined));
    }
    await this.loading;
  }

  // Lookups go by session id alone, never with the cwd as a project hint:
  // a session that changed directory midway (worktrees, cd) keeps its
  // transcript in the folder of the directory it started in, while its
  // reported cwd is the latest one.
  private async readMessages(): Promise<RawMessage[]> {
    try {
      return (await getSessionMessages(this.id)) as unknown as RawMessage[];
    } catch {
      return [];
    }
  }

  private async readStamp(): Promise<string> {
    try {
      const info = await getSessionInfo(this.id);
      return info ? `${info.lastModified}:${info.fileSize ?? ''}` : '';
    } catch {
      return '';
    }
  }

  /**
   * Picks up transcript changes made by other programs. Cheap when nothing
   * changed (one stat-like lookup); a full re-read is throttled by its cost.
   */
  async poll(): Promise<void> {
    if (!this.loaded || this.proc || this.busyReading) return;
    if (Date.now() - this.lastReloadAt < Math.max(1000, this.reloadCost * 3)) return;
    this.busyReading = true;
    try {
      const stamp = await this.readStamp();
      if (stamp && stamp !== this.stamp) {
        this.stamp = stamp;
        await this.reload();
      }
    } finally {
      this.busyReading = false;
    }
  }

  /** Re-reads the transcript and reconciles it with the log. */
  private async reload(): Promise<void> {
    const t0 = performance.now();
    const msgs = await this.readMessages();
    this.reloadCost = performance.now() - t0;
    this.lastReloadAt = Date.now();
    if (this.proc) return; // the live stream is authoritative while it runs
    this.reconcile(toEntries(msgs, this.entryOpts));
  }

  /**
   * Appends what is new, or — when the stored conversation no longer contains
   * what we show (rewind, compaction rewrite) — replaces the log.
   */
  private reconcile(fresh: Entry[]): void {
    // A read that finds no conversation (e.g. a turn interrupted before any
    // reply) must not wipe what the live stream already showed.
    if (!fresh.length) return;
    const ids = new Set(fresh.map((e) => e.uuid));
    // Results and notices exist only in the live stream; the conversation
    // itself (user and assistant messages) must still be there.
    const shown = this.log.entries.filter((e) => e.kind === 'user' || e.kind === 'assistant');
    if (shown.every((e) => ids.has(e.uuid))) {
      // Only what follows the newest entry we already show; earlier ones that
      // exist only on disk (command echoes) would land out of order.
      let last = -1;
      fresh.forEach((e, i) => {
        if (this.log.has(e.uuid)) last = i;
      });
      this.append(fresh.slice(last + 1).filter((e) => !this.log.has(e.uuid)));
    } else {
      this.log = new Log();
      for (const e of fresh) this.log.append(e);
      this.broadcast(this.snapshot());
    }
    this.deriveFromLog();
  }

  /** Frees memory for sessions nobody looks at. */
  unload(): void {
    if (this.subs.size || this.proc) return;
    this.loaded = false;
    this.log = new Log();
    this.images.clear();
    this.imageBytes = 0;
  }

  private append(entries: Entry[]): void {
    const added: Entry[] = [];
    for (const e of entries) {
      const stored = this.log.append(e);
      if (stored) added.push(stored);
    }
    if (added.length) {
      this.messageCount += added.filter((e) => e.kind === 'user' || e.kind === 'assistant').length;
      this.broadcast(event('entries', { gen: this.log.gen, entries: added }));
    }
  }

  private deriveFromLog(): void {
    this.messageCount = this.log.entries.filter((e) => e.kind === 'user' || e.kind === 'assistant').length;
    for (let i = this.log.entries.length - 1; i >= 0; i--) {
      const e = this.log.entries[i];
      if (e.kind !== 'assistant') continue;
      if (!this.lastModel && e.model && e.model !== '<synthetic>') this.lastModel = e.model;
      if (!this.preview) {
        const t = e.blocks?.find((b) => b.type === 'text')?.text;
        if (typeof t === 'string' && t) this.preview = preview(t, 140);
      }
      if (this.lastModel && this.preview) break;
    }
  }

  // ------------------------------------------------------------ viewers

  /**
   * since/gen continue a stream from the same log. Otherwise `after` (entry
   * uuids a client has cached, newest first) sends only what follows the
   * first one this log has, as a `delta`; failing that, a snapshot of the
   * last `tail` entries.
   */
  async subscribe(since: number, gen: string, sink: Sink, lang: Lang = DEFAULT_LANG, opts: { tail?: number; after?: string[] } = {}): Promise<Subscriber> {
    await this.ensureLoaded();
    const sub: Subscriber = new Subscriber(
      sink,
      () => {
        this.subs.delete(sub);
        this.lastView = Date.now();
      },
      lang,
    );
    this.subs.add(sub);
    this.lastView = Date.now();
    if (gen && gen === this.log.gen && since <= this.log.lastSeq) {
      sub.send(event('session', { session: this.host.summaryJSON(this) }));
      const news = this.log.after(since);
      if (news.length) sub.send(event('entries', { gen: this.log.gen, entries: news }));
      sub.send(event('partial', { partial: this.partialSnapshot() ?? null }));
      sub.send(event('permissions', { permissions: this.pendingList() }));
    } else {
      sub.send(this.delta(opts.after ?? [], tail(opts.tail)) ?? this.snapshot(tail(opts.tail)));
    }
    return sub;
  }

  /** What follows the newest cached entry this log still has, if that is less than a snapshot. */
  private delta(after: string[], limit: number): Event | undefined {
    const anchor = after.map((u) => this.log.get(u)).find(Boolean);
    if (!anchor) return undefined;
    const entries = this.log.after(anchor.seq);
    if (entries.length > limit) return undefined;
    return event('delta', {
      gen: this.log.gen,
      anchor: anchor.uuid,
      anchorSeq: anchor.seq,
      entries,
      session: this.host.summaryJSON(this),
      partial: this.partialSnapshot() ?? null,
      permissions: this.pendingList(),
    });
  }

  private snapshot(n = SNAPSHOT_ENTRIES): Event {
    const { entries, hasMore } = this.log.tail(n);
    return event('snapshot', {
      gen: this.log.gen,
      entries,
      hasMore,
      session: this.host.summaryJSON(this),
      partial: this.partialSnapshot() ?? null,
      permissions: this.pendingList(),
    });
  }

  broadcast(ev: Event): void {
    for (const sub of [...this.subs]) sub.send(ev);
  }

  async entriesPage(before: number, limit: number, beforeUuid?: string): Promise<{ entries: Entry[]; hasMore: boolean; gen: string }> {
    await this.ensureLoaded();
    if (beforeUuid) {
      // A cached entry from an earlier log: page by identity, not by its old seq.
      const e = this.log.get(beforeUuid);
      if (!e) return { entries: [], hasMore: false, gen: this.log.gen };
      before = e.seq;
    }
    const b = before > 0 ? before : this.log.lastSeq + 1;
    return { ...this.log.before(b, limit), gen: this.log.gen };
  }

  private pendingList(): PermissionRequest[] {
    return [...this.pending.values()].map((p) => p.req);
  }

  // ------------------------------------------------------------ process

  private async ensureProcess(): Promise<Proc> {
    while (this.spawning) await this.spawning.catch(() => undefined);
    const p = this.proc;
    if (p && !(this.restart && this.state === 'idle' && this.pending.size === 0)) return p;
    this.spawning = this.spawn();
    try {
      return await this.spawning;
    } finally {
      this.spawning = undefined;
    }
  }

  private async spawn(): Promise<Proc> {
    if (this.proc) await this.closeProc(this.proc);
    this.restart = false;
    const gen = ++this.gen;
    this.state = 'starting';
    this.activity = T('starting');
    this.errMsg = '';
    this.host.markDirty(this.id);

    let options: Options;
    try {
      options = await this.host.queryOptions(this);
    } catch (err) {
      this.fail(gen, err);
      throw err;
    }
    const input = new InputQueue();
    const stderr: string[] = [];
    let q: Query;
    try {
      q = query({
        prompt: input,
        options: {
          ...options,
          canUseTool: (tool, toolInput, opts) => this.canUseTool(gen, tool, toolInput, opts),
          stderr: (d) => {
            stderr.push(d);
            if (stderr.length > 80) stderr.shift();
          },
        },
      });
    } catch (err) {
      const e = new LocalizedError(T('cannotStart', { detail: message(err) }));
      this.fail(gen, e);
      throw e;
    }
    const proc: Proc = { q, input, gen, stderr, closing: false, done: Promise.resolve() };
    this.proc = proc;
    proc.done = this.consume(proc);

    try {
      const init = await withTimeout(q.initializationResult(), 120_000, T('initTimeout'));
      if (Array.isArray(init.models)) this.host.onModels(init.models);
    } catch (err) {
      proc.closing = true;
      q.close();
      await withTimeout(proc.done, 10_000).catch(() => undefined);
      const e = new LocalizedError(T('initFailed', { detail: errorText(err), stderr: stderrHint(stderr) }));
      this.fail(gen, e);
      throw e;
    }
    if (gen === this.gen && this.state === 'starting') {
      this.state = 'idle';
      this.activity = '';
    }
    this.lastActive = Date.now();
    this.host.markDirty(this.id);
    // What the new process read; later changes not made by it came from elsewhere.
    this.ownStamp = await this.readStamp();
    void this.refreshContext();
    return proc;
  }

  private async consume(proc: Proc): Promise<void> {
    let error: unknown;
    try {
      for await (const msg of proc.q) {
        if (proc.gen === this.gen) this.handle(msg as unknown as RawMessage & Record<string, unknown>);
      }
    } catch (err) {
      error = err;
    }
    this.onExit(proc, error);
  }

  private onExit(proc: Proc, error: unknown): void {
    if (this.proc !== proc) return;
    this.proc = undefined;
    this.lastExit = Date.now();
    this.tasks.clear();
    this.cancelPending(T('processExited'));
    this.clearPartial();
    const crashed = !proc.closing && (error !== undefined || (this.state !== 'idle' && this.state !== 'error'));
    if (crashed) {
      this.state = 'error';
      const stderr = stderrHint(proc.stderr);
      this.errMsg = error ? T('crashedWithError', { error: message(error), stderr }) : T('crashed', { stderr });
      this.broadcast(event('notice', { level: 'error', text: this.errMsg }));
      this.host.log(`session ${this.id}: ${render(this.errMsg, 'en')}`);
    } else if (this.state !== 'error') {
      this.state = 'idle';
    }
    this.activity = '';
    this.host.markDirty(this.id);
    // The transcript is the source of truth once the stream is gone.
    if (this.loaded) void this.reload();
  }

  private fail(gen: number, err: unknown): void {
    if (gen !== this.gen) return;
    this.state = 'error';
    this.errMsg = errorText(err);
    this.activity = '';
    this.broadcast(event('notice', { level: 'error', text: this.errMsg }));
    this.host.markDirty(this.id);
  }

  private async closeProc(proc: Proc): Promise<void> {
    proc.closing = true;
    proc.input.end();
    proc.q.close(); // stdin EOF, a short grace period, then termination
    await withTimeout(proc.done, 15_000).catch(() => undefined);
  }

  // ------------------------------------------------------------ actions

  /**
   * Delivers a user message, starting claude if needed. While a turn is
   * running, Claude Code queues it and handles it next.
   */
  async send(text: string, images: ImageInput[] = []): Promise<void> {
    if (!text.trim() && !images.length) throw new LocalizedError(T('emptyMessage'));
    // A process only knows the conversation as it read it. If another program
    // (the desktop app, a terminal) took turns since, start over from the
    // transcript, or our next turn would branch off before theirs.
    if (this.proc && this.state === 'idle' && this.pending.size === 0 && (await this.changedElsewhere())) {
      this.host.log(`session ${this.id}: transcript changed elsewhere, restarting claude to pick it up`);
      this.restart = true;
    }
    const proc = await this.ensureProcess();
    const uuid = randomUUID();
    this.ownUuids.add(uuid);
    const content = images.length
      ? [
          ...images.map((img) => ({ type: 'image' as const, source: { type: 'base64' as const, media_type: img.mediaType, data: img.data } })),
          ...(text.trim() ? [{ type: 'text' as const, text }] : []),
        ]
      : text;
    // Claude Code keeps this uuid for the transcript entry, so our local copy
    // and the stored one stay the same entry.
    const entry = toEntry({ type: 'user', uuid, timestamp: new Date().toISOString(), message: { role: 'user', content } }, this.entryOpts);
    if (entry) this.append([entry]);
    proc.input.push({
      type: 'user',
      uuid,
      session_id: this.id,
      parent_tool_use_id: null,
      message: { role: 'user', content },
    } as SDKUserMessage);
    if (this.state === 'idle' || this.state === 'error') {
      this.state = 'running';
      this.activity = T('thinking');
    }
    this.errMsg = '';
    this.lastActive = Date.now();
    this.host.markDirty(this.id);
  }

  /** Whether someone else added to the conversation since our process last saw it. */
  private async changedElsewhere(): Promise<boolean> {
    const stamp = await this.readStamp();
    if (!stamp || stamp === this.ownStamp) return false;
    const msgs = await this.readMessages();
    const last = msgs.findLast((m) => (m.type === 'user' || m.type === 'assistant') && !m.parent_tool_use_id);
    if (last?.uuid && !this.ownUuids.has(last.uuid)) return true;
    this.ownStamp = stamp; // only our own late writes, or metadata
    return false;
  }

  /** Context window use from the live process (its last response; no API call). */
  async refreshContext(): Promise<void> {
    const p = this.proc;
    if (!p) return;
    try {
      const u = (await p.q.getContextUsage({ detail: 'summary' })) as unknown as Record<string, unknown>;
      const num = (...keys: string[]) => keys.map((k) => u[k]).find((v): v is number => typeof v === 'number');
      const percent = num('percentage');
      const tokens = num('totalTokens', 'total_tokens');
      const max = num('rawMaxTokens', 'raw_max_tokens', 'maxTokens', 'max_tokens');
      if (percent === undefined || tokens === undefined || !max) return;
      this.context = { percent, tokens, max, at: new Date().toISOString() };
      this.host.markDirty(this.id);
    } catch {
      // older CLI, or the process is going away
    }
  }

  /** Plan usage through this session's live process, if it has one. */
  async planUsage(): Promise<PlanUsage | undefined> {
    const p = this.proc;
    return p ? readPlanUsage(p.q) : undefined;
  }

  /** Records a transcript write Binary made itself (a rename or tag). */
  async noteOwnWrite(): Promise<void> {
    if (this.proc) this.ownStamp = await this.readStamp();
  }

  async interrupt(): Promise<void> {
    if (!this.proc) throw new NotLiveError();
    await this.proc.q.interrupt();
  }

  /** Running background work that isn't housekeeping. */
  get busyTasks(): number {
    let n = 0;
    for (const t of this.tasks.values()) if (!t.ambient) n++;
    return n;
  }

  async stopTask(taskId: string): Promise<boolean> {
    if (!this.proc || !this.tasks.has(taskId)) return false;
    await this.proc.q.stopTask(taskId);
    return true;
  }

  /** Ends the process; the session stays resumable. */
  async stop(): Promise<void> {
    while (this.spawning) await this.spawning.catch(() => undefined);
    if (this.proc) await this.closeProc(this.proc);
  }

  /** Pushes changed settings into a live process. Returns warnings. */
  async applyUpdate(u: SettingsUpdate, defaultMode: string): Promise<Msg[]> {
    const p = this.proc;
    if (!p) return [];
    const warnings: Msg[] = [];
    if (u.model !== undefined) {
      try {
        await p.q.setModel(u.model && u.model !== 'default' ? u.model : undefined);
      } catch (err) {
        warnings.push(T('modelSwitchFailed', { detail: message(err) }));
        this.restart = true;
      }
    }
    if (u.effort !== undefined) {
      // effortLevel in flag settings overrides the launch effort; "max" and
      // "back to default" only take effect through a fresh launch.
      if (!u.effort || u.effort === 'max') {
        this.restart = true;
      } else {
        try {
          await p.q.applyFlagSettings({ effortLevel: u.effort as 'low' | 'medium' | 'high' | 'xhigh' });
        } catch {
          this.restart = true;
        }
      }
    }
    if (u.permissionMode !== undefined) {
      const mode = u.permissionMode || defaultMode;
      try {
        await p.q.setPermissionMode(mode as PermissionMode);
        this.liveMode = mode;
      } catch (err) {
        warnings.push(T('modeSwitchFailed', { detail: message(err) }));
        this.restart = true;
      }
    }
    this.host.markDirty(this.id);
    return warnings;
  }

  /** lang is the responding client's, used for the default denial Claude reads. */
  respond(reqId: string, d: Decision, lang: Lang = DEFAULT_LANG): void {
    const p = this.pending.get(reqId);
    if (!p) throw new LocalizedError(T('permissionGone'));
    if (d.behavior === 'allow') {
      const result: PermissionResult = {
        behavior: 'allow',
        updatedInput: d.updatedInput ?? (p.req.input as Record<string, unknown>),
      };
      if (d.remember && p.req.suggestions?.length) result.updatedPermissions = p.req.suggestions;
      p.settle(result);
    } else {
      p.settle({ behavior: 'deny', message: d.message || T('deniedInBinary').render(lang), ...(d.interrupt && { interrupt: true }) });
    }
  }

  private canUseTool(
    gen: number,
    toolName: string,
    input: Record<string, unknown>,
    opts: Parameters<NonNullable<Options['canUseTool']>>[2],
  ): Promise<PermissionResult> {
    return new Promise((resolve) => {
      if (gen !== this.gen) {
        resolve({ behavior: 'deny', message: T('sessionRestarted').render(DEFAULT_LANG) });
        return;
      }
      const o = opts as typeof opts & {
        requestId?: string;
        title?: string;
        displayName?: string;
        description?: string;
        decisionReason?: string;
        blockedPath?: string;
        toolUseID?: string;
      };
      const id = o.requestId || o.toolUseID || randomUUID();
      const req: PermissionRequest = {
        id,
        toolName,
        input,
        createdAt: new Date().toISOString(),
        ...(o.displayName && { displayName: o.displayName }),
        ...(o.title && { title: o.title }),
        ...(o.description && { description: o.description }),
        ...(o.suggestions?.length && { suggestions: o.suggestions }),
        ...(o.blockedPath && { blockedPath: o.blockedPath }),
        ...(o.decisionReason && { decisionReason: o.decisionReason }),
        ...(o.toolUseID && { toolUseId: o.toolUseID }),
      };
      const settle = (r: PermissionResult) => {
        if (!this.pending.delete(id)) return;
        this.broadcast(event('permission_resolved', { id }));
        if (this.pending.size === 0 && this.state === 'waiting') this.state = 'running';
        this.host.markDirty(this.id);
        resolve(r);
      };
      this.pending.set(id, { req, settle });
      this.state = 'waiting';
      this.activity = toolLabel(toolName, input);
      this.broadcast(event('permission', { permission: req }));
      this.host.markDirty(this.id);
      o.signal.addEventListener('abort', () => settle({ behavior: 'deny', message: T('cancelled').render(DEFAULT_LANG) }), { once: true });
    });
  }

  private cancelPending(reason: Text): void {
    for (const p of [...this.pending.values()]) p.settle({ behavior: 'deny', message: reason.render(DEFAULT_LANG) });
  }

  // ------------------------------------------------------------ SDK output

  private handle(msg: RawMessage & Record<string, unknown>): void {
    this.lastActive = Date.now();
    let dirty = true;
    switch (msg.type) {
      case 'stream_event':
        dirty = this.onStreamEvent(msg);
        break;
      case 'assistant': {
        if (msg.parent_tool_use_id) return;
        if (msg.uuid) this.ownUuids.add(msg.uuid);
        this.clearPartial();
        const e = toEntry(msg);
        if (msg.message?.model && msg.message.model !== '<synthetic>') this.lastModel = msg.message.model;
        const text = firstText(msg);
        if (text) this.preview = preview(text, 140);
        if (e) {
          this.activity = activityFor(e);
          this.append([e]);
        }
        this.toRunning();
        break;
      }
      case 'user': {
        if (msg.parent_tool_use_id) return;
        if (msg.uuid) this.ownUuids.add(msg.uuid);
        const e = toEntry(msg, this.entryOpts);
        if (e?.kind === 'user') {
          this.toRunning();
          if (e.blocks?.[0]?.type === 'tool_result') this.activity = T('thinking');
        }
        if (e) this.append([e]);
        break;
      }
      case 'result': {
        const e = toEntry(msg);
        if (e) this.append([e]);
        if (msg.total_cost_usd) this.costUsd = msg.total_cost_usd;
        this.cancelPending(T('turnEnded'));
        this.clearPartial();
        this.state = 'idle';
        this.activity = '';
        this.errMsg = msg.is_error && msg.subtype !== 'error_during_execution' && msg.result ? preview(msg.result, 300) : '';
        // The transcript as our turn left it (Claude Code may finish writing just after the result).
        const gen = this.gen;
        setTimeout(() => {
          if (gen === this.gen && this.state === 'idle') void this.noteOwnWrite();
        }, 1500).unref();
        void this.refreshContext().then(() => this.host.onTurnEnd?.(this));
        break;
      }
      case 'system':
        dirty = this.onSystem(msg);
        break;
      default:
        dirty = false;
    }
    if (dirty) this.host.markDirty(this.id);
  }

  private toRunning(): void {
    if (this.state === 'idle' || this.state === 'starting' || this.state === 'error') this.state = 'running';
  }

  private onSystem(msg: RawMessage & Record<string, unknown>): boolean {
    const str = (k: string) => (typeof msg[k] === 'string' ? (msg[k] as string) : '');
    switch (msg.subtype) {
      case 'init':
        if (str('permissionMode')) this.liveMode = str('permissionMode');
        if (str('model')) this.lastModel = str('model');
        return true;
      case 'status':
        if (str('permissionMode')) this.liveMode = str('permissionMode');
        if (msg.status === 'compacting') this.activity = T('compacting');
        else if (this.activity instanceof Text && this.activity.is('compacting')) this.activity = '';
        return true;
      case 'task_summary':
        if (str('detail') && this.state !== 'idle') {
          this.activity = str('detail');
          return true;
        }
        return false;
      case 'post_turn_summary':
        if (str('status_detail')) {
          this.lastSummary = str('status_detail');
          return true;
        }
        return false;
      case 'session_state_changed':
        if (msg.state === 'running' && this.state !== 'waiting') this.state = 'running';
        else if (msg.state === 'requires_action') this.state = 'waiting';
        else if (msg.state === 'idle' && this.pending.size === 0) {
          this.state = 'idle';
          this.activity = '';
        }
        return true;
      case 'background_tasks_changed': {
        // The full set each time: replace, keeping when we first saw each one.
        const list = Array.isArray(msg.tasks) ? (msg.tasks as Record<string, unknown>[]) : [];
        const next = new Map<string, BackgroundTask>();
        for (const t of list) {
          const id = typeof t.task_id === 'string' ? t.task_id : '';
          if (!id) continue;
          const old = this.tasks.get(id);
          const task: BackgroundTask = {
            id,
            type: friendlyTaskType(String(t.task_type ?? '')),
            description: String(t.description ?? ''),
            startedAt: old?.startedAt ?? new Date().toISOString(),
          };
          if (typeof t.subagent_type === 'string') task.agentType = t.subagent_type;
          if (t.ambient === true) task.ambient = true;
          next.set(id, task);
        }
        this.tasks = next;
        return true;
      }
      case 'api_retry':
        this.activity = T('apiRetry', { attempt: msg.attempt ?? '?', max: msg.max_retries ?? '?' });
        return true;
      case 'compact_boundary':
      case 'local_command_output':
      case 'informational': {
        const e = toEntry(msg);
        if (e) this.append([e]);
        return false;
      }
    }
    return false;
  }

  // ------------------------------------------------------------ streaming

  private onStreamEvent(msg: Record<string, unknown>): boolean {
    if (msg.parent_tool_use_id) return false;
    const ev = (msg.event ?? {}) as {
      type?: string;
      index?: number;
      message?: { id?: string };
      content_block?: { type?: string; name?: string };
      delta?: { type?: string; text?: string; thinking?: string; partial_json?: string };
    };
    const changed = this.state !== 'running' && this.state !== 'waiting';
    this.toRunning();
    switch (ev.type) {
      case 'message_start':
        this.partial = { messageId: ev.message?.id ?? '', index: -1, type: 'text', size: 0 };
        this.partialText = '';
        break;
      case 'content_block_start': {
        if (!ev.content_block) break;
        const t = ev.content_block.type;
        const type = t === 'text' || t === 'thinking' ? t : 'tool_use';
        this.partial = { messageId: this.partial?.messageId ?? '', index: ev.index ?? 0, type, size: 0, ...(ev.content_block.name && { name: ev.content_block.name }) };
        this.partialText = '';
        this.activity = type === 'thinking' ? T('thinking') : type === 'text' ? T('replying') : (ev.content_block.name ?? '');
        this.schedulePartial();
        return true;
      }
      case 'content_block_delta':
        if (!this.partial || !ev.delta || ev.index !== this.partial.index) break;
        if (ev.delta.type === 'text_delta') this.partialText += ev.delta.text ?? '';
        else if (ev.delta.type === 'thinking_delta') this.partialText += ev.delta.thinking ?? '';
        else if (ev.delta.type === 'input_json_delta') this.partial.size += (ev.delta.partial_json ?? '').length;
        this.schedulePartial();
        break;
      case 'message_stop':
        this.clearPartial();
        break;
    }
    return changed;
  }

  private partialSnapshot(): PartialBlock | undefined {
    if (!this.partial || this.partial.index < 0) return undefined;
    const p = { ...this.partial };
    if (p.type !== 'tool_use') {
      p.text = this.partialText;
      p.size = this.partialText.length;
    }
    return p;
  }

  /** Throttles partial broadcasts; each event carries the whole block. */
  private schedulePartial(): void {
    if (this.partialTimer) return;
    const n = this.partialText.length;
    const delay = n > 64 * 1024 ? 600 : n > 8 * 1024 ? 250 : 80;
    this.partialTimer = setTimeout(() => {
      this.partialTimer = undefined;
      const p = this.partialSnapshot();
      if (p) this.broadcast(event('partial', { partial: p }));
    }, delay);
  }

  private clearPartial(): void {
    if (this.partialTimer) clearTimeout(this.partialTimer);
    this.partialTimer = undefined;
    if (this.partial) {
      this.partial = undefined;
      this.partialText = '';
      this.broadcast(event('partial', { partial: null }));
    }
  }
}

/** What an assistant entry is doing, for the activity line. */
function activityFor(e: Entry): Msg {
  const blocks = e.blocks ?? [];
  for (let i = blocks.length - 1; i >= 0; i--) {
    const b = blocks[i];
    if (b.type === 'tool_use') return toolLabel(b.name ?? '', b.input);
    if (b.type === 'text') return T('replying');
    if (b.type === 'thinking') return T('thinking');
  }
  return '';
}

/**
 * Claude Code's /usage data through the SDK. The method is marked experimental
 * and may be renamed; without it there is simply no plan usage to show.
 */
export async function readPlanUsage(q: Query): Promise<PlanUsage | undefined> {
  const fn = (q as unknown as Record<string, unknown>)['usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET'];
  if (typeof fn !== 'function') return undefined;
  try {
    const r = (await (fn as (o: object) => Promise<unknown>).call(q, { skipBehaviors: true })) as Record<string, unknown>;
    const limits = (r.rate_limits ?? r.rateLimits) as Record<string, { utilization?: number | null; resets_at?: string | null; resetsAt?: string | null } | null> | null;
    const windows: PlanUsage['windows'] = [];
    for (const [kind, w] of Object.entries(limits ?? {})) {
      if (!w || typeof w.utilization !== 'number') continue;
      const resets = w.resets_at ?? w.resetsAt;
      windows.push({ kind, percent: w.utilization, ...(resets && { resetsAt: resets }) });
    }
    return { available: Boolean(r.rate_limits_available ?? r.rateLimitsAvailable ?? windows.length), windows, at: new Date().toISOString() };
  } catch {
    return undefined;
  }
}

function friendlyTaskType(t: string): string {
  switch (t) {
    case 'local_bash':
      return 'shell';
    case 'local_agent':
      return 'subagent';
    case 'local_workflow':
      return 'workflow';
    case 'monitor_mcp':
    case 'monitor':
      return 'monitor';
    default:
      return t.replace(/^local_/, '') || 'task';
  }
}
