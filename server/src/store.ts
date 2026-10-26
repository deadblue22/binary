// Persists the little state Binary owns itself: per-session settings chosen
// in Binary, how clients organize the list, and the model list last reported
// by Claude Code. Transcripts stay where Claude Code keeps them. Same file
// format as the Go server.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { writeFileAtomic } from './config.js';

export interface SessionRecord {
  id: string;
  cwd?: string;
  title?: string;
  model?: string;
  effort?: string;
  permissionMode?: string;
  /** The desktop app's mode when permissionMode was chosen here; once it differs, the desktop's newer choice wins. */
  desktopModeAtChoice?: string;
  /** Group tag chosen before the transcript existed (written once it does). */
  tag?: string;
  /** Session this one was started from in Binary. */
  parentId?: string;
  /** Extra environment variables for this session's claude process. */
  env?: Record<string, string>;
  /** Branch the session was started on, and the worktree created for it. */
  branch?: string;
  worktree?: string;
  /** Effort Claude Code last applied (reported by its Stop hook), for showing what "default" means. */
  appliedEffort?: string;
  /** Context window use after the latest turn Binary ran. */
  context?: { percent: number; tokens: number; max: number; at: string };
  createdAt: string;
  /** True for sessions started from Binary. */
  created?: boolean;
}

/**
 * How clients organize this server's sessions beyond groups (which are
 * session tags): pinned and archived sessions, the order of groups and the
 * projects (folders here with settings for new sessions), kept here so every
 * client shows the same.
 */
export interface Layout {
  pinned: string[];
  archived: string[];
  groupOrder: string[];
  /** Kept as clients send them: objects with at least a string `id`. */
  projects: Record<string, unknown>[];
  /** When each field was last set, by the setting client's clock (ms); 0 = never. */
  at: LayoutStamps;
}

export interface LayoutStamps {
  pinned: number;
  archived: number;
  groupOrder: number;
  projects: number;
}

export const LAYOUT_FIELDS = ['pinned', 'archived', 'groupOrder'] as const;

interface StoreFile {
  sessions: Record<string, SessionRecord>;
  models?: unknown[];
  layout?: Layout;
}

export class Store {
  private readonly path: string;
  private data: StoreFile = { sessions: {} };
  private timer?: NodeJS.Timeout;

  constructor(dir: string) {
    this.path = join(dir, 'sessions.json');
    try {
      const parsed = JSON.parse(readFileSync(this.path, 'utf8')) as StoreFile;
      this.data = { sessions: parsed.sessions ?? {}, models: parsed.models, layout: parsed.layout };
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
    }
  }

  get(id: string): SessionRecord | undefined {
    const r = this.data.sessions[id];
    return r ? { ...r } : undefined;
  }

  all(): SessionRecord[] {
    return Object.values(this.data.sessions).map((r) => ({ ...r }));
  }

  /** Applies fn to the record for id (creating it) and schedules a save. */
  update(id: string, fn: (r: SessionRecord) => void): SessionRecord {
    let r = this.data.sessions[id];
    if (!r) {
      r = { id, createdAt: new Date().toISOString() };
      this.data.sessions[id] = r;
    }
    fn(r);
    this.schedule();
    return { ...r };
  }

  layout(): Layout {
    const l = this.data.layout;
    return {
      pinned: [...(l?.pinned ?? [])],
      archived: [...(l?.archived ?? [])],
      groupOrder: [...(l?.groupOrder ?? [])],
      projects: (l?.projects ?? []).map((p) => ({ ...p })),
      at: { pinned: 0, archived: 0, groupOrder: 0, projects: 0, ...l?.at },
    };
  }

  setLayout(l: Layout): void {
    this.data.layout = l;
    this.schedule();
  }

  models(): unknown[] | undefined {
    return this.data.models;
  }

  setModels(models: unknown[]): void {
    if (JSON.stringify(models) === JSON.stringify(this.data.models)) return;
    this.data.models = models;
    this.schedule();
  }

  private schedule(): void {
    if (this.timer) return;
    this.timer = setTimeout(() => this.flush(), 500);
  }

  flush(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    writeFileAtomic(this.path, JSON.stringify(this.data, null, 2) + '\n', 0o600);
  }
}
