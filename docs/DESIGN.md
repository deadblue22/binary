# Binary design

Binary manages Claude Code sessions on one or more machines: view status and content live, send messages, start sessions in a chosen directory, set model / effort / permission mode, and approve tool permissions from the client.

```
┌──────────── macOS ─────────────┐            ┌────────────── macOS / Linux ───────────────┐
│ Binary.app (SwiftUI)           │  REST      │ binaryd (TypeScript / Node.js)             │
│  · multiple servers            │ ─────────▶ │  ├─ HTTP API /api/v1 (Bearer token)        │
│  · session list, groups        │            │  ├─ SSE streams (global + per session)     │
│  · conversation (streaming)    │ ◀───────── │  ├─ Manager: list, external state, summary │
│  · composer / approvals / Q&A  │  SSE       │  ├─ Session: query() lifecycle, merged log │
│  · new session (remote dirs)   │            │  └─ Store (~/.binary)                      │
└────────────────────────────────┘            └──────────────┬─────────────────────────────┘
                                                             │ official Claude Agent SDK
                                                             │ query() / listSessions() / getSessionMessages() …
                                                             ▼
                                               Claude Code (official, unmodified, bundled with and matching the SDK)
```

## 1. Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| How Claude is driven | **Only the official TypeScript Agent SDK** (`@anthropic-ai/claude-agent-sdk`), plus `claude agents --json`, which Claude Code provides for scripts | Every interaction with Claude Code goes through official public interfaces: no internal protocols, no parsing of internal file formats, no handling of credentials. The SDK runs the official, unmodified Claude Code with the user's own login; this is what the official terms call "ordinary, individual usage of Claude Code and the Agent SDK" |
| Server language | TypeScript on Node.js 20+; the only runtime dependency is the Agent SDK | The SDK exists only for Python and TypeScript; TS lines up directly with the SDK's type definitions |
| Claude Code version | By default the `claude` bundled with the SDK and matching its version; `claudePath` can point to your own install | A matching version guarantees the protocol agrees; upgrading = upgrading the npm dependency |
| System prompt | `systemPrompt: { type: 'preset', preset: 'claude_code' }` | The SDK defaults to a minimal prompt, unlike the terminal; the preset makes behavior match `claude` / `claude -p`. `settingSources` stays at its default (load everything), so CLAUDE.md, hooks and plugins match the terminal |
| Where sessions come from | `listSessions()` lists every session on the machine (opened from the terminal, desktop app, IDE or SDK) | An official interface; no scanning of directories ourselves |
| Process lifecycle | session ≠ process: `query({ resume })` on demand when a message is sent, automatic `close()` on idle timeout | Hundreds of past sessions can't all keep a resident process |
| Live push | SSE (one `data: {json}` line per event) | One-way push is enough, actions go through REST; easy to debug with curl |
| Client | Native SwiftUI for macOS 14+, built with SwiftPM, no dependencies | Native experience; talks to the server only through the HTTP API, and features degrade when the server lacks newer endpoints |

## 2. Official interfaces used

