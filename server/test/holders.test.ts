import assert from 'node:assert/strict';
import { test } from 'node:test';
import { holderOf, type ProcessTable } from '../src/holders.js';

const table = (rows: [number, number, string][]): ProcessTable => new Map(rows.map(([pid, ppid, args]) => [pid, { ppid, args }]));

test('which program holds an external claude process', () => {
  const t = table([
    // Claude desktop on macOS: its own claude under Application Support.
    [10, 9, '/Users/u/Library/Application Support/Claude/claude-code/2.1.304/claude --output-format stream-json'],
    [9, 8, '/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup'],
    [8, 1, '/Applications/Claude.app/Contents/MacOS/Claude'],
    // Claude desktop over SSH: its remote server starts the CLI.
    [20, 19, '/home/u/.claude/remote/ccd-cli/2.1.299-686c67ec1014 --resume x'],
    [19, 1, '/home/u/.claude/remote/srv/abc123/server'],
    // tmux, a terminal app, an IDE, ssh, and nothing recognisable.
    [30, 29, 'claude'],
    [29, 1, 'tmux new-session -d -s bots -c /Users/u/ops'],
    [40, 41, 'claude --resume abc'],
    [41, 42, '-zsh'],
    [42, 1, '/Applications/iTerm.app/Contents/MacOS/iTerm2'],
    [50, 51, 'claude'],
    [51, 1, '/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)'],
    [60, 61, 'claude'],
    [61, 62, '-bash'],
    [62, 1, 'sshd: u@pts/0'],
    [70, 71, 'claude'],
    [71, 1, '/usr/local/bin/node /opt/runner.js'],
    // A cycle must not hang.
    [80, 81, 'claude'],
    [81, 80, 'bash'],
  ]);
  assert.equal(holderOf(10, t), 'desktop');
  assert.equal(holderOf(20, t), 'desktop');
  assert.equal(holderOf(30, t), 'tmux');
  assert.equal(holderOf(40, t), 'terminal');
  assert.equal(holderOf(50, t), 'ide');
  assert.equal(holderOf(60, t), 'terminal');
  assert.equal(holderOf(70, t), 'other');
  assert.equal(holderOf(80, t), 'other');
  assert.equal(holderOf(999, t), 'other');
});
