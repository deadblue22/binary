// Locating Claude Code and preparing the environment it runs in.

import { execFile } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);

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

/** A session listed by `claude agents --json`. */
export interface ActiveAgent {
  pid: number;
  cwd: string;
  kind: string; // interactive | background
  sessionId: string;
  name?: string;
  status: string; // idle | busy
  startedAt?: number;
}

/** Sessions Claude Code reports as running anywhere on this machine. */
export async function activeAgents(bin: string, env: Record<string, string>): Promise<ActiveAgent[]> {
  const out = await run(bin, ['agents', '--json'], env, 10_000);
  const parsed = JSON.parse(out) as unknown;
  return Array.isArray(parsed) ? (parsed as ActiveAgent[]).filter((a) => a && typeof a.sessionId === 'string') : [];
}
