// binaryd: the Binary server. Manages Claude Code sessions on this machine
// through the official Claude Agent SDK and serves them to Binary clients.

import { createServer as createHttp } from 'node:http';
import { createServer as createHttps } from 'node:https';
import { readFileSync } from 'node:fs';
import { hostname } from 'node:os';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { listSessions } from '@anthropic-ai/claude-agent-sdk';
import { createHandler } from './api.js';
import { bundledClaude, claudeVersion, cleanEnv } from './claude.js';
import { homeDir, loadConfig, splitHostPort, type Config } from './config.js';
import { defaultDesktopDir } from './desktop.js';
import { Manager } from './manager.js';
import { preview } from './normalize.js';
import { service } from './service.js';
import { Store } from './store.js';

export const VERSION = '0.2.0';

const USAGE = `binaryd ${VERSION} — Binary server for Claude Code sessions

Usage:
  binaryd [serve] [flags]     run the server (default)
  binaryd token [flags]       print the URL and token for adding this server to Binary
  binaryd sessions [flags]    list sessions found on this machine
  binaryd service install     run binaryd at login (launchd on macOS, systemd --user on Linux)
  binaryd service uninstall
  binaryd version

Flags:
  --home <dir>        state directory (default $BINARY_HOME or ~/.binary)
  --listen <addr>     listen address, overrides server.json (e.g. 0.0.0.0:7350)
  --claude <path>     Claude Code executable (default: the one bundled with the Agent SDK)
  --tls-cert <file>   TLS certificate (enables HTTPS together with --tls-key)
  --tls-key <file>    TLS key
`;

function log(msg: string): void {
  console.log(`${new Date().toISOString()} ${msg}`);
}

function setup(values: Record<string, string | boolean | undefined>): Config {
  const cfg = loadConfig(homeDir(values.home as string | undefined));
  if (values.listen) cfg.data.listen = values.listen as string;
  if (values.claude) cfg.data.claudePath = values.claude as string;
  if (values['tls-cert']) {
    cfg.data.tlsCert = values['tls-cert'] as string;
    cfg.data.tlsKey = values['tls-key'] as string;
  }
  return cfg;
}

async function serve(cfg: Config): Promise<void> {
  const env = { ...cleanEnv(process.env, cfg.data.keepEnv), CLAUDE_AGENT_SDK_CLIENT_APP: `binary/${VERSION}` };
  const bundled = bundledClaude();
  const claudeBin = cfg.data.claudePath || bundled?.path || 'claude';
  const version = (await claudeVersion(claudeBin, env)) || bundled?.version || '';
  log(`binaryd ${VERSION} · Claude Agent SDK · claude ${version} (${claudeBin})`);

  const store = new Store(cfg.dir);
  const manager = new Manager(cfg, store, {
    claudeBin,
    claudeVersion: version,
    claudePath: cfg.data.claudePath,
    env,
    desktopDir: cfg.data.desktopLinks === false ? undefined : cfg.data.desktopSessionsDir || defaultDesktopDir(),
    log,
  });
  const t0 = Date.now();
  await manager.start();
  log(`listed ${manager.summaries().length} sessions in ${Date.now() - t0}ms`);

  const handler = createHandler({
    manager,
    token: cfg.data.token,
    name: cfg.displayName,
    version: VERSION,
    claudePath: claudeBin,
    claudeVersion: version,
    log,
  });
  const tls = cfg.data.tlsCert && cfg.data.tlsKey;
  const server = tls
    ? createHttps({ cert: readFileSync(cfg.data.tlsCert!), key: readFileSync(cfg.data.tlsKey!) }, handler)
    : createHttp(handler);
  server.headersTimeout = 10_000;
  server.requestTimeout = 0; // SSE streams stay open
  const { host, port } = splitHostPort(cfg.data.listen);
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, resolve);
  });
  log(`listening on ${tls ? 'https' : 'http'}://${cfg.data.listen} (config ${cfg.path})`);
  if (!['127.0.0.1', 'localhost', '::1'].includes(host) && !tls) {
    log('WARNING: serving plain HTTP on a non-loopback address; use --tls-cert/--tls-key, an SSH tunnel or a private network');
  }

  let stopping = false;
  const shutdown = async () => {
    if (stopping) return;
    stopping = true;
    log('shutting down');
    server.close();
    server.closeAllConnections();
    await manager.shutdown();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

function printToken(cfg: Config): void {
  const { host, port } = splitHostPort(cfg.data.listen);
  const shown = host === '0.0.0.0' || host === '::' ? hostname() : host;
  const scheme = cfg.data.tlsCert ? 'https' : 'http';
  console.log(`Name:  ${cfg.displayName}\nURL:   ${scheme}://${shown}:${port}\nToken: ${cfg.data.token}`);
}

async function printSessions(): Promise<void> {
  const t0 = Date.now();
  const infos = await listSessions({ limit: 50 });
  console.error(`listed in ${Date.now() - t0}ms`);
  for (const i of infos) {
    const at = new Date(i.lastModified).toLocaleString('sv-SE').slice(5, 16);
    const project = (i.cwd ?? '').split('/').pop() ?? '';
    console.log(`${at}  ${preview(project, 16).padEnd(17)} ${preview(i.summary, 60)}`);
  }
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  let cmd = 'serve';
  if (argv[0] && !argv[0].startsWith('-')) cmd = argv.shift()!;
  let action = '';
  if (cmd === 'service') action = argv.shift() ?? '';
  const { values } = parseArgs({
    args: argv,
    options: {
      home: { type: 'string' },
      listen: { type: 'string' },
      claude: { type: 'string' },
      'tls-cert': { type: 'string' },
      'tls-key': { type: 'string' },
      help: { type: 'boolean', short: 'h' },
    },
    allowPositionals: false,
  });
  if (values.help) {
    process.stdout.write(USAGE);
    return;
  }
  switch (cmd) {
    case 'version':
      console.log(VERSION);
      return;
    case 'serve':
      return serve(setup(values));
    case 'token':
      return printToken(setup(values));
    case 'sessions':
      return printSessions();
    case 'service': {
      const cfg = setup(values);
      service(action, cfg.dir, fileURLToPath(import.meta.url));
      return;
    }
    default:
      process.stderr.write(USAGE);
      process.exit(2);
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