| Purpose | Interface |
|---|---|
| Start / resume a session | `query({ prompt: AsyncIterable<SDKUserMessage>, options })`, with `cwd`, `sessionId` or `resume`, `model`, `effort`, `permissionMode`, `systemPrompt`, `includePartialMessages`, `canUseTool`, `env` set in `options` |
| Control while running | `interrupt()`, `setModel()`, `setPermissionMode()`, `applyFlagSettings({ effortLevel })`, `initializationResult()` (model list), `close()` |
| Permissions and questions | `canUseTool` callback: tool approval, `AskUserQuestion` (`updatedInput.answers`), `ExitPlanMode`; "Always Allow" returns `suggestions` as `updatedPermissions` |
| List and history | `listSessions()`, `getSessionInfo()`, `getSessionMessages()` (rebuilds the conversation chain along parentUuid) |
| Fork a session | `forkSession()` (new id, same history) |
| Effort actually in effect | `PreToolUse` / `Stop` callbacks in `options.hooks`: `effort.level` in the hook input is the level this turn actually used (already downgraded for the model), used to show which level "Default" stands for |
| Subagents | `listSubagents()`, `getSubagentMessages()` |
| Rename and group | `renameSession()`, `tagSession()` (a group is a tag) |
| Sessions running elsewhere | `claude agents --json` (Claude Code's output for scripts: pid, cwd, busy/idle) |
| Session tools for Claude | `createSdkMcpServer()` + `tool()` (in-process MCP), `options.mcpServers`, `options.allowedTools` |

The one exception is the **desktop app's session records**: Claude Code doesn't record parent/child relations between sessions, but the Claude desktop app does, in its own session records (`~/Library/Application Support/Claude/claude-code-sessions/<org>/<account>/local_*.json`). binaryd reads only five fields from these files (`sessionId`, `cliSessionId`, `spawnedFrom.sessionId`, `sshConfig.sshHost`, `permissionMode`), checking every 10 seconds and rereading only changed files, to fill in `parentId`, `sshHost` and the permission mode (desktop sessions are shown and started with the desktop app's mode; once changed in Binary, Binary's is used until the desktop app changes it again). (For sessions the desktop app runs on other machines over SSH, it mirrors the transcript locally, so they appear in the list too.) This isn't a public interface: if the format changes, parent/child relations are simply lost and nothing else is affected; it can be turned off with `desktopLinks: false` in the config.

**Session tools**: every claude process Binary starts carries an in-process MCP server `binary` that provides `get_session` and `set_session_title`, with the same names and parameters as the tools the Claude desktop app gives the sessions it hosts (`session_id` may be `"self"`), so project instructions asking Claude to maintain the session title work in Binary too. Both tools are always loaded (not deferred behind tool search) and are exempt from approval via `allowedTools`; renaming takes the same path as a rename from the client (`renameSession()`), so every client sees it live.

The child process environment is cleared of variables such as `CLAUDECODE` and `CLAUDE_CODE_*` injected by a host Claude session (so that when binaryd is started inside a Claude session, the child doesn't think it's a nested session), and `CLAUDE_AGENT_SDK_CLIENT_APP=binary/<version>` is set to identify the client, as the SDK docs describe.

## 3. Server

### 3.1 Modules

```
server/
  bin/binaryd          launcher script (node dist/src/main.js)
  src/main.ts          entry point; serve / token / sessions / service / version
  src/config.ts        config and token (~/.binary/server.json)
  src/store.ts         Binary's own small persistent state (per-session model, effort, permission mode, pending title and group, parent session; cached model list)
  src/claude.ts        environment cleanup, locating the SDK's bundled claude, `claude agents --json`
  src/desktop.ts       parent/child relations from the desktop app's session records (read-only)
  src/git.ts           branch info, creating worktrees, switching branches (calls git directly)
  src/holders.ts       which program holds an external claude process (desktop app, tmux, terminal, IDE)
  src/lister.ts        calls listSessions in a worker thread (it parses the head and tail of every transcript synchronously, which would block requests on the main thread)
  src/recent.ts        "recent directories": worktrees map to their main repo, temp directories and desktop scratch directories are skipped
  src/tools.ts         get_session / set_session_title for Claude inside sessions
  src/i18n.ts          English and Chinese for human-readable text (activity, errors, markers)
  src/normalize.ts     SDK messages → Entry for client rendering
  src/log.ts           Subscriber, ordered Log deduplicated by uuid
  src/session.ts       a single session: query() lifecycle, canUseTool, streaming fragments, merging with history
  src/manager.ts       session registry, list refresh, external state, summaries, settings updates, subagents
  src/api.ts           REST + SSE + auth
  src/service.ts       launchd / systemd --user
  test/                node:test; fake-claude.mjs is a fake CLI speaking the same protocol
```

### 3.2 Content sources and merging

A session's conversation log (Log) has two sources, deduplicated by uuid:

1. **History**: `getSessionMessages()`, read in full the first time the session is viewed.
2. **Live**: the message stream of our own `query()`, with the lowest latency, plus streaming fragments, permission requests and status. User messages we send get a uuid assigned by the server, and Claude Code writes that same uuid to the transcript, so both sides refer to the same record.

After the process ends, and when viewing sessions running elsewhere, "reconciliation" keeps up with transcript changes:

- Every second, `getSessionInfo()` compares modification time and file size (a few ms); only on a change is `getSessionMessages()` reread, at intervals of at least 3 times the last read time (measured: 160–400ms per read for 94–142MB transcripts, a few ms for small files).
- If all currently displayed user / assistant messages are still in the newly read chain → only the new messages at the end of the chain are appended; otherwise (rewind, compaction rewrite) everything is replaced and a new snapshot is sent. An empty read never replaces.

### 3.3 States

```
            send / create(prompt)
   idle ───────────────────────▶ starting ──initialize ok──▶ running ◀──┐
    ▲  ▲                            │                         │  │      │ user responds
    │  │                       start failed                    │  │ canUseTool
    │  └──── result ───────────── error ◀──── process crashed ──┘  ▼      │
    │                                                          waiting ─┘
    └── idle timeout / stop: close() (live=false, state stays idle)
external: `claude agents --json` reports it open in a terminal, IDE or the desktop app (not a Binary process)
```

`activity` comes from streaming fragments, tool calls, `task_summary`, `api_retry` and so on; for external sessions it is "Running in {program}" or "Open in {program}".

### 3.4 Settings changes

| Setting | Process alive | No process |
|---|---|---|
| model | `setModel()`, immediate | Stored, used by the next `query({ model })` |
| effort | `applyFlagSettings({ effortLevel })`; `max` and "back to default" restart the query before the next turn | Stored, used by the next `query({ effort })` |
| permissionMode | `setPermissionMode()` | Stored, used by the next `query({ permissionMode })` |
| title | `renameSession()` (written to the transcript) | If the transcript doesn't exist yet, passed to the first start as `query({ title })` |
| tag (group) | `tagSession()` | Stored in Binary first, written automatically once the transcript appears |

### 3.5 API (`/api/v1`, `Authorization: Bearer <token>`)

| Method | Path | Description |
|---|---|---|
| GET | `/info` | Host info, Claude Code version, model list, effort levels, permission modes, defaults |
| GET | `/sessions` | Summaries of all sessions (including `tag`, `parentId`, `subagentCount`, `sshHost`, `cwdExists`, `external`) |
| POST | `/sessions` | `{cwd, prompt?, images?, model?, effort?, permissionMode?, title?, tag?, parentId?, branch?, worktree?, env?}` creates a session. `worktree: true` creates `<repo>/.claude/worktrees/<name>` from `branch` (default: current HEAD) on branch `claude/<name>` (same as the desktop app); without a worktree, `branch` is checked out in the original folder, refused if there are uncommitted changes. `env` holds extra environment variables for this session's claude process |
| GET | `/sessions/{id}` | A single summary |
| PATCH | `/sessions/{id}` | `{model?, effort?, permissionMode?, title?, tag?}` |
| GET | `/sessions/{id}/entries?before=&limit=&beforeUuid=` | Page backwards; `beforeUuid` locates by entry uuid (entries in the client cache come from an older log, so their seq no longer matches) |
| POST | `/sessions/{id}/messages` | `{text, images?}` sends a message (while running, it goes into Claude Code's queue); images are base64 PNG/JPEG/GIF/WebP, up to 5MB each and 20 per message. If the session can't run locally (`sshHost` is set, or the working directory doesn't exist), returns 409 with the reason. If another program is running a turn in this session, the message is queued on the server first (returns 202 `{queued: <id>}`) and sent in order once that turn ends |
| DELETE | `/sessions/{id}/queue/{qid}` | Cancel a message that is still queued |
| GET | `/sessions/{id}/file?path=` | A file mentioned in a message (relative paths resolve against the session directory), with the matching Content-Type, up to 50MB; the client loads it in a web view through a custom URL scheme, and relative resources in HTML go through the same endpoint |
| GET | `/usage?refresh=1` | Plan usage of the Claude account on this server (percentages and reset times for the 5-hour, 7-day and other windows), from the SDK's usage interface (experimental); cached for a few minutes |
| POST | `/sessions/{id}/fork` | `{title?, text?, images?}` copies the session into a new one with the SDK's `forkSession` (new id, same history, title gets "(fork)" appended by default), with the same directory, settings and group, nested under the original session; with `text` / `images`, sends them in the copy right away. The original session is untouched |
| GET | `/sessions/{id}/images/{key}` | Original image from a user message (the `image` field of an image block); the server caches at most 48MB per session and returns 404 once evicted |
| POST | `/sessions/{id}/interrupt` | Interrupt the current turn |
| POST | `/sessions/{id}/stop` | Stop the process (the session itself is kept) |
| POST | `/sessions/{id}/permissions/{reqId}` | `{behavior, message?, updatedInput?, remember?}` |
| GET | `/sessions/{id}/subagents` | Subagent list `{id, title, prompt, entries, startedAt, updatedAt}`; `prompt` is the full prompt the subagent received (up to 4000 characters), used to match it exactly to the Task / Agent call in the parent session |
| GET | `/sessions/{id}/subagents/{agentId}/entries` | A subagent's conversation |
| GET | `/fs/dirs?path=&hidden=1` | Remote directory browsing |
| GET | `/fs/recent` | Working directories used by recent sessions |
| GET | `/fs/git?path=` | Branches of the repository containing the folder (most recently committed first), current branch, whether there are uncommitted changes, existing worktrees |
| POST | `/fs/mkdir` | `{path}` creates a directory |
| GET | `/events` | SSE: `sessions` snapshot, `session` updates, `removed` |
| GET | `/sessions/{id}/events?since=&gen=&tail=&after=&compress=` | SSE: `snapshot`, `delta`, `entries`, `partial`, `session`, `permission`, `permissions`, `permission_resolved`, `notice`. `since`/`gen` resume the same log; otherwise, if `after` (uuids of the newest few entries in the client cache, newest first) matches, only what follows is sent (`delta`: `{gen, anchor, anchorSeq, entries, session, partial, permissions}`); if it doesn't match, or there are more new entries than `tail`, a `snapshot` of the latest `tail` entries is sent (default 300). With `compress=gzip` and an `Accept-Encoding: gzip` request header, the whole event stream is gzipped and flushed after every write |

`parentId`: given by the client when a session is created "from another session" in Binary; for sessions the Claude desktop app spawned (such as review sessions started by start_session), read from the desktop app's records. Returned only when the parent session is also in the list.

`appliedEffort`: the effort Claude Code actually used on the latest turn (from the hook, saved in Binary's records so it can still be shown after the process exits); when the session is set to "Default", the client uses it to show which level is current. After the effort is changed, it isn't returned until the next turn ends. `lastModel` does the same for the model.

`external`: given as `{busy, background?, holder}` when the session is held by a claude process other than binaryd. `holder` is the program holding it, determined by walking the process's parent chain (`ps`): `desktop` (the Claude desktop app, either locally or a remote process it started over SSH), `tmux`, `terminal`, `ide`, `other`. `claude agents --json` reports busy as long as anything is still running in the process (including background shells left over from a turn that ended long ago, such as a dev server), so the server also checks the transcript: if the last conversation entry is a reply with no pending tool calls and nothing has been written for 30 seconds, the turn counts as finished, `busy: false, background: true`. Only when a turn is really running (`busy: true`) are incoming messages queued (`queued` lists the queued messages); otherwise they're sent directly. The desktop app and tmux keep the process open indefinitely, so only `busy` counts as activity (and only it affects `updatedAt`).

**Taking turns between programs**: an open claude process only remembers the version of the conversation it read itself; it can't see turns added elsewhere later, and continuing there forks from the old position (verified). Before each send, Binary checks: if its own process is idle, the transcript has changed since that process last wrote to it, and the last conversation entry wasn't written by it, it restarts the process first (resuming from the transcript) and then sends, so Binary's side never forks. The other program's side can't do this: before continuing in the desktop app or tmux, close and reopen the session there (or quit claude and `--resume`).

`sshHost`: a session the Claude desktop app runs on that host over SSH; only its mirrored transcript exists locally, so it's view-only. `cwdExists`: whether the working directory exists locally (cached per directory for 30 seconds; omitted when cwd is unknown). If either applies, sending a message returns 409, and the client should show the session as read-only.

**System entries in the conversation** (`kind: "system"`, distinguished by `subtype`): `compact_boundary`, `compact_summary`, `interrupted`, `local_command`, `api_error`; for `task_notification` (completion notice of a background task or agent) and `app_event` (notifications the Claude desktop app sends as user messages: `side-sessions-event`, `cross-session-message`, `ci-monitor-event`, `scheduled-task`, with the tag name in the `event` field), the first line of `text` is a summary, followed after a blank line by a Markdown body. Context meant for the model, such as `<system-reminder>` and `<artifact-view-context>`, is stripped from user messages and tool results; when an `app_event` shares a message with text the user wrote, only the user's text is shown.

**Transfer size**: JSON responses over 1KB are compressed when the request has `Accept-Encoding: gzip` (transcripts shrink to about 1/3–1/5). Remote servers often have very low bandwidth (measured about 46KB/s over Tailscale); opening a session used to transfer 300 entries, about 300KB, in 5–7 seconds; now it's 60 entries + gzip, about 15KB, and resuming from the client cache transfers only what's new (about 1KB).

**Language**: activity descriptions, error messages and system markers in the conversation (interrupted, conversation compacted, etc.) follow the `Accept-Language` request header (`zh` / `en`), and SSE events are serialized separately in each subscriber's language; when the header is absent or unrecognized, Chinese is used. Text Claude itself produces (replies, `task_summary`, `post_turn_summary`) is returned as is.

### 3.6 Security

- By default the server only listens on `127.0.0.1:7350`; a token is required even locally. The token is randomly generated on first run and stored in `~/.binary/server.json` (0600).
- Remote access, pick one of three: Tailscale (recommended; `tailscale serve` gives the local port an HTTPS address reachable only inside the tailnet), an SSH tunnel, or HTTPS directly with `--tls-cert/--tls-key`. The token is equivalent to shell access on that machine.
- Binary never reads, stores or forwards Claude's credentials; Claude Code uses its own login.
- `bypassPermissions` can be disabled in the config (`allowBypassPermissions: false`).

## 4. Client

```
client/Sources/Binary/
  App/        BinaryApp (windows, menus, settings window), notifications, development debug hooks
  Models/     Codable types for the wire protocol, JSONValue
  Network/    APIClient (REST), SSE (auto-reconnect, resumes by since/gen)
  Stores/     ServerStore (server list), ServerConnection, SessionController
  Views/      sidebar, conversation, tool cards, Markdown, composer, permission and question cards, new session, directory picker, settings
```

- The sidebar has a section per server (collapsible), organized within by group (session tag), pinned and archived; child sessions and subagents are nested under their parent. Status dots distinguish running / awaiting approval / idle / busy elsewhere / held elsewhere but idle / error / view-only.
- When the same session appears on several servers (the desktop app's SSH mirrors), only the copy on the server where it actually runs is shown.
- The sidebar only distinguishes whether you can talk right away: working, awaiting approval, idle; whether another program has it open shows only in the tooltip and the info panel. Messages to a session held elsewhere but idle are sent directly (a hint above the message box says to close and reopen it there before continuing over there); while the other side is running a turn, messages are queued until that turn ends; fork is in the send menu.
- New sessions are project-centric (starred, recent directories, branch, worktree, environment variables, stored locally in `projects.json`); the message box supports pasting and dropping images.
- The conversation view merges each `tool_use` with its `tool_result` into an expandable tool card; text and thinking being generated show live.
- Permission requests appear as cards pinned above the message box; `AskUserQuestion` renders as options, `ExitPlanMode` renders the plan.
- On first launch the client reads `~/.binary/server.json` automatically and adds a "This Mac" server.

## 5. Known limitations

- Sessions held by another program: you can't see their output as it streams, answer their permission requests, or interrupt a turn they're running (Claude Code offers no interface for external programs). Binary can keep talking at any time (restarting its own process before sending when needed), but before going back to that program to continue, close and reopen the session there, or it forks from the old position it remembers.
- The history API doesn't provide per-turn effort or cost; the sidebar's last model and preview are available only after the session has been viewed or run by Binary.
- Reconciling large transcripts rereads them in full, throttled by read time, so they update less promptly than incremental reads would.
- Claude Code doesn't record parent/child relations between sessions; `parentId` comes from Binary's own records and the Claude desktop app's session records, and sessions started manually in a terminal have no parent/child relations.
