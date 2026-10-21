// The SDK's listSessions reads the head and tail of every transcript and
// parses them synchronously: with a few hundred sessions that holds the event
// loop for 100–200ms, every refresh. Running the same call in a worker thread
// keeps requests and event streams responsive; the result is a few hundred
// small records, cheap to pass back.

import { listSessions, type SDKSessionInfo } from '@anthropic-ai/claude-agent-sdk';
import { isMainThread, parentPort, Worker } from 'node:worker_threads';

type Reply = { id: number; infos?: SDKSessionInfo[]; error?: string };

if (!isMainThread && parentPort) {
  const port = parentPort;
  port.on('message', (id: number) => {
    listSessions().then(
      (infos) => port.postMessage({ id, infos } satisfies Reply),
      (err: unknown) => port.postMessage({ id, error: err instanceof Error ? err.message : String(err) } satisfies Reply),
    );
  });
}

export class SessionLister {
  private worker?: Worker;
  private next = 1;
  private waiting = new Map<number, { ok: (v: SDKSessionInfo[]) => void; fail: (e: Error) => void }>();
  private broken = false;

  /** All stored sessions, read off the main thread when possible. */
  list(): Promise<SDKSessionInfo[]> {
    const w = this.ensureWorker();
    if (!w) return listSessions();
    const id = this.next++;
    return new Promise((ok, fail) => {
      this.waiting.set(id, { ok, fail });
      w.postMessage(id);
    });
  }

  close(): void {
    void this.worker?.terminate();
    this.worker = undefined;
  }

  private ensureWorker(): Worker | undefined {
    if (this.worker || this.broken) return this.worker;
    try {
      // The worker gets a copy of the environment as it is now (CLAUDE_CONFIG_DIR included).
      const w = new Worker(new URL(import.meta.url));
      w.unref();
      w.on('message', (r: Reply) => {
        const p = this.waiting.get(r.id);
        if (!p) return;
        this.waiting.delete(r.id);
        if (r.error !== undefined) p.fail(new Error(r.error));
        else p.ok(r.infos ?? []);
      });
      const down = (err: Error) => {
        // Fall back to the main thread from now on rather than keep failing.
        this.broken = true;
        this.worker = undefined;
        for (const p of this.waiting.values()) p.fail(err);
        this.waiting.clear();
      };
      w.on('error', down);
      w.on('exit', (code) => {
        if (this.worker === w) down(new Error(`session list worker exited (${code})`));
      });
      this.worker = w;
    } catch {
      this.broken = true;
    }
    return this.worker;
  }
}
