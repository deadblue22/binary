// Measures the SDK's session-reading functions on real transcripts.
// Usage: node bench/session-read.mjs [N largest files to test]
import { listSessions, getSessionInfo, getSessionMessages } from '@anthropic-ai/claude-agent-sdk';
import { readdirSync, statSync } from 'node:fs';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';

const projects = join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude'), 'projects');
const files = [];
for (const d of readdirSync(projects)) {
  const dir = join(projects, d);
  let names;
  try { names = readdirSync(dir); } catch { continue; }
  for (const n of names) {
    if (!n.endsWith('.jsonl') || n.startsWith('agent-')) continue;
    const p = join(dir, n);
    files.push({ id: basename(n, '.jsonl'), path: p, size: statSync(p).size });
  }
}
files.sort((a, b) => b.size - a.size);
const mb = (n) => (n / 1048576).toFixed(1) + 'MB';
const ms = (t) => (performance.now() - t).toFixed(0) + 'ms';
const heap = () => mb(process.memoryUsage().rss);

console.log(`${files.length} transcripts, total ${mb(files.reduce((s, f) => s + f.size, 0))}, rss ${heap()}`);

let t = performance.now();
const all = await listSessions();
console.log(`listSessions(): ${all.length} sessions in ${ms(t)}, rss ${heap()}`);
t = performance.now();
const page = await listSessions({ limit: 50 });
console.log(`listSessions({limit:50}): ${page.length} in ${ms(t)}`);

const n = Number(process.argv[2] ?? 4);
const picks = [...files.slice(0, n), files[Math.floor(files.length / 2)], files[files.length - 1]];
for (const f of picks) {
  t = performance.now();
  const info = await getSessionInfo(f.id);
  const infoT = ms(t);
  t = performance.now();
  const msgs = await getSessionMessages(f.id, { includeSystemMessages: true });
  const allT = ms(t);
  t = performance.now();
  const tail = await getSessionMessages(f.id, { includeSystemMessages: true, offset: Math.max(0, msgs.length - 50), limit: 50 });
  const tailT = ms(t);
  console.log(`${mb(f.size).padStart(8)}  info ${infoT.padStart(6)}  all ${String(msgs.length).padStart(5)} msgs ${allT.padStart(7)}  last50 ${tailT.padStart(7)}  rss ${heap()}  ${info?.summary?.slice(0, 30) ?? '-'}`);
}
