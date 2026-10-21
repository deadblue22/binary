import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { createWorktree, gitInfo, switchBranch, worktreeName } from '../src/git.js';

function repo(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-git-')));
  const g = (...args: string[]) => execFileSync('git', ['-C', dir, ...args], { stdio: 'pipe' });
  g('init', '-q', '-b', 'main');
  g('config', 'user.email', 't@example.com');
  g('config', 'user.name', 'T');
  mkdirSync(join(dir, 'pkg'));
  writeFileSync(join(dir, 'pkg', 'a.txt'), 'a');
  g('add', '.');
  g('commit', '-q', '-m', 'one');
  g('branch', 'feature');
  return dir;
}

test('gitInfo', async () => {
  const dir = repo();
  const info = await gitInfo(join(dir, 'pkg'));
  assert.equal(info.isRepo, true);
  assert.equal(info.root, dir);
  assert.equal(info.current, 'main');
  assert.deepEqual([...info.branches].sort(), ['feature', 'main']);
  assert.equal(info.dirty, false);
  assert.equal((await gitInfo(tmpdir())).isRepo, false);
});

test('worktree on a base branch, keeping the subfolder', async () => {
  const dir = repo();
  const wt = await createWorktree(join(dir, 'pkg'), 'try-it-abc123', 'feature');
  assert.equal(wt.path, join(dir, '.claude', 'worktrees', 'try-it-abc123'));
  assert.equal(wt.branch, 'claude/try-it-abc123');
  assert.equal(wt.cwd, join(wt.path, 'pkg'));
  assert.ok(existsSync(join(wt.cwd, 'a.txt')));
  assert.equal((await gitInfo(wt.cwd)).current, 'claude/try-it-abc123');
  assert.ok(readFileSync(join(dir, '.git', 'info', 'exclude'), 'utf8').includes('.claude/worktrees/'));
  // The new worktree isn't untracked noise in the main checkout.
  assert.equal(execFileSync('git', ['-C', dir, 'status', '--porcelain']).toString().trim(), '');
  await assert.rejects(createWorktree(dir, 'try-it-abc123'), /already exists/);
  await assert.rejects(createWorktree(dir, '../escape'), /Invalid/);
});

test('switching branches refuses uncommitted changes', async () => {
  const dir = repo();
  await switchBranch(dir, 'feature');
  assert.equal((await gitInfo(dir)).current, 'feature');
  writeFileSync(join(dir, 'pkg', 'a.txt'), 'changed');
  await assert.rejects(switchBranch(dir, 'main'), /uncommitted/);
  await assert.rejects(switchBranch(dir, 'nope'), /uncommitted|git/);
});

test('worktreeName', () => {
  assert.match(worktreeName('Fix the Login Bug, please!'), /^fix-the-login-bug-please-[0-9a-f]{6}$/);
  assert.match(worktreeName('Исправить вход'), /^session-[0-9a-f]{6}$/);
});
