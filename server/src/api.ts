// HTTP API: JSON REST endpoints for actions and server-sent events for live
// updates. Wire-compatible with the original Go server. Human-readable text
// in responses and events follows the client's Accept-Language (zh or en).

import { timingSafeEqual } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { homedir, hostname } from 'node:os';
import { dirname, extname, join, resolve } from 'node:path';
import { constants as zlibConstants, createGzip, gzipSync } from 'node:zlib';
import { encode, errorText, LocalizedError, parseLang, render, T, type Lang, type Msg } from './i18n.js';
import type { Sink, Subscriber } from './log.js';
import { gitInfo } from './git.js';
import { EFFORT_LEVELS, expandPath, HttpError, type Manager } from './manager.js';
import { checkImages, NotLiveError, type Decision } from './session.js';

export interface ApiOptions {
  manager: Manager;
  token: string;
  name: string;
  version: string;
  claudePath: string;
  claudeVersion: string;
  log: (msg: string) => void;
}

interface Ctx {
  req: IncomingMessage;
  res: ServerResponse;
  params: Record<string, string>;
  url: URL;
  lang: Lang;
}

/** A JSON reply; undefined when the handler streamed its own response. */
type Reply = { status: number; body: unknown } | undefined;
type Handler = (ctx: Ctx) => Promise<Reply> | Reply;

/** A failure carrying any message (localizable or verbatim) and a status. */
class ApiFailure extends Error {
  constructor(
    readonly status: number,
    readonly msg: Msg,
  ) {
    super(typeof msg === 'string' ? msg : msg.toString());
  }
}

const NODE_ARCH: Record<string, string> = { x64: 'amd64', ia32: '386' };

const MAX_FILE = 50 << 20;

const MIME: Record<string, string> = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.bmp': 'image/bmp', '.tiff': 'image/tiff', '.heic': 'image/heic',
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json',
  '.pdf': 'application/pdf', '.txt': 'text/plain; charset=utf-8', '.md': 'text/markdown; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8', '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.otf': 'font/otf',
  '.mp4': 'video/mp4', '.webm': 'video/webm', '.mp3': 'audio/mpeg', '.wav': 'audio/wav',
};
const mimeType = (path: string) => MIME[extname(path).toLowerCase()] ?? 'application/octet-stream';

const ok = (body: unknown = { ok: true }, status = 200): Reply => ({ status, body });

/** Whether the client takes gzip; transcripts are JSON and shrink 3–5×, which matters on slow links. */
function acceptsGzip(req: IncomingMessage): boolean {
  return /\bgzip\b/.test(String(req.headers['accept-encoding'] ?? ''));
}

function send(res: ServerResponse, status: number, body: unknown, lang: Lang, gzip = false): void {
  const data = encode(body, lang);
  const raw = Buffer.from(data);
  const zipped = gzip && raw.length > 1024;
  const out = zipped ? gzipSync(raw, { level: 6 }) : raw;
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': out.length,
    'Content-Language': lang,
    Vary: 'Accept-Encoding',
    ...(zipped && { 'Content-Encoding': 'gzip' }),
  });
  res.end(out);
}

function fail(res: ServerResponse, status: number, msg: Msg, lang: Lang): void {
  send(res, status, { error: render(msg, lang) }, lang);
}

async function readJSON<V>(req: IncomingMessage): Promise<V> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    // Messages may carry several base64 images.
    if (size > 64 << 20) throw new HttpError(413, T('bodyTooLarge'));
    chunks.push(chunk as Buffer);
  }
  const text = Buffer.concat(chunks).toString('utf8').trim();
  if (!text) return {} as V;
  try {
    return JSON.parse(text) as V;
  } catch (err) {
    throw new HttpError(400, T('badRequest', { detail: (err as Error).message }));
  }
}

