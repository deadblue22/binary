import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { encode, parseLang, T, template, type Key } from '../src/i18n.js';

const zh = JSON.parse(readFileSync(new URL('../../locales/zh.json', import.meta.url), 'utf8')) as Record<string, string>;

test('parseLang', () => {
  assert.equal(parseLang('en'), 'en');
  assert.equal(parseLang('en-US,en;q=0.9'), 'en');
  assert.equal(parseLang('zh-Hans-CN'), 'zh');
  assert.equal(parseLang('fr, en;q=0.5'), 'en');
  assert.equal(parseLang('fr'), 'en');
  assert.equal(parseLang(undefined), 'en');
});

test('text renders per language, nested params included', () => {
  const t = T('initFailed', { detail: T('initTimeout'), stderr: '' });
  assert.equal(t.render('en'), 'claude failed to initialize: Timed out waiting for claude to initialize');
  assert.equal(t.render('zh'), zh.initFailed.replace('{detail}', zh.initTimeout).replace('{stderr}', ''));
  assert.equal(encode({ a: [T('thinking')], b: 'raw' }, 'en'), '{"a":["Thinking…"],"b":"raw"}');
});

test('translations cover every message, with the same placeholders', () => {
  const names = (t: string) => [...t.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
  for (const [key, text] of Object.entries(zh)) {
    const en = template(key as Key, 'en');
    assert.ok(en !== undefined, `zh.json has unknown key ${key}`);
    assert.deepEqual(names(text), names(en), `placeholders differ for ${key}`);
  }
  // The table was found and is used.
  const probe = T('thinking');
  assert.ok(probe.render('zh') !== probe.render('en'));
});
