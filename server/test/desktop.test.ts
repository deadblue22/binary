import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync, mkdtempSync, realpathSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { harness, transcriptLine, writeTranscript } from './helpers.js';

function record(dir: string, local: string, fields: Record<string, unknown>): void {
  writeFileSync(join(dir, `${local}.json`), JSON.stringify({ sessionId: local, cwd: '/x', title: 't', ...fields }));
}

test('desktop app parent links and localized external activity', async () => {
  const desktop = join(realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-desktop-'))), 'org', 'account');
  mkdirSync(desktop, { recursive: true });
  const parent = randomUUID();
  const child = randomUUID();
  const orphan = randomUUID();
  const h = await harness({ desktopDir: join(desktop, '..', '..'), agents: [{ pid: 1, cwd: '/x', kind: 'interactive', sessionId: parent, status: 'busy' }] });
  try {
    for (const id of [parent, child, orphan]) {
      const u = randomUUID();
      writeTranscript(h.configDir, h.cwd, id, [transcriptLine(id, h.cwd, u, null, 'user', `prompt ${id.slice(0, 4)}`)]);
    }
    record(desktop, 'local_parent', { cliSessionId: parent });
    record(desktop, 'local_child', { cliSessionId: child, spawnedFrom: { sessionId: 'local_parent', title: 'p' } });
    // Parent record exists but its session is not one binaryd knows.
    record(desktop, 'local_ghost', { cliSessionId: randomUUID() });
    record(desktop, 'local_orphan', { cliSessionId: orphan, spawnedFrom: { sessionId: 'local_ghost' } });
    writeFileSync(join(desktop, 'local_broken.json'), '{not json');

    await h.manager.refreshList();
    await h.manager.refreshAgents();
    h.manager.refreshDesktop();
    assert.equal(h.manager.summary(child)?.parentId, parent);
    assert.equal(h.manager.summary(orphan)?.parentId, undefined);
    assert.equal(h.manager.summary(parent)?.parentId, undefined);

    // The same summary reads in each subscriber's language.
    const en: string[] = [];
    const zh: string[] = [];
    h.manager.subscribeGlobal((_t, d) => (en.push(d), true), 'en');
    h.manager.subscribeGlobal((_t, d) => (zh.push(d), true), 'zh');
    const find = (data: string) => (JSON.parse(data) as { sessions: { id: string; activity?: string }[] }).sessions.find((s) => s.id === parent);
    assert.equal(find(en[0])?.activity, 'Running in another app');
    assert.ok(find(zh[0])?.activity && find(zh[0])?.activity !== 'Running in another app');
  } finally {
    await h.close();
  }
});


test('sessions that cannot run here: SSH hosts and missing folders', async () => {
  const desktop = join(realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-desktop-'))), 'org', 'account');
  mkdirSync(desktop, { recursive: true });
  const h = await harness({ desktopDir: join(desktop, '..', '..') });
  try {
    const remote = randomUUID();
    const gone = randomUUID();
    const here = randomUUID();
    const missing = join(h.root, 'not-here');
    // The desktop app mirrors an SSH session's transcript under its remote cwd.
    writeTranscript(h.configDir, '/home/claude/dev/x', remote, [transcriptLine(remote, '/home/claude/dev/x', randomUUID(), null, 'user', 'remote')]);
    writeTranscript(h.configDir, missing, gone, [transcriptLine(gone, missing, randomUUID(), null, 'user', 'gone')]);
    writeTranscript(h.configDir, h.cwd, here, [transcriptLine(here, h.cwd, randomUUID(), null, 'user', 'here')]);
    record(desktop, 'local_remote', { cliSessionId: remote, sshConfig: { sshHost: 'devbox' } });
    record(desktop, 'local_here', { cliSessionId: here, sshConfig: {} });

    await h.manager.refreshList();
    h.manager.refreshDesktop();
    const r = h.manager.summary(remote);
    assert.equal(r?.sshHost, 'devbox');
    assert.equal(r?.cwdExists, false);
    assert.equal(h.manager.cannotRun(remote)?.render('en'), 'This session runs on SSH host devbox through the Claude desktop app; it can only be viewed here');

    assert.equal(h.manager.summary(gone)?.sshHost, undefined);
    assert.equal(h.manager.summary(gone)?.cwdExists, false);
    assert.equal(h.manager.cannotRun(gone)?.render('en'), `Working directory does not exist: ${missing}`);

    assert.equal(h.manager.summary(here)?.sshHost, undefined);
    assert.equal(h.manager.summary(here)?.cwdExists, true);
    assert.equal(h.manager.cannotRun(here), undefined);

    // Sending is refused up front instead of failing to start claude.
    await assert.rejects(h.manager.session(remote)!.send('hi'), /SSH host devbox/);
  } finally {
    await h.close();
  }
});

test("the desktop app's permission mode applies until Binary picks one, and its later changes win", async () => {
  const desktop = join(realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-desktop-'))), 'org', 'account');
  mkdirSync(desktop, { recursive: true });
  const h = await harness({ desktopDir: join(desktop, '..', '..') });
  try {
    const id = randomUUID();
    writeTranscript(h.configDir, h.cwd, id, [transcriptLine(id, h.cwd, randomUUID(), null, 'user', 'hi')]);
    const file = join(desktop, 'local_m.json');
    record(desktop, 'local_m', { cliSessionId: id, permissionMode: 'bypassPermissions' });
    await h.manager.refreshList();
    h.manager.refreshDesktop();
    assert.equal(h.manager.summary(id)?.permissionMode, 'bypassPermissions');
    assert.equal((await h.manager.queryOptions(h.manager.session(id)!)).permissionMode, 'bypassPermissions');

    await h.manager.update(id, { permissionMode: 'plan' });
    assert.equal(h.manager.summary(id)?.permissionMode, 'plan');

    // Changed in the desktop app afterwards (a new mtime makes it re-read).
    record(desktop, 'local_m', { cliSessionId: id, permissionMode: 'acceptEdits' });
    const later = new Date(Date.now() + 5000);
    utimesSync(file, later, later);
    h.manager.refreshDesktop();
    assert.equal(h.manager.summary(id)?.permissionMode, 'acceptEdits');
  } finally {
    await h.close();
  }
});

test("a session that cd'd into a folder that's gone runs in the desktop app's folder", async () => {
  const desktop = join(realpathSync(mkdtempSync(join(tmpdir(), 'binaryd-desktop-'))), 'org', 'account');
  mkdirSync(desktop, { recursive: true });
  const h = await harness({ desktopDir: join(desktop, '..', '..') });
  try {
    const id = randomUUID();
    const gone = join(h.root, 'worktree-removed');
    const u = randomUUID();
    // Stored under the folder it started in; its latest cwd is a removed worktree.
    writeTranscript(h.configDir, h.cwd, id, [
      transcriptLine(id, gone, u, null, 'user', 'start'),
      transcriptLine(id, gone, randomUUID(), u, 'assistant', 'now elsewhere'),
    ]);
    record(desktop, 'local_w', { cliSessionId: id, cwd: h.cwd });
    await h.manager.refreshList();
    assert.equal(h.manager.summary(id)?.cwdExists, false, 'without the desktop record it looks gone');
    h.manager.refreshDesktop();
    const sum = h.manager.summary(id)!;
    assert.equal(sum.cwd, h.cwd);
    assert.equal(sum.cwdExists, true);
    assert.equal(h.manager.cannotRun(id), undefined);
    assert.equal((await h.manager.queryOptions(h.manager.session(id)!)).cwd, h.cwd);
  } finally {
    await h.close();
  }
});
