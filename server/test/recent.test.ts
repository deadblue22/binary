import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, realpathSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { isUnder, mainCheckout, tempRoots } from '../src/recent.js';
import { harness, transcriptLine, writeTranscript } from './helpers.js';

/** <root>/main with a pkg/ subfolder, and a linked worktree at <root>/main-wt/issue-1. */
function repoWithWorktree(root: string): { main: string; wt: string } {
  const main = join(root, 'main');
  const wt = join(root, 'main-wt', 'issue-1');
  mkdirSync(join(main, 'pkg'), { recursive: true });
  const g = (...args: string[]) => execFileSync('git', ['-C', main, ...args], { stdio: 'pipe' });
  g('init', '-q', '-b', 'main');
  g('config', 'user.email', 't@example.com');
  g('config', 'user.name', 'T');
  writeFileSync(join(main, 'pkg', 'a.txt'), 'a');
  g('add', '.');
  g('commit', '-q', '-m', 'one');
  g('worktree', 'add', '-q', '-b', 'issue-1', wt);
  mkdirSync(join(wt, 'only-here'));
  return { main, wt };
}

test('temp roots', () => {
  const roots = tempRoots();
  assert.ok(isUnder(join(tmpdir(), 'binaryd-x'), roots));
  assert.ok(isUnder(join(realpathSync(tmpdir()), 'binaryd-x'), roots));
  assert.ok(isUnder('/private/tmp/claude-501/-Users-x-dev/5b25/scratchpad/e2e/proj', roots));
  assert.ok(isUnder('/tmp', roots));
  assert.ok(!isUnder('/tmpfoo/x', roots));
  assert.ok(!isUnder('/var/folders-x/y', roots));
  assert.ok(!isUnder('/Users/someone/dev/repo', roots));
});

test('worktrees map to their main checkout', () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-recent-')));
  const { main, wt } = repoWithWorktree(root);
  assert.equal(mainCheckout(wt), main);
  // The same subfolder when the main checkout has it, else the top.
  assert.equal(mainCheckout(join(wt, 'pkg')), join(main, 'pkg'));
  assert.equal(mainCheckout(join(wt, 'only-here')), main);
  // By name alone, even once the worktree is gone.
  assert.equal(mainCheckout(join(main, '.claude', 'worktrees', 'issue-653-resolution-883c5c')), main);
  assert.equal(mainCheckout(join(main, '.claude', 'worktrees', 'x', 'pkg')), main);
  // Main checkouts, plain folders and submodule-style .git files stay as they are.
  assert.equal(mainCheckout(join(main, 'pkg')), join(main, 'pkg'));
  assert.equal(mainCheckout(root), root);
  const sub = join(root, 'sub');
  mkdirSync(sub);
  writeFileSync(join(sub, '.git'), 'gitdir: ../main/.git/modules/sub\n');
  assert.equal(mainCheckout(sub), sub);
});

test('recent folders: worktrees collapse into the repo, scratch and missing folders are left out', async () => {
  const scratch = realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-scratch-')));
  const h = await harness({ tempDirs: [scratch] });
  try {
    const { main, wt } = repoWithWorktree(h.root);
    const other = join(h.root, 'other');
    mkdirSync(other);
    const proj = join(scratch, 'e2e', 'proj');
    mkdirSync(proj, { recursive: true });
    // Newest first.
    const cwds = [
      join(main, '.claude', 'worktrees', 'design-concrete-plan-e44096'),
      proj,
      other,
      join(wt, 'pkg'),
      wt,
      join(h.root, 'gone'),
      main,
    ];
    const now = Date.now() / 1000;
    cwds.forEach((cwd, i) => {
      const id = randomUUID();
      const file = writeTranscript(h.configDir, cwd, id, [transcriptLine(id, cwd, randomUUID(), null, 'user', `in ${cwd}`)]);
      utimesSync(file, now - 60 * (i + 1), now - 60 * (i + 1));
    });
    await h.manager.refreshList();
    assert.deepEqual(h.manager.recentDirs(40), [main, other, join(main, 'pkg')]);
    assert.deepEqual(h.manager.recentDirs(2), [main, other]);
  } finally {
    await h.close();
  }
});
