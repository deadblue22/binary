// Event fan-out and the per-session ordered entry log.

import { randomUUID } from 'node:crypto';
import { encode, type Lang } from './i18n.js';
import type { Entry } from './normalize.js';

/** One server-sent event, serialized once per language that receives it. */
export class Event {
  private cache = new Map<Lang, string>();

  constructor(
    readonly type: string,
    readonly payload: Record<string, unknown>,
  ) {}

  data(lang: Lang): string {
    let d = this.cache.get(lang);
    if (d === undefined) {
      d = encode({ ...this.payload, type: this.type }, lang);
      this.cache.set(lang, d);
    }
    return d;
  }
}

export function event(type: string, fields: Record<string, unknown> = {}): Event {
  return new Event(type, fields);
}

/** Receives an event's JSON; returns false when it can't keep up. */
export type Sink = (type: string, data: string) => boolean;

/**
 * A viewer of a session or of the session list, in one language. A sink that
 * can't keep up closes itself and the client reconnects with since/gen.
 */
export class Subscriber {
  closed = false;
  constructor(
    private readonly sink: Sink,
    private readonly onClose: () => void,
    readonly lang: Lang,
  ) {}

  send(ev: Event): boolean {
    if (this.closed) return false;
    if (!this.sink(ev.type, ev.data(this.lang))) {
      this.close();
      return false;
    }
    return true;
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.onClose();
  }
}

/** Ordered, uuid-deduplicated entries with monotonically increasing seq. */
export class Log {
  readonly gen = randomUUID().slice(0, 8);
  entries: Entry[] = [];
  private byUuid = new Map<string, number>();
  private nextSeq = 1;

  has(uuid: string): boolean {
    return this.byUuid.has(uuid);
  }

  /** Adds e unless an entry with the same uuid exists; returns the stored entry. */
  append(e: Entry): Entry | undefined {
    if (this.byUuid.has(e.uuid)) return undefined;
    const stored = { ...e, seq: this.nextSeq++ };
    this.byUuid.set(stored.uuid, this.entries.length);
    this.entries.push(stored);
    return stored;
  }

  /** The stored entry with this uuid. */
  get(uuid: string): Entry | undefined {
    const i = this.byUuid.get(uuid);
    return i === undefined ? undefined : this.entries[i];
  }

  get lastSeq(): number {
    return this.nextSeq - 1;
  }

  tail(n: number): { entries: Entry[]; hasMore: boolean } {
    if (this.entries.length <= n) return { entries: [...this.entries], hasMore: false };
    return { entries: this.entries.slice(-n), hasMore: true };
  }

  after(since: number): Entry[] {
    return this.entries.filter((e) => e.seq > since);
  }

  before(before: number, n: number): { entries: Entry[]; hasMore: boolean } {
    let end = this.entries.length;
    while (end > 0 && this.entries[end - 1].seq >= before) end--;
    const start = Math.max(0, end - n);
    return { entries: this.entries.slice(start, end), hasMore: start > 0 };
  }
}
