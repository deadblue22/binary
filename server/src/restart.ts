// What a restart of binaryd interrupts, kept on disk so the next binaryd can
// pick it up. Claude processes are children of binaryd, talking over its
// pipes: they end with it. The conversations survive in their transcripts,
// but a turn in progress, the process's background tasks and messages still
// waiting to be sent don't; this records them, and the next start resumes
// those sessions with a note telling Claude what happened.

import { chmodSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { BackgroundTask, QueuedMessage } from './session.js';

export interface Interrupted {
  id: string;
  /** A turn was running (or waiting for approval) when the process ended. */
  turn: boolean;
  /** Background work the process took with it. */
  tasks: BackgroundTask[];
  /** Messages accepted but not sent yet, oldest first. */
  queued: QueuedMessage[];
}

interface ResumeFile {
  stoppedAt: string;
  sessions: Interrupted[];
}

const FILE = 'resume.json';

export function saveInterrupted(dir: string, sessions: Interrupted[], stoppedAt = new Date()): void {
  const path = join(dir, FILE);
  if (!sessions.length) {
    rmSync(path, { force: true });
    return;
  }
  const body: ResumeFile = { stoppedAt: stoppedAt.toISOString(), sessions };
  // Message text can be private, as in server.json.
  writeFileSync(path + '.tmp', JSON.stringify(body), { mode: 0o600 });
  chmodSync(path + '.tmp', 0o600);
  renameSync(path + '.tmp', path);
}

/** Reads and removes what the last binaryd left, so it is resumed once. */
export function takeInterrupted(dir: string): { stoppedAt: string; sessions: Interrupted[] } | undefined {
  const path = join(dir, FILE);
  let raw: string;
  try {
    raw = readFileSync(path, 'utf8');
  } catch {
    return undefined;
  }
  rmSync(path, { force: true });
  try {
    const f = JSON.parse(raw) as Partial<ResumeFile>;
    const sessions = Array.isArray(f.sessions) ? f.sessions.filter((s) => s && typeof s.id === 'string') : [];
    return { stoppedAt: typeof f.stoppedAt === 'string' ? f.stoppedAt : '', sessions };
  } catch {
    return undefined;
  }
}

export const NOTE_TAG = 'binary-restart';

/** What Claude is told when its session is resumed after a restart. */
export function resumeNote(s: Interrupted, stoppedAt: string): string {
  const lines = [`Binary's server (binaryd) restarted${stoppedAt ? ` at ${stoppedAt}` : ''}, which ended the claude process this session ran in. This is a new process on the same conversation.`];
  if (s.turn) {
    lines.push(
      'Your last turn was cut off before it finished. Check where it stopped before going on, and do not repeat steps that already took effect (commits, pushes, messages sent, deploys). A command that was running when it was cut off may have been killed partway.',
    );
  }
  if (s.tasks.length) {
    lines.push('These background tasks were stopped with the old process:');
    for (const t of s.tasks) {
      const what = t.agentType ? `${t.type} (${t.agentType})` : t.type;
      lines.push(`- ${what}: ${t.description || '(no description)'}, started ${t.startedAt}`);
    }
    lines.push('Start again the ones you still need; if you were only waiting on them, set the wait up again.');
  }
  lines.push(s.turn ? 'Then carry on with the task.' : 'Then carry on as before.');
  return `<${NOTE_TAG}>\n${lines.join('\n')}\n</${NOTE_TAG}>`;
}