export function createHandler(o: ApiOptions): (req: IncomingMessage, res: ServerResponse) => void {
  const m = o.manager;
  const routes: [string, RegExp, string[], Handler][] = [];
  const route = (method: string, pattern: string, handler: Handler) => {
    const names: string[] = [];
    const re = new RegExp('^' + pattern.replace(/\{(\w+)\}/g, (_, n) => (names.push(n), '([^/]+)')) + '$');
    routes.push([method, re, names, handler]);
  };
  const sessionOr404 = (id: string) => {
    const s = m.session(id);
    if (!s) throw new HttpError(404, T('sessionNotFound'));
    return s;
  };

  route('GET', '/api/v1/info', () =>
    ok({
      name: o.name,
      hostname: hostname(),
      os: process.platform,
      arch: NODE_ARCH[process.arch] ?? process.arch,
      version: o.version,
      claudePath: o.claudePath,
      claudeVersion: o.claudeVersion,
      home: homedir(),
      models: m.models(),
      effortLevels: EFFORT_LEVELS,
      permissionModes: m.permissionModes(),
      defaultPermissionMode: m.defaultMode,
      ...(m.cachedUsage() && { usage: m.cachedUsage() }),
    }),
  );

  route('GET', '/api/v1/sessions', () => ok({ sessions: m.summaries() }));

  // Full-text search of what was said in each session (see search.ts).
  route('GET', '/api/v1/search', async ({ url }) => {
    const q = (url.searchParams.get('q') ?? '').trim();
    let limit = Number(url.searchParams.get('limit')) || 100;
    if (limit <= 0 || limit > 500) limit = 100;
    return ok({ results: q ? await m.search(q, limit) : [] });
  });

  route('POST', '/api/v1/sessions', async ({ req }) => ok(await m.create(await readJSON(req)), 201));

  route('GET', '/api/v1/sessions/{id}', ({ params }) => {
    const sum = m.summary(params.id);
    if (!sum) throw new HttpError(404, T('sessionNotFound'));
    return ok(sum);
  });

  route('PATCH', '/api/v1/sessions/{id}', async ({ req, params }) => ok(await m.update(params.id, await readJSON(req))));

  route('GET', '/api/v1/sessions/{id}/entries', async ({ params, url }) => {
    const s = sessionOr404(params.id);
    const before = Number(url.searchParams.get('before')) || 0;
    const beforeUuid = url.searchParams.get('beforeUuid') || undefined;
    let limit = Number(url.searchParams.get('limit')) || 300;
    if (limit <= 0 || limit > 2000) limit = 300;
    return ok(await s.entriesPage(before, limit, beforeUuid));
  });

  route('POST', '/api/v1/sessions/{id}/messages', async ({ req, params }) => {
    const s = sessionOr404(params.id);
    const body = await readJSON<{ text?: string; images?: unknown }>(req);
    const images = checkImages(body.images);
    const text = body.text ?? '';
    if (!text.trim() && !images.length) throw new HttpError(400, T('emptyMessage'));
    const why = s.live ? undefined : m.cannotRun(s.id);
    if (why) throw new HttpError(409, why);
    // Another program is mid-turn on it, or binaryd is restarting: hold the
    // message until that turn ends or the next binaryd starts.
    if (m.closing || m.busyElsewhere(s.id)) return ok({ ok: true, queued: m.enqueue(s.id, text, images) }, 202);
    try {
      await s.send(text, images);
    } catch (err) {
      throw new ApiFailure(502, errorText(err));
    }
    return ok({ ok: true }, 202);
  });

  route('DELETE', '/api/v1/sessions/{id}/queue/{qid}', ({ params }) => {
    m.cancelQueued(params.id, params.qid);
    return ok({ ok: true });
  });

  route('POST', '/api/v1/sessions/{id}/tasks/{taskId}/stop', async ({ params }) => {
    await m.stopTask(params.id, params.taskId);
    return ok({ ok: true });
  });

  // Continue in a copy instead of writing to a session another program holds.
  route('POST', '/api/v1/sessions/{id}/fork', async ({ req, params }) =>
    ok(await m.fork(params.id, await readJSON<{ title?: string; text?: string; images?: unknown }>(req)), 201),
  );

  // Images from user messages, by the key on their image block.
  route('GET', '/api/v1/sessions/{id}/images/{key}', async ({ res, params }) => {
    const s = sessionOr404(params.id);
    await s.ensureLoaded();
    const img = s.image(params.key);
    if (!img) throw new HttpError(404, T('imageNotFound'));
    res.writeHead(200, {
      'Content-Type': img.mediaType,
      'Content-Length': img.bytes.length,
      // Keys are derived from the message uuid: the image never changes.
      'Cache-Control': 'private, max-age=604800, immutable',
    });
    res.end(img.bytes);
    return undefined;
  });

  // A file the conversation points at (an image, an HTML page and what it
  // loads), so a client can show it even when the server is another machine.
  // Relative paths are taken from the session's folder.
  route('GET', '/api/v1/sessions/{id}/file', async ({ res, params, url }) => {
    sessionOr404(params.id);
    const raw = url.searchParams.get('path') ?? '';
    if (!raw.trim()) throw new HttpError(400, T('pathEmpty'));
    const base = m.cwdFor(params.id) || homedir();
    const path = raw.startsWith('~') ? expandPath(raw) : resolve(base, raw);
    let st;
    try {
      st = statSync(path);
    } catch {
      throw new HttpError(404, T('fileNotFound', { path }));
    }
    if (!st.isFile()) throw new HttpError(404, T('fileNotFound', { path }));
    if (st.size > MAX_FILE) throw new HttpError(413, T('fileTooLarge', { max: MAX_FILE >> 20 }));
    res.writeHead(200, {
      'Content-Type': mimeType(path),
      'Content-Length': st.size,
      'Cache-Control': 'no-cache',
    });
    res.end(readFileSync(path));
    return undefined;
  });

  route('POST', '/api/v1/sessions/{id}/interrupt', async ({ params }) => {
    const s = sessionOr404(params.id);
    try {
      await s.interrupt();
    } catch (err) {
      throw new ApiFailure(err instanceof NotLiveError ? 409 : 502, errorText(err));
    }
    return ok();
  });

  route('POST', '/api/v1/sessions/{id}/stop', async ({ params }) => {
    await sessionOr404(params.id).stop();
    return ok();
  });

  route('POST', '/api/v1/sessions/{id}/permissions/{reqId}', async ({ req, params, lang }) => {
    const s = sessionOr404(params.id);
    const d = await readJSON<Decision>(req);
    if (d.behavior !== 'allow' && d.behavior !== 'deny') throw new HttpError(400, T('behaviorInvalid'));
    try {
      s.respond(params.reqId, d, lang);
    } catch (err) {
      throw new ApiFailure(409, errorText(err));
    }
    return ok();
  });

  route('GET', '/api/v1/sessions/{id}/subagents', async ({ params }) => ok({ subagents: await m.subagents(params.id) }));

  route('GET', '/api/v1/sessions/{id}/subagents/{agentId}/entries', async ({ params }) =>
    ok({ entries: await m.subagentEntries(params.id, params.agentId) }),
  );

  // Pinned, archived and group order, shared by every client of this server.
  route('GET', '/api/v1/layout', () => ok({ layout: m.layout() }));
  route('PUT', '/api/v1/layout', async ({ req }) => ok({ layout: m.updateLayout(await readJSON(req)) }));

  // The account's plan usage (5-hour and weekly windows). ?refresh=1 reads it again now.
  route('GET', '/api/v1/usage', async ({ url }) => {
    const usage = await m.planUsage(url.searchParams.get('refresh') === '1');
    return ok({ usage: usage ?? null });
  });

  route('GET', '/api/v1/events', ({ req, res, url, lang }) => {
    const stream = openStream(req, res, url);
    keepAlive(req, res, stream, m.subscribeGlobal(endOnFailure(stream), lang));
    return undefined;
  });

  // since/gen resume a stream the client had open; after (uuids it has, newest
  // first) resumes from a cache when the server's log was rebuilt meanwhile;
  // tail caps the snapshot.
  route('GET', '/api/v1/sessions/{id}/events', async ({ req, res, params, url, lang }) => {
    const s = sessionOr404(params.id);
    const since = Number(url.searchParams.get('since')) || 0;
    const gen = url.searchParams.get('gen') ?? '';
    const tail = Number(url.searchParams.get('tail')) || undefined;
    const after = (url.searchParams.get('after') ?? '').split(',').filter(Boolean).slice(0, 20);
    const stream = openStream(req, res, url);
    const sub = await s.subscribe(since, gen, endOnFailure(stream), lang, { tail, after });
    if (res.destroyed) sub.close();
    keepAlive(req, res, stream, sub);
    return undefined;
  });

  route('GET', '/api/v1/fs/dirs', ({ url }) => {
    const dir = expandPath(url.searchParams.get('path') || '~');
    const hidden = url.searchParams.get('hidden') === '1';
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch (err) {
      throw new ApiFailure(400, (err as Error).message);
    }
    const entries: { name: string; path: string; isGit?: boolean }[] = [];
    for (const name of names) {
      if (!hidden && name.startsWith('.')) continue;
      const full = join(dir, name);
      try {
        if (!statSync(full).isDirectory()) continue;
      } catch {
        continue;
      }
      entries.push({ name, path: full, ...(existsSync(join(full, '.git')) && { isGit: true }) });
      if (entries.length >= 3000) break;
    }
    entries.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
    const parent = dirname(dir);
    return ok({
      path: dir,
      parent: parent === dir ? '' : parent,
      home: homedir(),
      isGit: existsSync(join(dir, '.git')),
      entries,
    });
  });

  route('GET', '/api/v1/fs/recent', () => ok({ dirs: m.recentDirs(40) }));

  // Branches and worktrees of the repository containing a folder.
  route('GET', '/api/v1/fs/git', async ({ url }) => ok(await gitInfo(expandPath(url.searchParams.get('path') || '~'))));

  route('POST', '/api/v1/fs/mkdir', async ({ req }) => {
    const body = await readJSON<{ path?: string }>(req);
    const dir = expandPath(body.path ?? '');
    try {
      mkdirSync(dir, { recursive: true, mode: 0o755 });
    } catch (err) {
      throw new ApiFailure(400, (err as Error).message);
    }
    return ok({ path: dir }, 201);
  });

  const tokenBuf = Buffer.from(o.token);
  const authorized = (req: IncomingMessage, url: URL): boolean => {
    const header = req.headers.authorization ?? '';
    const given = header.startsWith('Bearer ') ? header.slice(7) : url.searchParams.get('token') ?? '';
    const buf = Buffer.from(given);
    return buf.length === tokenBuf.length && timingSafeEqual(buf, tokenBuf);
  };

  return (req, res) => {
    const start = Date.now();
    const url = new URL(req.url ?? '/', 'http://localhost');
    const lang = parseLang(req.headers['accept-language']);
    res.on('finish', () => {
      if (url.pathname.endsWith('/events') || (req.method === 'GET' && res.statusCode < 400)) return;
      o.log(`${req.method} ${url.pathname} ${res.statusCode} ${Date.now() - start}ms`);
    });

    if (req.method === 'GET' && url.pathname === '/healthz') return send(res, 200, { ok: true }, lang);
    if (!url.pathname.startsWith('/api/')) return fail(res, 404, T('notFound'), lang);
    if (!authorized(req, url)) return fail(res, 401, T('tokenInvalid'), lang);

    let pathMatched = false;
    for (const [method, re, names, handler] of routes) {
      const match = re.exec(url.pathname);
      if (!match) continue;
      pathMatched = true;
      if (method !== req.method) continue;
      const params: Record<string, string> = {};
      names.forEach((n, i) => (params[n] = decodeURIComponent(match[i + 1])));
      Promise.resolve()
        .then(() => handler({ req, res, params, url, lang }))
        .then((reply) => {
          if (reply) send(res, reply.status, reply.body, lang, acceptsGzip(req));
        })
        .catch((err: unknown) => {
          if (res.headersSent) {
            res.end();
            return;
          }
          if (err instanceof HttpError) fail(res, err.status, err.text, lang);
          else if (err instanceof ApiFailure) fail(res, err.status, err.msg, lang);
          else if (err instanceof LocalizedError) fail(res, 400, err.text, lang);
          else {
            o.log(`${req.method} ${url.pathname}: ${(err as Error).stack ?? err}`);
            fail(res, 500, (err as Error).message ?? String(err), lang);
          }
        });
      return;
    }
    fail(res, pathMatched ? 405 : 404, pathMatched ? T('methodNotAllowed') : T('notFound'), lang);
  };
}

