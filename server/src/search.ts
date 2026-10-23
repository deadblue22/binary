// Full-text search over what was said in every stored session: the user's
// messages and Claude's replies, as the transcript shows them (tool calls,
// their output and thinking are left out; they are most of a transcript's
// bytes and little of what people look for).
//
// The text is a small part of the transcripts (tens of MB against GBs), so a
// worker thread keeps all of it in memory and reads only what was appended to
// a transcript since the last search. The first build parses every transcript
// once, off the main thread.

import { closeSync, openSync, readdirSync, readSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { isMainThread, parentPort, Worker } from 'node:worker_threads';
import { stripContext, toEntry, type RawMessage } from './normalize.js';

export interface SearchSnippet {
  /** The entry the text is in: the transcript row to show. */
  uuid: string;
  role: 'user' | 'assistant';
  time?: string;
  /** Text around the first match, whitespace flattened. */
  text: string;
}

export interface SearchResult {
  id: string;
  /** Messages that match. */
  hits: number;
  /** When the latest matching message was written. */
  latest?: string;
  /** The latest matches first. */
  snippets: SearchSnippet[];
}

interface Doc {
  uuid: string;
  role: 'user' | 'assistant';
  time?: string;
  text: string;
  lower: string;
}

interface FileIndex {
  id: string;
  size: number;
  mtimeMs: number;
  /** Bytes read so far: up to the end of the last complete line. */
  offset: number;
  docs: Doc[];
}

const SNIPPETS = 3;
const CHUNK = 4 << 20;
const BEFORE = 40;
const AFTER = 120;

function projectsDir(): string {
  return join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects');
}

/** Splits a query into lowercased terms; a message matches when it has them all. */
export function terms(q: string): string[] {
  return [...new Set(q.toLowerCase().split(/\s+/).filter(Boolean))];
}

export function snippet(text: string, lower: string, term: string): string {
  const at = Math.max(0, lower.indexOf(term));
  let start = Math.max(0, at - BEFORE);
  let end = Math.min(text.length, at + term.length + AFTER);
  // Don't cut a surrogate pair in half.
  if (start > 0 && /[\uDC00-\uDFFF]/.test(text[start])) start--;
  if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1])) end++;
  const flat = text.slice(start, end).split(/\s+/).filter(Boolean).join(' ');
  return (start > 0 ? '…' : '') + flat + (end < text.length ? '…' : '');
}

/** All the text of a message toEntry kept (only text blocks are left by then). */
function fullText(m: RawMessage): string {
  const c = m.message?.content;
  const parts = typeof c === 'string' ? [c] : Array.isArray(c) ? (c as { text?: string }[]).map((b) => b.text ?? '') : [];
  return parts
    .map((p) => (m.type === 'user' ? stripContext(p) : p))
    .filter((p) => p.trim())
    .join('\n\n');
}

/** The searchable messages in transcript lines. */
export function docsFrom(lines: string[]): Doc[] {
  const out: Doc[] = [];
  for (const line of lines) {
    // Cheap test before parsing: most lines are tool traffic or bookkeeping.
    if (!line.includes('"type":"user"') && !line.includes('"type":"assistant"')) continue;
    let m: RawMessage & { isSidechain?: boolean };
    try {
      m = JSON.parse(line);
    } catch {
      continue;
    }
    if ((m.type !== 'user' && m.type !== 'assistant') || m.isSidechain || !m.uuid) continue;
    // Drop tool traffic before converting: it isn't searched, and it's the bulk.
    const c = m.message?.content;
    if (Array.isArray(c)) {
      const kept = (c as { type?: string }[]).filter((b) => b?.type === 'text');
      if (!kept.length) continue;
      m = { ...m, message: { ...m.message, content: kept } };
    }
    const e = toEntry(m);
    if (!e || (e.kind !== 'user' && e.kind !== 'assistant')) continue;
    const shown = (e.blocks ?? []).filter((b) => b.type === 'text' && typeof b.text === 'string');
    // The transcript cuts long messages; search all of them.
    const text = shown.some((b) => b.truncated) ? fullText(m) : shown.map((b) => b.text as string).join('\n\n');
    if (!text.trim()) continue;
    out.push({ uuid: e.uuid, role: e.kind, time: m.timestamp, text, lower: text.toLowerCase() });
  }
  return out;
}

/** The searchable text of every transcript, kept current on each search. */
export class TextIndex {
  private files = new Map<string, FileIndex>();

  /** Reads transcripts that are new or changed since the last refresh. */
  refresh(root = projectsDir()): void {
    const seen = new Set<string>();
    let dirs: string[] = [];
    try {
      dirs = readdirSync(root);
    } catch {
      dirs = [];
    }
    for (const d of dirs) {
      let names: string[];
      try {
        names = readdirSync(join(root, d));
      } catch {
        continue;
      }
      for (const name of names) {
        if (!name.endsWith('.jsonl')) continue;
        const path = join(root, d, name);
        seen.add(path);
        try {
          this.update(path, name.slice(0, -'.jsonl'.length));
        } catch {
          // Unreadable or removed mid-scan: try again next time.
        }
      }
    }
    for (const path of this.files.keys()) if (!seen.has(path)) this.files.delete(path);
  }

