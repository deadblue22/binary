// How long SDK reads block the event loop (max single stall), for
// getSessionMessages on one session and listSessions over all of them.
// Usage: node bench/loop-lag.mjs <session id>
import { getSessionMessages, listSessions, getSessionInfo } from '@anthropic-ai/claude-agent-sdk';
import { monitorEventLoopDelay } from 'node:perf_hooks';

async function measure(label, fn) {
  const h = monitorEventLoopDelay({ resolution: 5 });
  // A ticker that notices stalls directly, too.
  let worst = 0, last = performance.now();
  const t = setInterval(() => { const now = performance.now(); worst = Math.max(worst, now - last - 5); last = now; }, 5);
  h.enable();
  const t0 = performance.now();
  const r = await fn();
  const total = performance.now() - t0;
  h.disable(); clearInterval(t);
  console.log(`${label}: total ${total.toFixed(0)}ms, worst stall ${worst.toFixed(0)}ms, p99 lag ${(h.percentile(99) / 1e6).toFixed(0)}ms (${r})`);
}

const id = process.argv[2];
for (let i = 0; i < 3; i++) {
  await measure('getSessionMessages', async () => (await getSessionMessages(id)).length + ' msgs');
  await measure('getSessionInfo', async () => ((await getSessionInfo(id))?.fileSize ?? 0) + ' bytes');
  await measure('listSessions', async () => (await listSessions()).length + ' sessions');
}
