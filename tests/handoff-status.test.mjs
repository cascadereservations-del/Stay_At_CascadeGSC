import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';

const handoffUrl = new URL('../docs/handoff/COMPLETE-HANDOFF-2026-09-06.md', import.meta.url);
const statusUrl = new URL('../docs/handoff/cascade-project-status.html', import.meta.url);
const handoff = await readFile(handoffUrl, 'utf8');
const status = await readFile(statusUrl, 'utf8');

test('handoff states the production freeze, selected hosting, and human authority boundary', () => {
  assert.match(handoff, /Production posture:\*\* Frozen pending recovery, hosting, Module A/i);
  assert.match(handoff, /Portainer CE \+ separate n8n\/PostgreSQL stack is canonical/i);
  assert.match(handoff, /47\/47 pgTAP pass/i);
  assert.match(handoff, /Module D's Admin UI wiring remains/i);
  assert.match(handoff, /named human approves booking\/payment confirmation/i);
  assert.match(handoff, /AI, OCR, forecasts, classifications, and email evidence are advisory/i);
});

test('handoff covers every remaining module and wave', () => {
  for (const label of ['Module A', 'Module B', 'Module C', 'Module D', 'Module E']) {
    assert.match(handoff, new RegExp(label, 'i'), `missing ${label}`);
  }
  for (let wave = 2; wave <= 8; wave += 1) {
    assert.match(handoff, new RegExp(`Wave ${wave}`, 'i'), `missing Wave ${wave}`);
  }
});

test('every local Markdown link in the handoff resolves', () => {
  const links = [...handoff.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)]
    .map((match) => match[1].trim())
    .filter((href) => href && !href.startsWith('#') && !/^[a-z][a-z0-9+.-]*:/i.test(href));

  for (const href of links) {
    assert.ok(existsSync(new URL(href, handoffUrl)), `missing handoff target ${href}`);
  }
});

test('status page is offline, script-free, and explicit about authority', () => {
  assert.match(status, /Content-Security-Policy/);
  assert.doesNotMatch(status, /<script\b/i);
  assert.doesNotMatch(status, /\b(?:src|href)=["']https?:/i);
  assert.match(status, /Production[\s\S]*Frozen/i);
  assert.match(status, /Only a named authorized Finance reviewer/i);
  assert.match(status, /must never confirm payment or a booking/i);
});

test('every local link in the status page resolves', () => {
  const hrefs = [...status.matchAll(/<a\b[^>]*\bhref\s*=\s*(["'])(.*?)\1/gi)]
    .map((match) => match[2].trim())
    .filter((href) => href && !href.startsWith('#'));

  for (const href of hrefs) {
    assert.ok(existsSync(new URL(href, statusUrl)), `missing status-page target ${href}`);
  }
});

test('all status-page hash links resolve', () => {
  const ids = new Set([...status.matchAll(/\bid\s*=\s*(["'])(.*?)\1/gi)].map((match) => match[2]));
  const hashes = [...status.matchAll(/<a\b[^>]*\bhref\s*=\s*(["'])#(.*?)\1/gi)].map((match) => match[2]);
  for (const hash of hashes) {
    assert.ok(ids.has(hash), `missing status-page anchor #${hash}`);
  }
});
