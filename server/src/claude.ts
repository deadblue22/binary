// Locating Claude Code and preparing the environment it runs in.

import { execFile } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { query, type Options, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';

const require = createRequire(import.meta.url);

/** Read startup metadata without sending a message. */
export async function probeClaude(options: Options) {
  let finish!: () => void;
  const done = new Promise<void>((resolve) => { finish = resolve; });
  const input = { async *[Symbol.asyncIterator]() { await done; } } as AsyncIterable<SDKUserMessage>;
  const q = query({ prompt: input, options });
  let timeout: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      q.initializationResult(),
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error('timeout')), 60_000).unref();
      }),
    ]);
  } finally {
    clearTimeout(timeout);
    finish();
    q.close();
  }
}

/** Variables that configure claude itself rather than describe a host session. */
const KEPT_BY_DEFAULT = new Set([
  'CLAUDE_CODE_USE_BEDROCK',
  'CLAUDE_CODE_USE_VERTEX',
  'CLAUDE_CODE_USE_FOUNDRY',
  'CLAUDE_CODE_OAUTH_TOKEN',
  'CLAUDE_CODE_MAX_OUTPUT_TOKENS',
  'CLAUDE_CODE_SKIP_BEDROCK_AUTH',
  'CLAUDE_CODE_SKIP_VERTEX_AUTH',
  'CLAUDE_CODE_GIT_BASH_PATH',
]);

/**
 * Drops variables a parent Claude Code session injects into its children. If
 * binaryd is started from inside a Claude session, passing these through would
 * make every managed session believe it is a nested child of it.
 */
export function cleanEnv(base: NodeJS.ProcessEnv, keep: string[] = []): Record<string, string> {
  const extra = new Set(keep);
  const out: Record<string, string> = {};
  for (const [name, value] of Object.entries(base)) {
    if (value === undefined) continue;
    if (!extra.has(name) && !KEPT_BY_DEFAULT.has(name)) {
      if (['CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_EFFORT', 'AI_AGENT'].includes(name)) continue;
      if (/^(CLAUDE_CODE_|CLAUDE_AGENT_SDK_|CLAUDE_PREVIEW_)/.test(name)) continue;
    }
    out[name] = value;
  }
  return out;
}

/** The Claude Code binary the SDK ships for this platform, if installed. */
export function bundledClaude(): { path: string; version: string } | undefined {
  const candidates = [`${process.platform}-${process.arch}`, `${process.platform}-${process.arch}-musl`];
  for (const c of candidates) {
    try {
      const pkg = require.resolve(`@anthropic-ai/claude-agent-sdk-${c}/package.json`);
      const bin = join(dirname(pkg), process.platform === 'win32' ? 'claude.exe' : 'claude');
      if (existsSync(bin)) {
        // manifest.json is not in the package's exports map; find it next to the entry point.
        const manifest = join(dirname(require.resolve('@anthropic-ai/claude-agent-sdk')), 'manifest.json');
        const version = (JSON.parse(readFileSync(manifest, 'utf8')) as { version?: string }).version ?? '';
        return { path: bin, version };
      }
    } catch {
      // not installed for this platform
    }
  }
  return undefined;
}

export function run(bin: string, args: string[], env: Record<string, string>, timeoutMs = 15_000): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(bin, args, { env, timeout: timeoutMs, maxBuffer: 16 << 20 }, (err, stdout) => {
      if (err) reject(err);
      else resolve(stdout);
    });
  });
}

export async function claudeVersion(bin: string, env: Record<string, string>): Promise<string> {
  try {
    return (await run(bin, ['--version'], env)).trim().split(/\s+/)[0] ?? '';
  } catch {
    return '';
  }
}

/** A session Claude Code registers as running (as `claude agents --json` lists it). */
export interface ActiveAgent {
  pid: number;
  cwd: string;
  kind: string; // interactive | background
  sessionId: string;
  name?: string;
  status: string; // idle | busy
  startedAt?: number;
}

/** pid:procStart → whether that process is still the one that wrote the record. */
const verified = new Map<string, boolean>();

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === 'EPERM';
  }
}

/** The start stamp Claude Code records for pid, in the same form (undefined: can't tell). */
async function procStart(pid: number): Promise<string | undefined> {
  if (process.platform === 'linux') {
    try {
      // Field 22 (starttime), counted after the parenthesised command name.
      const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
      return stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19];
    } catch {
      return undefined;
    }
  }
  return new Promise((ok) => {
    execFile('ps', ['-o', 'lstart=', '-p', String(pid)], { env: { ...process.env, LC_ALL: 'C', TZ: 'UTC' }, timeout: 5_000 }, (err, out) =>
      ok(err ? undefined : out.trim().replace(/\s+/g, ' ') || undefined));
  });
}

/**
 * Sessions Claude Code reports as running anywhere on this machine: the
 * records each claude process keeps in <config>/sessions (what `claude agents
 * --json` reads), whose process is still running. Read directly, so polling
 * starts no claude process.
 */
export async function activeAgents(env: Record<string, string>): Promise<ActiveAgent[]> {
  const dir = join(env.CLAUDE_CONFIG_DIR || process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'sessions');
  let names: string[];
  try {
    names = readdirSync(dir).filter((n) => n.endsWith('.json'));
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return [];
    throw err;
  }
  const out: ActiveAgent[] = [];
  const seen = new Set<string>();
  for (const name of names) {
    let r: Record<string, unknown>;
    try {
      r = JSON.parse(readFileSync(join(dir, name), 'utf8')) as Record<string, unknown>;
    } catch {
      continue; // being written, or not a record
    }
    const pid = r.pid;
    if (typeof pid !== 'number' || typeof r.sessionId !== 'string' || !alive(pid)) continue;
    // A reused pid: the record's process ended without removing it.
    if (typeof r.procStart === 'string' && r.procStart) {
      const key = `${pid}:${r.procStart}`;
      seen.add(key);
      let ok = verified.get(key);
      if (ok === undefined) {
        const now = await procStart(pid);
        ok = now === undefined || now === r.procStart.trim().replace(/\s+/g, ' ');
        verified.set(key, ok);
      }
      if (!ok) continue;
    }
    out.push({
      pid,
      cwd: typeof r.cwd === 'string' ? r.cwd : '',
      kind: typeof r.kind === 'string' ? r.kind : 'interactive',
      sessionId: r.sessionId,
      ...(typeof r.name === 'string' && r.name && { name: r.name }),
      // The record says what keeps it busy (busy, shell, …); the CLI reports busy.
      status: r.status === undefined || r.status === 'idle' ? 'idle' : 'busy',
      ...(typeof r.startedAt === 'number' && { startedAt: r.startedAt }),
    });
  }
  for (const key of verified.keys()) if (!seen.has(key)) verified.delete(key);
  return out;
}
