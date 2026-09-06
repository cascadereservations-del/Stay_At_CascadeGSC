import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';

const handoffUrl = new URL('../docs/handoff/COMPLETE-HANDOFF-P3-2026-09-06.md', import.meta.url);
const statusUrl = new URL('../docs/handoff/cascade-phase-status-p3.html', import.meta.url);
const resumeUrl = new URL('../docs/handoff/RESUME-PROMPT-P3.md', import.meta.url);
const handoff = await readFile(handoffUrl, 'utf8');
const status = await readFile(statusUrl, 'utf8');
const resume = await readFile(resumeUrl, 'utf8');

test('handoff states the verified P3 posture, next phase, and human authority boundary', () => {
  assert.match(handoff, /Live posture:\*\* P0–P3 complete\. P4 has not started/i);
  assert.match(handoff, /P1 — Recovery and deployment packet \| \*\*Complete\*\*/i);
  assert.match(handoff, /P2 — Host protection and fresh baseline \| \*\*Complete\*\*/i);
  assert.match(handoff, /P3 — Dormant Cascade stack \| \*\*Complete\*\*/i);
  assert.match(handoff, /P4 — Recovery drill and 72-hour soak \| \*\*Not started\*\*/i);
  assert.match(handoff, /Portainer CE on Alfred with a separate capped Compose stack is canonical/i);
  assert.match(handoff, /Module C \| 47 rollback-only pgTAP assertions/i);
  assert.match(handoff, /Connect Module D's Finance-only review UI in its owning product repository/i);
  assert.match(handoff, /named human approves booking\/payment confirmation/i);
  assert.match(handoff, /AI, OCR, forecasts, classifications and email evidence are advisory/i);
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

test('status page is offline, script-free, and shows the post-P3 phase boundary', () => {
  assert.match(status, /Content-Security-Policy/);
  assert.doesNotMatch(status, /<script\b/i);
  assert.doesNotMatch(status, /\b(?:src|href)=["']https?:/i);
  assert.match(status, /<strong>P0–P3<\/strong>/i);
  assert.match(status, /P4 has not started/i);
  assert.match(status, /72-hour/i);
  assert.match(status, /Named humans decide/i);
  assert.match(status, /Supabase is canonical/i);
});

test('resume prompt preserves the exact continuation gate and workspace exclusions', () => {
  assert.match(resume, /P0–P3 are complete/i);
  assert.match(resume, /P4 has not started/i);
  assert.match(resume, /P2 2049 MiB swap, persistence and full host baseline: COMPLETE/i);
  assert.match(resume, /13 workflows, zero active workflows, zero credentials/i);
  assert.match(resume, /Task Master/i);
  assert.match(resume, /fresh owner approval/i);
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
