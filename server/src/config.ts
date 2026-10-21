// Loads and persists binaryd's configuration ($BINARY_HOME/server.json,
// default ~/.binary). Created on first run with a random access token.

import { randomBytes } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync, chmodSync } from 'node:fs';
import { homedir, hostname } from 'node:os';
import { dirname, join, resolve, basename } from 'node:path';

export const DEFAULT_LISTEN = '127.0.0.1:7350';

export interface ConfigFile {
  /** Name shown in clients; defaults to the hostname. */
  name?: string;
  /** Listen address, e.g. "127.0.0.1:7350" or "0.0.0.0:7350". */
  listen: string;
  /** Token required as "Authorization: Bearer <token>". */
  token: string;
  /** Claude Code executable for the SDK (default: the one bundled with the SDK). */
  claudePath?: string;
  /** Stop claude processes idle this long; 0 keeps them until shutdown. */
  idleTimeoutMinutes: number;
  /** Let clients pick the bypassPermissions mode. */
  allowBypassPermissions: boolean;
  /** Permission mode for sessions that have none configured. */
  defaultPermissionMode?: string;
  /** HTTPS when both are set. */
  tlsCert?: string;
  tlsKey?: string;
  /** Extra CLAUDE_CODE_* variables to pass through to claude. */
  keepEnv?: string[];
  /**
   * Nest sessions the Claude desktop app started from other sessions under
   * their parent, read from the app's session records (default true).
   */
  desktopLinks?: boolean;
  /** Where those records are (default: the desktop app's folder on macOS). */
  desktopSessionsDir?: string;
}

export class Config {
  constructor(public readonly dir: string, public data: ConfigFile) {}

  get path(): string {
    return join(this.dir, 'server.json');
  }

  get displayName(): string {
    return this.data.name || hostname();
  }

  save(): void {
    writeFileAtomic(this.path, JSON.stringify(this.data, null, 2) + '\n', 0o600);
  }
}

export function homeDir(override?: string): string {
  if (override) return resolve(override);
  if (process.env.BINARY_HOME) return resolve(process.env.BINARY_HOME);
  return join(homedir(), '.binary');
}

export function newToken(): string {
  return 'bin_' + randomBytes(24).toString('base64url');
}

export function loadConfig(dir: string): Config {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const path = join(dir, 'server.json');
  let raw: string | undefined;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
  }
  if (raw === undefined) {
    const cfg = new Config(dir, {
      listen: DEFAULT_LISTEN,
      token: newToken(),
      idleTimeoutMinutes: 30,
      allowBypassPermissions: true,
      defaultPermissionMode: 'default',
    });
    cfg.save();
    return cfg;
  }
  let data: ConfigFile;
  try {
    data = JSON.parse(raw);
  } catch (err) {
    throw new Error(`parse ${path}: ${(err as Error).message}`);
  }
  data.listen ||= DEFAULT_LISTEN;
  data.idleTimeoutMinutes ??= 30;
  data.allowBypassPermissions ??= true;
  const cfg = new Config(dir, data);
  if (!data.token) {
    data.token = newToken();
    cfg.save();
  }
  return cfg;
}

/** Writes via a temp file and rename so readers never see a partial file. */
export function writeFileAtomic(path: string, data: string, mode: number): void {
  const tmp = join(dirname(path), `.tmp-${basename(path)}-${process.pid}`);
  writeFileSync(tmp, data, { mode });
  chmodSync(tmp, mode);
  renameSync(tmp, path);
}

/** Splits "host:port" (IPv6 hosts in brackets). */
export function splitHostPort(listen: string): { host: string; port: number } {
  const m = /^\[?([^\]]*)\]?:(\d+)$/.exec(listen);
  if (!m) throw new Error(`invalid listen address: ${listen}`);
  return { host: m[1] || '0.0.0.0', port: Number(m[2]) };
}
