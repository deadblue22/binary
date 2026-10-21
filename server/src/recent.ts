// Folders for the project picker's recent list. Sessions often run in git
// worktrees (<repo>/.claude/worktrees/<name>, or linked worktrees elsewhere)
// and in scratch folders under the temp dir; the picker should offer the
// repository itself and leave scratch folders out. Everything here is a few
// stats and small reads per folder: no git processes.

import { readFileSync, realpathSync, statSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve, sep } from 'node:path';

/** Where scratch folders live: the OS temp dirs, and Claude desktop's scratch workspaces. */
export function tempRoots(): string[] {
  const roots = new Set(['/tmp', '/private/tmp', '/var/folders', '/private/var/folders']);
  // Claude desktop's per-session scratch folders.
  if (process.platform === 'darwin') roots.add(join(homedir(), 'Library', 'Application Support', 'Claude', 'scratch-workspaces'));
  const t = tmpdir();
  roots.add(resolve(t));
  try {
    roots.add(realpathSync(t));
  } catch {
    // keep the unresolved one
  }
  return [...roots];
}

/** Whether p is one of roots or inside one. */
export function isUnder(p: string, roots: string[]): boolean {
  return roots.some((r) => p === r || p.startsWith(r.endsWith(sep) ? r : r + sep));
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

/**
 * The main checkout for a .git file's `gitdir: <main>/.git/worktrees/<name>`;
 * undefined for anything else (submodules, bare repositories).
 */
function linkedMain(gitFile: string): string | undefined {
  let text: string;
  try {
    text = readFileSync(gitFile, 'utf8');
  } catch {
    return undefined;
  }
  const line = /^gitdir:\s*(.+?)\s*$/m.exec(text)?.[1];
  if (!line) return undefined;
  // Relative with worktree.useRelativePaths.
  const gitdir = resolve(dirname(gitFile), line);
  const common = dirname(dirname(gitdir));
  if (basename(dirname(gitdir)) !== 'worktrees' || basename(common) !== '.git') return undefined;
  return dirname(common);
}

/**
 * The folder to offer for a session's working directory: inside a git
 * worktree, its main repository. A <repo>/.claude/worktrees/<name> path maps
 * to <repo> by name alone, so worktrees removed since still count. A linked
 * worktree keeps its subfolder when the main checkout has it too.
 */
export function mainCheckout(dir: string): string {
  const marker = `${sep}.claude${sep}worktrees${sep}`;
  const i = dir.indexOf(marker);
  if (i > 0) return dir.slice(0, i);
  if (!isDir(dir)) return dir;
  // Up to the repository top: the first folder with a .git entry.
  for (let d = dir; ; ) {
    const git = join(d, '.git');
    let file: boolean | undefined;
    try {
      file = statSync(git).isFile();
    } catch {
      // not here
    }
    if (file !== undefined) {
      const main = file ? linkedMain(git) : undefined;
      if (!main || main === d || !isDir(main)) return dir;
      const sub = relative(d, dir);
      return sub && isDir(join(main, sub)) ? join(main, sub) : main;
    }
    const up = dirname(d);
    if (up === d) return dir;
    d = up;
  }
}