  private update(path: string, id: string): void {
    const st = statSync(path);
    let f = this.files.get(path);
    if (f && f.size === st.size && f.mtimeMs === st.mtimeMs) return;
    // Transcripts only grow; anything else means it was rewritten.
    if (!f || st.size < f.offset) {
      f = { id, size: 0, mtimeMs: 0, offset: 0, docs: [] };
      this.files.set(path, f);
    }
    const fd = openSync(path, 'r');
    try {
      // In chunks: some transcripts are hundreds of MB, mostly tool output.
      let size = CHUNK;
      while (f.offset < st.size) {
        const buf = Buffer.allocUnsafe(Math.min(size, st.size - f.offset));
        const n = readSync(fd, buf, 0, buf.length, f.offset);
        if (n <= 0) break;
        const end = buf.lastIndexOf(0x0a, n - 1) + 1;
        if (end === 0) {
          // A line still being written waits for next time; a longer one gets a bigger read.
          if (f.offset + n >= st.size) break;
          size *= 2;
          continue;
        }
        for (const d of docsFrom(buf.subarray(0, end).toString('utf8').split('\n'))) f.docs.push(d);
        f.offset += end;
        size = CHUNK;
      }
    } finally {
      closeSync(fd);
    }
    f.size = st.size;
    f.mtimeMs = st.mtimeMs;
  }

  search(q: string, limit: number): SearchResult[] {
    const ts = terms(q);
    if (!ts.length) return [];
    const byId = new Map<string, SearchResult>();
    for (const f of this.files.values()) {
      let r: SearchResult | undefined;
      for (let i = f.docs.length - 1; i >= 0; i--) {
        const d = f.docs[i];
        if (!ts.every((t) => d.lower.includes(t))) continue;
        if (!r) {
          // A session copied into another folder keeps its id: one result.
          r = byId.get(f.id) ?? { id: f.id, hits: 0, snippets: [] };
          byId.set(f.id, r);
        }
        r.hits++;
        if (d.time && (!r.latest || d.time > r.latest)) r.latest = d.time;
        if (r.snippets.length < SNIPPETS) {
          r.snippets.push({ uuid: d.uuid, role: d.role, time: d.time, text: snippet(d.text, d.lower, ts[0]) });
        }
      }
    }
    return [...byId.values()].sort((a, b) => (b.latest ?? '').localeCompare(a.latest ?? '')).slice(0, limit);
  }
}

type Request = { id: number; q?: string; limit?: number };
type Reply = { id: number; results?: SearchResult[]; error?: string };

if (!isMainThread && parentPort) {
  const port = parentPort;
  const index = new TextIndex();
  port.on('message', (r: Request) => {
    try {
      index.refresh();
      port.postMessage({ id: r.id, results: r.q ? index.search(r.q, r.limit ?? 100) : [] } satisfies Reply);
    } catch (err) {
      port.postMessage({ id: r.id, error: err instanceof Error ? err.message : String(err) } satisfies Reply);
    }
  });
}

/** Searches session text from a worker thread (the main thread when one can't start). */
export class SessionSearch {
  private worker?: Worker;
  private next = 1;
  private waiting = new Map<number, { ok: (v: SearchResult[]) => void; fail: (e: Error) => void }>();
  private broken = false;
  private closed = false;
  private local?: TextIndex;

  /** Builds the index ahead of the first search. */
  warm(): void {
    void this.search('').catch(() => {});
  }

  async search(q: string, limit = 100): Promise<SearchResult[]> {
    const w = this.ensureWorker();
    if (!w) {
      this.local ??= new TextIndex();
      this.local.refresh();
      return q ? this.local.search(q, limit) : [];
    }
    const id = this.next++;
    return new Promise((ok, fail) => {
      this.waiting.set(id, { ok, fail });
      w.postMessage({ id, q, limit } satisfies Request);
    });
  }

  close(): void {
    this.closed = true;
    void this.worker?.terminate();
    this.worker = undefined;
  }

  private ensureWorker(): Worker | undefined {
    if (this.closed) throw new Error('search closed');
    if (this.worker || this.broken) return this.worker;
    try {
      const w = new Worker(new URL(import.meta.url));
      w.unref();
      w.on('message', (r: Reply) => {
        const p = this.waiting.get(r.id);
        if (!p) return;
        this.waiting.delete(r.id);
        if (r.error !== undefined) p.fail(new Error(r.error));
        else p.ok(r.results ?? []);
      });
      const down = (err: Error) => {
        this.broken = true;
        this.worker = undefined;
        for (const p of this.waiting.values()) p.fail(err);
        this.waiting.clear();
      };
      w.on('error', down);
      w.on('exit', (code) => {
        if (this.worker === w) down(new Error(`search worker exited (${code})`));
      });
      this.worker = w;
    } catch {
      this.broken = true;
    }
    return this.worker;
  }
}
