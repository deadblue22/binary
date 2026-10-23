// Waiting until a restart would interrupt nothing: no session binaryd runs
// has a turn in progress, background work or messages waiting to go out.
// Asks the running server through its own API, so it works whatever version
// that server is (a deploy waits with the new code on the old server).

import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { splitHostPort, type Config } from './config.js';

interface Listed {
  id: string;
  title?: string;
  state?: string;
  live?: boolean;
  tasks?: { type: string; description: string; ambient?: boolean }[];
  queued?: unknown[];
}

/** What keeps a session from being restarted now, or '' when nothing does. */
export function busyReason(s: Listed): string {
  if (!s.live) return '';
  if (s.state === 'running' || s.state === 'starting') return 'turn running';
  if (s.state === 'waiting') return 'waiting for approval';
  const tasks = (s.tasks ?? []).filter((t) => !t.ambient);
  if (tasks.length) return `${tasks.length} background task${tasks.length > 1 ? 's' : ''} (${tasks.map((t) => t.description || t.type).join('; ')})`;
  if (s.queued?.length) return 'messages queued';
  return '';
}

function get(cfg: Config, path: string): Promise<unknown> {
  const { host, port } = splitHostPort(cfg.data.listen);
  const local = host === '0.0.0.0' || host === '::' || !host ? '127.0.0.1' : host;
  const tls = Boolean(cfg.data.tlsCert && cfg.data.tlsKey);
  return new Promise((resolve, reject) => {
    const req = (tls ? httpsRequest : httpRequest)(
      { host: local, port, path, headers: { Authorization: `Bearer ${cfg.data.token}` }, timeout: 10_000, ...(tls && { rejectUnauthorized: false }) },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (d: string) => (body += d));
        res.on('end', () => {
          if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode}`));
          try {
            resolve(JSON.parse(body));
          } catch (err) {
            reject(err);
          }
        });
      },
    );
    req.on('timeout', () => req.destroy(new Error('timed out')));
    req.on('error', reject);
    req.end();
  });
}

/**
 * Resolves true once two checks in a row find nothing busy (one turn ending
 * and a queued message starting the next can look idle for a moment), false
 * after timeoutMs. A server that doesn't answer has nothing to interrupt.
 */
export async function waitIdle(cfg: Config, opts: { timeoutMs?: number; everyMs?: number; log?: (msg: string) => void } = {}): Promise<boolean> {
  const log = opts.log ?? ((m: string) => console.log(m));
  const every = opts.everyMs ?? 3_000;
  const deadline = opts.timeoutMs ? Date.now() + opts.timeoutMs : Infinity;
  let quiet = 0;
  let last = '';
  for (;;) {
    let busy: string[] = [];
    try {
      const { sessions } = (await get(cfg, '/api/v1/sessions')) as { sessions: Listed[] };
      busy = sessions.map((s) => [s, busyReason(s)] as const).filter(([, r]) => r).map(([s, r]) => `  ${s.title || s.id.slice(0, 8)}: ${r}`);
    } catch (err) {
      if (!last) log(`server not answering (${(err as Error).message}); nothing to wait for`);
      return true;
    }
    quiet = busy.length ? 0 : quiet + 1;
    if (quiet >= 2) return true;
    const now = busy.join('\n');
    if (busy.length && now !== last) log(`waiting for ${busy.length} session${busy.length > 1 ? 's' : ''} to be idle:\n${now}`);
    last = now || last;
    if (Date.now() >= deadline) return false;
    await new Promise((r) => setTimeout(r, quiet ? Math.min(every, 1_500) : every));
  }
}
