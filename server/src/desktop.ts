// What the Claude desktop app knows about sessions it started: the parent
// session one was started from (Claude Code itself records no parent), and
// the SSH host of a session that runs on another machine (the desktop app
// mirrors its transcript here, so it lists like a local one). This is
// read-only and best-effort: the records are the app's own files (not a
// documented interface), so any change in their layout just means no links.
// Only six fields are used: the record's sessionId, its cliSessionId (= the
// Claude Code session id), spawnedFrom.sessionId, sshConfig.sshHost,
// permissionMode and cwd (the mode and folder the desktop app runs it in).

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export function defaultDesktopDir(): string | undefined {
  if (process.platform === 'darwin') return join(homedir(), 'Library', 'Application Support', 'Claude', 'claude-code-sessions');
  return undefined;
}

interface Rec {
  mtime: number;
  local: string;
  cli?: string;
  parentLocal?: string;
  sshHost?: string;
  mode?: string;
  cwd?: string;
}

export class DesktopLinks {
  private files = new Map<string, Rec>();
  private parents = new Map<string, string>();
  private hosts = new Map<string, string>();
  private modes = new Map<string, string>();
  private cwds = new Map<string, string>();

  constructor(private readonly dir: string | undefined) {}

  /** Parent Claude Code session id of a session, if the desktop app started it from one. */
  parentOf(cliId: string): string | undefined {
    return this.parents.get(cliId);
  }

  /** SSH host of a session the desktop app runs on another machine. */
  sshHostOf(cliId: string): string | undefined {
    return this.hosts.get(cliId);
  }

  /** Permission mode the desktop app has set for a session. */
  modeOf(cliId: string): string | undefined {
    return this.modes.get(cliId);
  }

  /** Folder the desktop app starts a session in (a session that later cd'd elsewhere keeps it). */
  cwdOf(cliId: string): string | undefined {
    return this.cwds.get(cliId);
  }

  /** Re-reads changed records; returns the session ids whose parent or host changed. */
  refresh(): string[] {
    if (!this.dir) return [];
    const seen = new Set<string>();
    let changed = false;
    for (const path of this.list(this.dir, 0)) {
      seen.add(path);
      let mtime: number;
      try {
        mtime = statSync(path).mtimeMs;
      } catch {
        continue;
      }
      if (this.files.get(path)?.mtime === mtime) continue;
      const rec = this.read(path, mtime);
      if (rec) {
        this.files.set(path, rec);
        changed = true;
      }
    }
    for (const path of [...this.files.keys()]) {
      if (!seen.has(path)) {
        this.files.delete(path);
        changed = true;
      }
    }
    if (!changed) return [];

    const cliOf = new Map<string, string>();
    for (const r of this.files.values()) if (r.cli) cliOf.set(r.local, r.cli);
    const parents = new Map<string, string>();
    const hosts = new Map<string, string>();
    const modes = new Map<string, string>();
    const cwds = new Map<string, string>();
    for (const r of this.files.values()) {
      if (!r.cli) continue;
      const parent = r.parentLocal && cliOf.get(r.parentLocal);
      if (parent && parent !== r.cli) parents.set(r.cli, parent);
      if (r.sshHost) hosts.set(r.cli, r.sshHost);
      if (r.mode) modes.set(r.cli, r.mode);
      if (r.cwd) cwds.set(r.cli, r.cwd);
    }
    const diff = new Set([...changedKeys(parents, this.parents), ...changedKeys(hosts, this.hosts), ...changedKeys(modes, this.modes), ...changedKeys(cwds, this.cwds)]);
    this.parents = parents;
    this.hosts = hosts;
    this.modes = modes;
    this.cwds = cwds;
    return [...diff];
  }

  /** local_*.json under <dir>/<org>/<account>/ (a little depth tolerance). */
  private list(dir: string, depth: number): string[] {
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch {
      return [];
    }
    const out: string[] = [];
    for (const name of names) {
      const p = join(dir, name);
      if (name.startsWith('local_') && name.endsWith('.json')) out.push(p);
      else if (depth < 3 && !name.includes('.')) out.push(...this.list(p, depth + 1));
    }
    return out;
  }

  private read(path: string, mtime: number): Rec | undefined {
    try {
      const j = JSON.parse(readFileSync(path, 'utf8')) as {
        sessionId?: unknown;
        cliSessionId?: unknown;
        spawnedFrom?: { sessionId?: unknown };
        sshConfig?: { sshHost?: unknown };
        permissionMode?: unknown;
        cwd?: unknown;
      };
      const host = j.sshConfig?.sshHost;
      const local = typeof j.sessionId === 'string' ? j.sessionId : (path.split('/').pop() ?? '').replace(/\.json$/, '');
      return {
        mtime,
        local,
        ...(typeof j.cliSessionId === 'string' && { cli: j.cliSessionId }),
        ...(typeof j.spawnedFrom?.sessionId === 'string' && { parentLocal: j.spawnedFrom.sessionId }),
        ...(typeof host === 'string' && host.trim() && { sshHost: host.trim() }),
        ...(typeof j.permissionMode === 'string' && j.permissionMode && { mode: j.permissionMode }),
        ...(typeof j.cwd === 'string' && j.cwd && { cwd: j.cwd }),
      };
    } catch {
      return undefined; // being written, or not the shape we know
    }
  }
}

function changedKeys(a: Map<string, string>, b: Map<string, string>): string[] {
  return [...new Set([...a.keys(), ...b.keys()])].filter((k) => a.get(k) !== b.get(k));
}
