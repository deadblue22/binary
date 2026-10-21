// Hits /healthz every 20ms for a while and prints slow responses, optionally
// with a viewer subscribed to one session (which makes the server poll it).
// Usage: node bench/probe-stalls.mjs [base URL] [seconds] [session id]
// The token is read from ~/.binary/server.json, or from $BINARY_TOKEN_FILE.
import { readFileSync } from 'node:fs';
const [base = 'http://127.0.0.1:7350', seconds = '20', id] = process.argv.slice(2);
const token = JSON.parse(readFileSync(process.env.BINARY_TOKEN_FILE || process.env.HOME + '/.binary/server.json', 'utf8')).token;
const ctl = new AbortController();
if (id) {
  fetch(`${base}/api/v1/sessions/${id}/events`, { headers: { Authorization: `Bearer ${token}` }, signal: ctl.signal })
    .then(async (r) => {
      const reader = r.body.getReader();
      while (!(await reader.read()).done);
    })
    .catch(() => {});
}
const t0 = performance.now();
const slow = [];
let n = 0;
while (performance.now() - t0 < Number(seconds) * 1000) {
  const s = performance.now();
  await fetch(`${base}/healthz`).then((r) => r.text());
  const d = performance.now() - s;
  n++;
  if (d > 30) slow.push([((s - t0) / 1000).toFixed(1), d.toFixed(0)]);
  await new Promise((r) => setTimeout(r, 20));
}
ctl.abort();
console.log(`${n} requests, ${slow.length} over 30ms`);
console.log(slow.map(([t, d]) => `${t}s:${d}ms`).join('  '));
