// When a transcript last got a real message. The file's modification time
// moves for other reasons too: Claude Code re-appends the title, mode and
// last-prompt lines around a turn, and a rename or tag adds one more, so a
// session nobody has touched in days would read "just now".

import { closeSync, openSync, readSync, fstatSync } from 'node:fs';

const CHUNK = 256 * 1024;
const MAX_SCAN = 16 * 1024 * 1024;

/** Epoch ms of the last user or assistant line in the transcript, or 0 when none is found near its end. */
export function lastMessageAt(file: string): number {
  let fd: number;
  try {
    fd = openSync(file, 'r');
  } catch {
    return 0;
  }
  try {
    let end = fstatSync(fd).size;
    const floor = Math.max(0, end - MAX_SCAN);
    // Bytes after `end` that belong to a line whose start is not read yet.
    let carry = Buffer.alloc(0);
    while (end > floor) {
      const start = Math.max(floor, end - CHUNK);
      const buf = Buffer.alloc(end - start);
      readSync(fd, buf, 0, buf.length, start);
      const data = Buffer.concat([buf, carry]);
      const lines = data.toString('utf8').split('\n');
      // Without the file's start in hand, the first piece may be cut off.
      const rest = start > 0 ? lines.shift()! : '';
      for (let i = lines.length - 1; i >= 0; i--) {
        const at = messageTime(lines[i]);
        if (at) return at;
      }
      carry = Buffer.from(rest, 'utf8');
      end = start;
    }
    return 0;
  } catch {
    return 0;
  } finally {
    closeSync(fd);
  }
}

function messageTime(line: string): number {
  if (!line.includes('"type":"user"') && !line.includes('"type":"assistant"')) return 0;
  try {
    const o = JSON.parse(line) as { type?: string; timestamp?: string };
    if (o.type !== 'user' && o.type !== 'assistant') return 0;
    const t = o.timestamp ? Date.parse(o.timestamp) : NaN;
    return Number.isFinite(t) ? t : 0;
  } catch {
    return 0;
  }
}
