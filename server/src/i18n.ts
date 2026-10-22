// Human-readable server text (activity lines, errors, transcript markers) in
// the language each client asks for with Accept-Language. Text is kept as a
// message key until it is serialized for a particular client, so one event
// can go to an English and a Chinese client at once. English lives here;
// other languages in locales/<lang>.json, keyed the same way.

import { readFileSync } from 'node:fs';

export type Lang = 'zh' | 'en';

/** Used when a client sends no Accept-Language or one we don't know. */
export const DEFAULT_LANG: Lang = 'en';

const CATALOG = {
  // activity
  starting: 'Starting claude…',
  thinking: 'Thinking…',
  replying: 'Replying…',
  compacting: 'Compacting context…',
  apiRetry: 'Retrying API ({attempt}/{max})',
  externalBusy: 'Running in {holder}',
  externalOpen: 'Open in {holder}, idle',
  externalBackground: 'Open in {holder}, background task running',
  taskNotFound: 'That background task has already ended',
  queuedNotFound: 'That queued message was already sent or cancelled',
  holderDesktop: 'the Claude desktop app',
  holderTmux: 'tmux',
  holderTerminal: 'a terminal',
  holderIde: 'an IDE',
  holderOther: 'another app',
  fileNotFound: 'No such file: {path}',
  fileTooLarge: 'The file is over {max} MB, too large to preview',
  forkFailed: 'Could not fork the session: {detail}',
  // session and transcript text
  newSession: 'New session',
  interrupted: 'Interrupted',
  compacted: 'Conversation compacted',
  document: '[Document]',
  evSideSessions: 'Update from linked sessions',
  evCrossSession: 'Message from {name}',
  evCrossSessionAnon: 'Message from another session',
  evCI: 'CI update',
  evCIPr: 'CI update · {pr}',
  evScheduled: 'Scheduled task: {name}',
  evScheduledAnon: 'Scheduled task',
  withBody: "{summary}\n\n{body}",
  truncatedValue: "{head}\n… (truncated, {n} characters in total)",
  defaultModel: "Claude Code's default model",
  // errors
  bodyTooLarge: 'Request body too large',
  badRequest: 'Malformed request: {detail}',
  tokenInvalid: 'Invalid token',
  notFound: 'Not found',
  methodNotAllowed: 'Method not allowed',
  sessionNotFound: 'Session not found',
  behaviorInvalid: 'behavior must be allow or deny',
  pathEmpty: 'Path is empty',
  pathNotAbsolute: 'An absolute path is required: {path}',
  dirMissing: 'Directory does not exist: {path}',
  cwdUnknown: "This session's working directory is unknown",
  cwdMissing: 'Working directory does not exist: {path}',
  sshSession: 'This session runs on SSH host {host} through the Claude desktop app; it can only be viewed here',
  unknownEffort: 'Unknown effort: {value}',
  modeNotAllowed: 'Permission mode not allowed: {value}',
  parentNotFound: 'Parent session not found: {id}',
  notLive: 'This session has no running process',
  emptyMessage: 'The message is empty',
  cannotStart: 'Could not start claude: {detail}',
  initTimeout: 'Timed out waiting for claude to initialize',
  initFailed: 'claude failed to initialize: {detail}{stderr}',
  crashed: 'The claude process exited unexpectedly{stderr}',
  crashedWithError: 'The claude process exited unexpectedly: {error}{stderr}',
  modelSwitchFailed: 'Could not switch the model: {detail}',
  modeSwitchFailed: 'Could not switch the permission mode: {detail}',
  permissionGone: 'The permission request no longer exists',
  notGitRepo: 'Not a git repository: {path}',
  worktreeDirty: 'Branch {branch} has uncommitted changes, so it cannot be switched; use a worktree instead',
  worktreeNameInvalid: 'Invalid worktree name: {name}',
  worktreeExists: 'Worktree already exists: {path}',
  gitFailed: 'git failed: {detail}',
  envInvalid: 'Invalid environment variable: {name}',
  layoutInvalid: '{field} must be a list of names',
  imageNotFound: 'Image not found or no longer cached',
  imageInvalid: 'Unsupported image (PNG, JPEG, GIF or WebP as base64)',
  imageTooLarge: 'Image too large (at most {max} MB each)',
  tooManyImages: 'Too many images (at most {max} per message)',
  // replies to Claude for permission requests Binary closes itself
  deniedInBinary: 'The user denied this action in Binary',
  sessionRestarted: 'The session was restarted',
  cancelled: 'Cancelled',
  processExited: 'The claude process exited',
  turnEnded: 'The turn has ended',
} as const satisfies Record<string, string>;

export type Key = keyof typeof CATALOG;

/** Translations: locales/<lang>.json next to src/ (and two up from dist/src/). */
function loadLocale(lang: Lang): Partial<Record<Key, string>> {
  for (const rel of ['../locales/', '../../locales/']) {
    try {
      return JSON.parse(readFileSync(new URL(`${rel}${lang}.json`, import.meta.url), 'utf8'));
    } catch {
      // try the next place
    }
  }
  return {};
}

const LOCALES: Record<Lang, Partial<Record<Key, string>>> = { en: {}, zh: loadLocale('zh') };

/** A message's template in a language, falling back to English. */
export function template(key: Key, lang: Lang): string {
  return LOCALES[lang][key] ?? CATALOG[key];
}

/** A message that renders in whichever language it is serialized for. */
export class Text {
  constructor(
    readonly key: Key,
    readonly params: Record<string, unknown> = {},
  ) {}

  render(lang: Lang): string {
    return template(this.key, lang).replace(/\{(\w+)\}/g, (_, name: string) => {
      const v = this.params[name];
      return v instanceof Text ? v.render(lang) : String(v ?? '');
    });
  }

  is(key: Key): boolean {
    return this.key === key;
  }

  toString(): string {
    return this.render(DEFAULT_LANG);
  }
}

export function T(key: Key, params?: Record<string, unknown>): Text {
  return new Text(key, params);
}

/** Server text: localizable, or verbatim (text that came from Claude Code). */
export type Msg = string | Text;

export function render(m: Msg, lang: Lang): string {
  return m instanceof Text ? m.render(lang) : m;
}

/** An error whose message is localizable. */
export class LocalizedError extends Error {
  constructor(readonly text: Text) {
    super(text.render(DEFAULT_LANG));
  }
}

/** The user-facing text of any error. */
export function errorText(err: unknown): Msg {
  if (err instanceof LocalizedError) return err.text;
  return err instanceof Error ? err.message : String(err);
}

/** Picks a supported language from an Accept-Language header. */
export function parseLang(header: string | string[] | undefined): Lang {
  const value = Array.isArray(header) ? header[0] : header;
  for (const part of (value ?? '').split(',')) {
    const tag = part.trim().split(';')[0].toLowerCase();
    if (tag.startsWith('zh')) return 'zh';
    if (tag.startsWith('en')) return 'en';
  }
  return DEFAULT_LANG;
}

/** JSON with every Text rendered for lang. */
export function encode(value: unknown, lang: Lang): string {
  return JSON.stringify(value, (_key, v: unknown) => (v instanceof Text ? v.render(lang) : v));
}
