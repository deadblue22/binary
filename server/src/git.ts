// Git operations for starting a session on a branch or in a fresh worktree.
// Worktrees follow the layout Claude Code's own tools use:
// <repo>/.claude/worktrees/<name> on branch claude/<name>, with
// .claude/worktrees/ excluded locally (.git/info/exclude).

import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { LocalizedError, T } from './i18n.js';

function git(dir: string, args: string[], timeoutMs = 20_000): Promise<string> {
  return new Promise((ok, fail) => {
    execFile('git', ['-C', dir, ...args], { timeout: timeoutMs, maxBuffer: 8 << 20 }, (err, stdout, stderr) => {
      if (err) fail(new Error((stderr || err.message).trim()));
      else ok(stdout);
    });
  });
}

const WORKTREE_BRANCH_PREFIX = 'claude/';
const BRANCH_LIMIT = 10;

export interface GitInfo {
  isRepo: boolean;
  /** Top of the working tree that contains the folder. */
  root?: string;
  /** Checked-out branch; absent when HEAD is detached. */
  current?: string;
  /**
   * The few most recently committed local branches, for a short picker,
   * plus the main branch (origin's HEAD, else main or master) when older;
   * claude/* branches made for session worktrees are left out.
   */
  branches: string[];
  /** Uncommitted changes to tracked files. */
  dirty?: boolean;
  worktrees?: { path: string; branch?: string }[];
}

export async function gitInfo(dir: string): Promise<GitInfo> {
  let root: string;
  try {
    root = (await git(dir, ['rev-parse', '--show-toplevel'])).trim();
  } catch {
    return { isRepo: false, branches: [] };
  }
  const [current, local, origin, status, worktrees] = await Promise.all([
    git(dir, ['symbolic-ref', '--quiet', '--short', 'HEAD']).then((s) => s.trim() || undefined, () => undefined),
    git(dir, ['for-each-ref', '--sort=-committerdate', '--format=%(refname:short)', 'refs/heads']).then(
      (s) => s.split('\n').filter((b) => b && !b.startsWith(WORKTREE_BRANCH_PREFIX)),
      () => [] as string[],
    ),
    git(dir, ['symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD']).then(
      (s) => s.trim().replace(/^origin\//, '') || undefined,
      () => undefined,
    ),
    git(dir, ['status', '--porcelain', '--untracked-files=no'], 10_000).then((s) => s.trim() !== '', () => undefined),
    git(dir, ['worktree', 'list', '--porcelain']).then(parseWorktrees, () => undefined),
  ]);
  // The main branch stays in the list however long ago it was committed to.
  const main = [origin, 'main', 'master'].find((b) => b && local.includes(b));
  const branches = local.slice(0, BRANCH_LIMIT);
  if (main && !branches.includes(main)) branches.push(main);
  return {
    isRepo: true,
    root,
    ...(current && { current }),
    branches,
    ...(status !== undefined && { dirty: status }),
    ...(worktrees && { worktrees }),
  };
}

function parseWorktrees(out: string): { path: string; branch?: string }[] {
  const list: { path: string; branch?: string }[] = [];
  for (const block of out.split('\n\n')) {
    const path = /^worktree (.+)$/m.exec(block)?.[1];
    if (!path) continue;
    const branch = /^branch refs\/heads\/(.+)$/m.exec(block)?.[1];
    list.push({ path, ...(branch && { branch }) });
  }
  return list;
}

/** A worktree name from free text: ASCII slug plus a short random suffix. */
export function worktreeName(hint: string): string {
  const slug = hint
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .split('-')
    .filter(Boolean)
    .slice(0, 6)
    .join('-')
    .slice(0, 40)
    .replace(/-+$/, '');
  return `${slug || 'session'}-${randomBytes(3).toString('hex')}`;
}

function checkName(name: string): string {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$/.test(name)) throw new LocalizedError(T('worktreeNameInvalid', { name }));
  return name;
}

/**
 * Creates <repo>/.claude/worktrees/<name> on a new branch claude/<name>,
 * starting from base (default: the folder's HEAD). Returns the folder to run
 * in: the same subfolder of the new worktree that dir was of its repository.
 */
export async function createWorktree(dir: string, name: string, base?: string): Promise<{ cwd: string; branch: string; path: string }> {
  const info = await gitInfo(dir);
  if (!info.isRepo || !info.root) throw new LocalizedError(T('notGitRepo', { path: dir }));
  checkName(name);
  // Worktrees hang off the main checkout even when dir is itself a worktree.
  const commonDir = resolve(dir, (await git(dir, ['rev-parse', '--git-common-dir'])).trim());
  const mainRoot = dirname(commonDir);
  const path = join(mainRoot, '.claude', 'worktrees', name);
  const branch = `${WORKTREE_BRANCH_PREFIX}${name}`;
  if (existsSync(path)) throw new LocalizedError(T('worktreeExists', { path }));

  const exclude = join(commonDir, 'info', 'exclude');
  try {
    const current = existsSync(exclude) ? readFileSync(exclude, 'utf8') : '';
    if (!current.split('\n').some((l) => l.trim() === '.claude/worktrees/')) {
      mkdirSync(dirname(exclude), { recursive: true });
      appendFileSync(exclude, `${current && !current.endsWith('\n') ? '\n' : ''}.claude/worktrees/\n`);
    }
  } catch {
    // Not fatal: the worktree still works, it just shows up as untracked.
  }
  mkdirSync(dirname(path), { recursive: true });
  try {
    await git(mainRoot, ['worktree', 'add', '-b', branch, path, base || 'HEAD'], 120_000);
  } catch (err) {
    throw new LocalizedError(T('gitFailed', { detail: (err as Error).message }));
  }
  return { cwd: join(path, relative(info.root, dir)), branch, path };
}

/** Checks out branch in dir, refusing when tracked files have changes. */
export async function switchBranch(dir: string, branch: string): Promise<void> {
  const info = await gitInfo(dir);
  if (!info.isRepo) throw new LocalizedError(T('notGitRepo', { path: dir }));
  if (info.current === branch) return;
  if (info.dirty) throw new LocalizedError(T('worktreeDirty', { branch: info.current ?? 'HEAD' }));
  try {
    await git(dir, ['switch', branch], 60_000);
  } catch (err) {
    throw new LocalizedError(T('gitFailed', { detail: (err as Error).message }));
  }
}
