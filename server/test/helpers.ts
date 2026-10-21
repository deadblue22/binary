import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig } from '../src/config.js';
import { Manager } from '../src/manager.js';
import { Store } from '../src/store.js';

/** test/fake-claude.mjs, from dist/test/ */
export const FAKE = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'test', 'fake-claude.mjs');
chmodSync(FAKE, 0o755);

export interface Harness {
  root: string;
  configDir: string;
  cwd: string;
  manager: Manager;
  launches(): string[];
  /** Replaces what `claude agents --json` reports from now on. */
  setAgents(agents: unknown[]): void;
  close(): Promise<void>;
}

/**
 * A manager wired to the fake CLI with its own CLAUDE_CONFIG_DIR. The SDK's
 * session readers use the same variable, so each harness sees only its own
 * transcripts.
 */
export async function harness(
  opts: { claudePath?: string; agents?: unknown[]; desktopDir?: string; tempDirs?: string[] } = {},
): Promise<Harness> {
  // Real path: on macOS the temp dir is behind a symlink, and Claude Code
  // names project folders after the resolved working directory.
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-test-')));
  const configDir = join(root, 'claude');
  const cwd = join(root, 'work');
  mkdirSync(join(configDir, 'projects'), { recursive: true });
  mkdirSync(cwd);
  process.env.CLAUDE_CONFIG_DIR = configDir;
  const cfg = loadConfig(join(root, 'home'));
  const store = new Store(cfg.dir);
  const env: Record<string, string> = {
    PATH: process.env.PATH ?? '',
    HOME: process.env.HOME ?? '',
    CLAUDE_CONFIG_DIR: configDir,
    FAKE_AGENTS: JSON.stringify(opts.agents ?? []),
    FAKE_AGENTS_FILE: join(root, 'agents.json'),
  };
  const manager = new Manager(cfg, store, {
    claudeBin: FAKE,
    claudeVersion: '9.9.9',
    claudePath: opts.claudePath ?? FAKE,
    env,
    desktopDir: opts.desktopDir,
    // Test folders live under the OS temp dir: only what a test names is scratch.
    tempDirs: opts.tempDirs ?? [],
    log: () => {},
  });
  await manager.start();
  return {
    root,
    configDir,
    cwd,
    manager,
    launches: () => {
      try {
        return readFileSync(join(configDir, 'launches.log'), 'utf8').trim().split('\n').filter(Boolean);
      } catch {
        return [];
      }
    },
    setAgents: (agents) => writeFileSync(join(root, 'agents.json'), JSON.stringify(agents)),
    close: () => manager.shutdown(),
  };
}

export async function waitFor(what: string, cond: () => boolean, ms = 15_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (cond()) return;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** Writes a transcript as Claude Code would, for sessions "running elsewhere". */
export function writeTranscript(configDir: string, cwd: string, id: string, lines: object[]): string {
  const dir = join(configDir, 'projects', cwd.replace(/[^a-zA-Z0-9]/g, '-'));
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${id}.jsonl`);
  writeFileSync(file, lines.map((l) => JSON.stringify(l)).join('\n') + '\n');
  return file;
}

export function transcriptLine(id: string, cwd: string, uuid: string, parent: string | null, role: 'user' | 'assistant', text: string): object {
  return {
    parentUuid: parent,
    isSidechain: false,
    userType: 'external',
    cwd,
    sessionId: id,
    version: '9.9.9',
    type: role,
    uuid,
    timestamp: new Date().toISOString(),
    message: role === 'user' ? { role, content: text } : { id: `msg_${uuid}`, model: 'fake-model', role, content: [{ type: 'text', text }] },
  };
}

/** Whether a launch line carries --name value (in either spelling). */
export function hasFlag(launch: string, name: string, value?: string): boolean {
  if (value === undefined) return launch.split(' ').some((a) => a === name || a.startsWith(name + '='));
  return launch.includes(`${name}=${value}`) || launch.includes(`${name} ${value}`);
}