interface Stream {
  sink: Sink;
  write(text: string): void;
  end(): void;
}

/**
 * Starts an SSE response. With ?compress=gzip (and Accept-Encoding: gzip) the
 * stream is gzipped with a sync flush after every write, so each event still
 * arrives at once, just smaller.
 */
function openStream(req: IncomingMessage, res: ServerResponse, url: URL): Stream {
  const gzip = url.searchParams.get('compress') === 'gzip' && acceptsGzip(req);
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache',
    'X-Accel-Buffering': 'no',
    Connection: 'keep-alive',
    ...(gzip && { 'Content-Encoding': 'gzip' }),
  });
  res.socket?.setNoDelay(true);
  const z = gzip ? createGzip({ flush: zlibConstants.Z_SYNC_FLUSH }) : undefined;
  if (z) z.pipe(res);
  const out = z ?? res;
  const write = (text: string) => {
    if (!res.destroyed) out.write(text);
  };
  // Padding so intermediaries and URLSession deliver the first event at once.
  write(`:${' '.repeat(2048)}\n\n`);
  return {
    write,
    end: () => out.end(),
    sink: (type, data) => {
      if (res.destroyed) return false;
      out.write(`event: ${type}\ndata: ${data}\n\n`);
      // A client this far behind reconnects and catches up from its last seq.
      return res.writableLength + (z?.writableLength ?? 0) < 32 << 20;
    },
  };
}

function endOnFailure(stream: Stream): Sink {
  return (type, data) => stream.sink(type, data) || (stream.end(), false);
}

function keepAlive(req: IncomingMessage, res: ServerResponse, stream: Stream, sub: Subscriber): void {
  const ping = setInterval(() => stream.write(': ping\n\n'), 15_000);
  const close = () => {
    clearInterval(ping);
    sub.close();
  };
  req.on('close', close);
  res.on('close', close);
  if (sub.closed) close();
}
