// Slash commands for the message box's suggestions: what Claude Code offers in
// a folder (its own commands; the user's, the project's and plugins' commands
// and skills; MCP prompts). A live session reports its own list; for any other
// folder a short-lived process starts up and answers (no prompt, no model call).

import { query, type Options, type SDKUserMessage, type SlashCommand } from '@anthropic-ai/claude-agent-sdk';

/** A command as clients get it. */
export interface Command {
  name: string;
  description: string;
  argumentHint?: string;
  aliases?: string[];
  builtin?: boolean;
}

/**
 * What a client can offer: without the commands only a terminal can run
 * (Claude Code names them in each session's init message) and internal ones,
 * one row per name (Claude Code's own wins, as it does when the name is typed).
 */
export function toCommands(list: SlashCommand[], terminal: ReadonlySet<string>): Command[] {
  const byName = new Map<string, Command>();
  for (const c of list) {
    if (!c.name || c.name.startsWith('__') || terminal.has(c.name)) continue;
    if (byName.get(c.name)?.builtin) continue;
    byName.set(c.name, {
      name: c.name,
      description: c.description ?? '',
      ...(c.argumentHint && { argumentHint: c.argumentHint }),
      ...(c.aliases?.length && { aliases: c.aliases }),
      ...(c.builtin && { builtin: true }),
    });
  }
  return [...byName.values()];
}

const FRESH_MS = 60_000;

/** Commands per folder, read through short-lived processes and kept a minute. */
export class CommandProbe {
  private cache = new Map<string, { at: number; list: SlashCommand[] }>();
  private reading = new Map<string, Promise<SlashCommand[]>>();

  constructor(
    private readonly options: (cwd: string) => Options,
    private readonly log: (msg: string) => void,
  ) {}

  async read(cwd: string): Promise<SlashCommand[]> {
    const hit = this.cache.get(cwd);
    if (hit && Date.now() - hit.at < FRESH_MS) return hit.list;
    let p = this.reading.get(cwd);
    if (!p) {
      p = this.probe(cwd).finally(() => this.reading.delete(cwd));
      this.reading.set(cwd, p);
    }
    return p;
  }

  private async probe(cwd: string): Promise<SlashCommand[]> {
    const input = { async *[Symbol.asyncIterator]() { await new Promise(() => undefined); } } as AsyncIterable<SDKUserMessage>;
    const q = query({ prompt: input, options: this.options(cwd) });
    try {
      const init = await Promise.race([
        q.initializationResult(),
        new Promise<never>((_, no) => setTimeout(() => no(new Error('timeout')), 60_000).unref()),
      ]);
      const list = init.commands ?? [];
      this.cache.set(cwd, { at: Date.now(), list });
      return list;
    } catch (err) {
      this.log(`reading slash commands in ${cwd} failed: ${(err as Error).message}`);
      return this.cache.get(cwd)?.list ?? [];
    } finally {
      q.close();
    }
  }
}
