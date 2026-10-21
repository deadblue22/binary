// Which program holds a session that runs outside binaryd. `claude agents
// --json` reports the claude process (pid, busy/idle) but not what started
// it; the process's ancestors tell: the Claude desktop app keeps a process
// for every session it has open (locally, or over SSH through its remote
// server), and tmux, terminals and IDEs show up as an ancestor too.

import { execFile } from 'node:child_process';

export type Holder = 'desktop' | 'tmux' | 'terminal' | 'ide' | 'other';

// Matched against each process's command line, nearest first; first match wins.
const RULES: [Holder, RegExp][] = [
  ['desktop', /\/Claude\.app\/|Application Support\/Claude\/|\/\.claude\/remote\//],
  ['ide', /\/(Visual Studio Code|Cursor|Windsurf|Zed)[^/]*\.app\/|\.vscode-server\/|\.cursor-server\/|\/JetBrains\/|Code Helper/],
  ['tmux', /(^|\/)(tmux|screen)(:|\s|$)/],
  ['terminal', /\/(Terminal|iTerm2?|Ghostty|WezTerm|Alacritty|kitty|Warp)\.app\/|(^|\/)sshd(:|\s|$)/],
];

export type ProcessTable = Map<number, { ppid: number; args: string }>;

/** pid → parent and command line, for every process (`ps`, macOS and Linux). */
export function processTable(): Promise<ProcessTable> {
  return new Promise((ok) => {
    execFile('ps', ['-A', '-o', 'pid=,ppid=,args='], { maxBuffer: 16 << 20, timeout: 10_000 }, (err, stdout) => {
      const t: ProcessTable = new Map();
      if (!err) {
        for (const line of stdout.split('\n')) {
          const m = /^\s*(\d+)\s+(\d+)\s?(.*)$/.exec(line);
          if (m) t.set(Number(m[1]), { ppid: Number(m[2]), args: m[3] });
        }
      }
      ok(t);
    });
  });
}

/** The program holding pid, from it and its ancestors. */
export function holderOf(pid: number, table: ProcessTable): Holder {
  const seen = new Set<number>();
  for (let p = pid; p > 1 && !seen.has(p); ) {
    seen.add(p);
    const proc = table.get(p);
    if (!proc) break;
    for (const [holder, re] of RULES) if (re.test(proc.args)) return holder;
    p = proc.ppid;
  }
  return 'other';
}
