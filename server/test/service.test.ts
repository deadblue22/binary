import assert from 'node:assert/strict';
import { test } from 'node:test';
import { launchdPlist, systemdUnit } from '../src/service.js';

test('service definitions', () => {
  const v = { node: '/usr/bin/node', script: '/opt/binaryd/dist/src/main.js', home: '/home/a/.binary', path: '/usr/bin:/bin', log: '/home/a/.binary/binaryd.log' };
  const plist = launchdPlist(v);
  assert.ok(plist.includes('<string>/usr/bin/node</string>') && plist.includes('<string>serve</string>'));
  const unit = systemdUnit(v);
  assert.ok(unit.includes('ExecStart="/usr/bin/node" "/opt/binaryd/dist/src/main.js" serve --home "/home/a/.binary"'), unit);
  assert.ok(unit.includes('Environment="PATH=/usr/bin:/bin"'));
});
