// Tools for Claude inside a Binary session to read and rename sessions, with
// the names and arguments the Claude desktop app uses for the sessions it
// hosts (project instructions ask for get_session / set_session_title).
// Served in-process through the Agent SDK's MCP support; renaming goes
// through Binary's own update path, so every client sees the new title.

import { createSdkMcpServer, tool, type McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';

export const SESSION_TOOL_SERVER = 'binary';
/** Full tool names, auto-allowed for Binary's sessions. */
export const SESSION_TOOLS = ['get_session', 'set_session_title'].map((n) => `mcp__${SESSION_TOOL_SERVER}__${n}`);

export interface SessionToolHost {
  /** What get_session reports, or undefined for an unknown session. */
  sessionInfo(id: string): Record<string, unknown> | undefined;
  /** Renames a session; resolves to its title afterwards. */
  setTitle(id: string, title: string): Promise<string>;
}

const MAX_TITLE = 200;

type Result = { content: { type: 'text'; text: string }[]; isError?: boolean };

const text = (s: string, isError = false): Result => ({ content: [{ type: 'text', text: s }], ...(isError && { isError }) });

/** The tool definitions for the session `self` runs in (exported for tests). */
export function sessionToolDefs(self: string, host: SessionToolHost) {
  const resolve = (id: string) => (!id || id === 'self' ? self : id);
  const sessionId = z.string().describe('The session id, or the literal string "self" for this session.');
  return [
    tool(
      'get_session',
      'Get metadata for a session by id, or for this session with "self": title, working directory, git branch and worktree, model, effort, permission mode, state, group and parent. Metadata only, no conversation content.',
      { session_id: sessionId },
      async ({ session_id }) => {
        const info = host.sessionInfo(resolve(session_id));
        return info ? text(JSON.stringify(info, null, 2)) : text(`No session ${session_id} on this server.`, true);
      },
      { annotations: { readOnlyHint: true }, searchHint: 'session title metadata', alwaysLoad: true },
    ),
    tool(
      'set_session_title',
      'Rename a session: this one with "self", or another by id. Use it when the user asks, or when the session\'s scope has clearly changed and the old title is misleading.',
      { session_id: sessionId, title: z.string().describe('New title for the session.') },
      async ({ session_id, title }) => {
        const t = title.trim();
        if (!t) return text('The title is empty.', true);
        if (t.length > MAX_TITLE) return text(`The title is longer than ${MAX_TITLE} characters.`, true);
        const id = resolve(session_id);
        if (!host.sessionInfo(id)) return text(`No session ${session_id} on this server.`, true);
        try {
          return text(`Renamed to: ${await host.setTitle(id, t)}`);
        } catch (err) {
          return text(`Renaming failed: ${(err as Error).message}`, true);
        }
      },
      { annotations: { idempotentHint: true }, searchHint: 'session title rename', alwaysLoad: true },
    ),
  ];
}

/** An in-process MCP server with the session tools, for one session's claude process. */
export function sessionTools(self: string, host: SessionToolHost): McpSdkServerConfigWithInstance {
  return createSdkMcpServer({ name: SESSION_TOOL_SERVER, version: '1.0.0', tools: sessionToolDefs(self, host) });
}
