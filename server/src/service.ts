// Installs binaryd as a per-user background service: launchd on macOS,
// systemd --user on Linux. The current PATH is captured so claude and the
// tools it runs resolve like in a terminal.

import { execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

const LABEL = 'dev.binary.binaryd';

function xml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export interface ServiceVars {
  node: string;
  script: string;
  home: string;
  path: string;
  log: string;
}

export function launchdPlist(v: ServiceVars): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xml(v.node)}</string>
    <string>${xml(v.script)}</string>
    <string>serve</string>
    <string>--home</string>
    <string>${xml(v.home)}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>${xml(v.path)}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ExitTimeOut</key><integer>60</integer>
  <key>StandardOutPath</key><string>${xml(v.log)}</string>
  <key>StandardErrorPath</key><string>${xml(v.log)}</string>
</dict>
</plist>
`;
}

export function systemdUnit(v: ServiceVars): string {
  const q = (s: string) => `"${s.replace(/(["\\])/g, '\\$1')}"`;
  return `[Unit]
Description=Binary server for Claude Code sessions
After=network-online.target

[Service]
ExecStart=${q(v.node)} ${q(v.script)} serve --home ${q(v.home)}
Environment=${q('PATH=' + v.path)}
Restart=on-failure
RestartSec=3
# Signal binaryd alone first: it lets running turns end, then stops its claude processes.
KillMode=mixed
TimeoutStopSec=60

[Install]
WantedBy=default.target
`;
}

/** Runs a service command; unchecked ones (stopping what may not be running) stay quiet. */
function run(cmd: string, args: string[], check = true): void {
  try {
    execFileSync(cmd, args, { stdio: check ? 'inherit' : 'ignore' });
  } catch (err) {
    if (check) throw err;
  }
}

export function service(action: string, home: string, script: string): void {
  const vars: ServiceVars = {
    node: process.execPath,
    script,
    home,
    path: process.env.PATH ?? '/usr/bin:/bin',
    log: join(home, 'binaryd.log'),
  };
  if (process.platform === 'darwin') {
    const plist = join(homedir(), 'Library', 'LaunchAgents', `${LABEL}.plist`);
    const domain = `gui/${process.getuid?.() ?? 501}`;
    if (action === 'install') {
      mkdirSync(dirname(plist), { recursive: true });
      run('launchctl', ['bootout', `${domain}/${LABEL}`], false);
      writeFileSync(plist, launchdPlist(vars));
      run('launchctl', ['bootstrap', domain, plist]);
      console.log(`installed ${plist}\nlogs: ${vars.log}`);
    } else if (action === 'uninstall') {
      run('launchctl', ['bootout', `${domain}/${LABEL}`], false);
      rmSync(plist, { force: true });
      console.log('uninstalled');
    } else {
      throw new Error(`unknown service action "${action}"`);
    }
  } else if (process.platform === 'linux') {
    const unit = join(homedir(), '.config', 'systemd', 'user', 'binaryd.service');
    if (action === 'install') {
      mkdirSync(dirname(unit), { recursive: true });
      writeFileSync(unit, systemdUnit(vars));
      run('systemctl', ['--user', 'daemon-reload']);
      run('systemctl', ['--user', 'enable', '--now', 'binaryd']);
      run('systemctl', ['--user', 'restart', 'binaryd']); // pick up new code if it was running
      console.log(`installed ${unit}\nlogs: journalctl --user -u binaryd -f`);
      console.log('to keep it running after logout: sudo loginctl enable-linger $USER');
    } else if (action === 'uninstall') {
      run('systemctl', ['--user', 'disable', '--now', 'binaryd'], false);
      rmSync(unit, { force: true });
      run('systemctl', ['--user', 'daemon-reload'], false);
      console.log('uninstalled');
    } else {
      throw new Error(`unknown service action "${action}"`);
    }
  } else {
    throw new Error(`service install is not supported on ${process.platform}`);
  }
}
