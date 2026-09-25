#!/usr/bin/env node
// SPEC-12 — deployed-versus-repo drift for Edge Functions. Reads only; it never deploys.
//
// Exists because session 29 found `approve-booking` two versions behind its repo with a security hole in
// the gap, and because session 32 shipped a policy the booking site implemented twice. Supabase version
// numbers run ahead of the vault's count, so a deploy is identified by CONTENT, never by number.
//
// How the deployed source is fetched (verified on Lloyd's machine 2026-09-18, Docker NOT running):
//   npx supabase functions download <slug> --project-ref <ref> --use-api
// `--use-api` unbundles server-side, so no Docker is needed. It lands in <cwd>/supabase/functions/**, the
// same layout as the repo, so the comparison is a plain file walk. The CLI uses Lloyd's stored login, so no
// SUPABASE_ACCESS_TOKEN is needed and none is ever printed.
//
// ponytail: sequential downloads and pure file comparison. Parallelise only if this becomes a daily habit.
//
//   node scripts/check-deploy-drift.mjs [--only slug,slug] [--json] [--keep] [--selftest]
//
// ONE DOWNLOAD PER SLUG, always. `functions download` with no slug name is a trap: it serves STALE source.
// Proved 2026-09-18 - its messenger-concierge/booking.ts came back 37,363 bytes against HEAD's 39,543,
// missing that same day's deploy, and the bulk run reported false drift on eight functions while the
// per-slug run of the same function reported `in sync`. A drift tool that cries wolf is worse than none,
// so the fast path is gone. Budget roughly 15 s a function (about 8 minutes for all 30); use --only while
// iterating. Per-slug also attributes each _shared file to the function that actually bundles it.

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, existsSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { tmpdir } from 'node:os';

const PROJECT_REF = 'qkgfhsdppslwunarczeq';
const WAVES = join(import.meta.dirname, '..');
// Every function deploys from waves. last-readings did deploy from stay-site until session 45 (D-219) deployed
// it from waves; stay-site keeps a byte-identical mirror for its observability test. Map a slug here only if it
// really deploys from another repo.
const REPO_FOR = {};
// B41 + the 2026-09-18 baseline: every function verifies no JWT except these three.
const JWT_EXPECTED = new Set(['ocr-receipt', 'submit-cleaning', 'verify-meter-photo']);

const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : null; };
const ONLY = (opt('--only') ?? '').split(',').map((s) => s.trim()).filter(Boolean);

const sh = (cmd, cmdArgs, cwd) =>
  execFileSync(cmd, cmdArgs, { cwd, encoding: 'buffer', shell: process.platform === 'win32', maxBuffer: 64 << 20 });

const lf = (buf) => buf.toString('utf8').replace(/\r\n/g, '\n');
const hash = (buf) => createHash('sha256').update(lf(buf)).digest('hex');

/** Every file under dir, as paths relative to it, with forward slashes. */
function walk(dir, base = dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p, base, out);
    else out.push(relative(base, p).split(sep).join('/'));
  }
  return out;
}

/** The first line where two texts differ — the line number only, never the content (it may hold a secret). */
function firstDiffLine(a, b) {
  const A = lf(a).split('\n'), B = lf(b).split('\n');
  for (let i = 0; i < Math.max(A.length, B.length); i++) if (A[i] !== B[i]) return i + 1;
  return null;
}

function gitShow(repo, relPath) {
  try { return sh('git', ['-c', 'safe.directory=*', '-C', `"${repo}"`, 'show', `HEAD:${relPath}`]); }
  catch { return null; }
}

function download(dest, slug) {
  // Always name the slug: see the header - an unnamed download serves stale source.
  sh('npx', ['--yes', 'supabase@latest', 'functions', 'download', slug, '--project-ref', PROJECT_REF, '--use-api'], dest);
}

function listDeployed() {
  const raw = sh('npx', ['--yes', 'supabase@latest', 'functions', 'list', '--project-ref', PROJECT_REF, '-o', 'json']).toString('utf8');
  return JSON.parse(raw.slice(raw.indexOf('[')));
}

// ---- the comparison ------------------------------------------------------------------------------------

/** Compare one slug's downloaded tree (its own files plus the _shared files it bundles) against its repo. */
function compareSlug(downloadRoot, slug) {
  const fnRoot = join(downloadRoot, 'supabase', 'functions');
  const files = walk(fnRoot);
  {
    const repo = REPO_FOR[slug] ?? WAVES;
    const deployedDiffers = [], treeDirty = [], missingLocally = [];
    for (const rel of files.sort()) {
      const deployed = readFileSync(join(fnRoot, rel));
      const localPath = join(repo, 'supabase', 'functions', rel);
      const repoRel = `supabase/functions/${rel}`;
      if (!existsSync(localPath)) { missingLocally.push(rel); continue; }
      const tree = readFileSync(localPath);
      const head = gitShow(repo, repoRel);
      if (head && hash(head) !== hash(deployed)) deployedDiffers.push(`${rel}:${firstDiffLine(head, deployed) ?? '?'}`);
      else if (!head) missingLocally.push(`${rel} (not in HEAD)`);
      if (head && hash(head) !== hash(tree)) treeDirty.push(rel);
    }
    const status = missingLocally.length && missingLocally.length === files.length ? 'deployed only'
      : deployedDiffers.length ? 'deployed differs from HEAD'
      : treeDirty.length ? 'working tree dirty'
      : 'in sync';
    return { name: slug, status, files: files.length, deployedDiffers, treeDirty, missingLocally };
  }
}

// ---- self-test -----------------------------------------------------------------------------------------

function selftest() {
  const a = Buffer.from('const x = 1;\nconst y = 2;\n');
  const bSame = Buffer.from('const x = 1;\r\nconst y = 2;\r\n');      // CRLF only: must NOT be reported
  const bDiff = Buffer.from('const x = 1;\nconst y = 3;\n');          // one character: MUST be reported
  const checks = [
    ['CRLF-only difference is ignored', hash(a) === hash(bSame)],
    ['one-character difference is caught', hash(a) !== hash(bDiff)],
    ['the differing line is named', firstDiffLine(a, bDiff) === 2],
    ['identical files report no line', firstDiffLine(a, bSame) === null],
  ];
  let ok = true;
  for (const [what, pass] of checks) { console.log(`${pass ? 'ok  ' : 'FAIL'} ${what}`); ok &&= pass; }
  return ok ? 0 : 1;
}

// ---- main ----------------------------------------------------------------------------------------------

if (flag('--selftest')) process.exit(selftest());

const deployed = listDeployed();
const slugs = ONLY.length ? ONLY : deployed.map((f) => f.slug);
const tmp = mkdtempSync(join(tmpdir(), 'cascade-drift-'));

const rows = [];
for (const [i, slug] of slugs.entries()) {
  if (!flag('--json')) process.stderr.write(`\r  downloading ${i + 1}/${slugs.length} ${slug}`.padEnd(58));
  const dest = join(tmp, slug);
  mkdirSync(dest, { recursive: true });
  download(dest, slug);
  rows.push(compareSlug(dest, slug));
}
if (!flag('--json')) process.stderr.write('\r'.padEnd(60) + '\r');

// Local folders that were never deployed.
const localSlugs = readdirSync(join(WAVES, 'supabase', 'functions'), { withFileTypes: true })
  .filter((e) => e.isDirectory() && e.name !== '_shared').map((e) => e.name);
for (const s of localSlugs) if (!deployed.some((f) => f.slug === s) && (!ONLY.length || ONLY.includes(s)))
  rows.push({ name: s, status: 'local only', files: 0, deployedDiffers: [], treeDirty: [], missingLocally: [] });

const jwtSurprises = deployed
  .filter((f) => Boolean(f.verify_jwt) !== JWT_EXPECTED.has(f.slug))
  .map((f) => `${f.slug}: verify_jwt=${f.verify_jwt} (expected ${JWT_EXPECTED.has(f.slug)})`);

if (flag('--json')) {
  console.log(JSON.stringify({ checked: new Date().toISOString(), rows, jwtSurprises }, null, 2));
} else {
  const w = Math.max(...rows.map((r) => r.name.length), 8);
  console.log(`\nDeploy drift — project ${PROJECT_REF} — ${new Date().toISOString().slice(0, 16).replace('T', ' ')}Z\n`);
  for (const r of rows.sort((a, b) => (a.status === 'in sync') - (b.status === 'in sync') || a.name.localeCompare(b.name))) {
    const mark = r.status === 'in sync' || r.status === 'local only' ? ' ' : '!';
    console.log(`${mark} ${r.name.padEnd(w)}  ${r.status}${r.files ? `  (${r.files} files)` : ''}`);
    if (r.deployedDiffers.length) console.log(`    deployed differs: ${r.deployedDiffers.join(', ')}`);
    if (r.treeDirty.length)       console.log(`    tree dirty:       ${r.treeDirty.join(', ')}`);
    if (r.missingLocally.length)  console.log(`    no local source:  ${r.missingLocally.slice(0, 6).join(', ')}`);
  }
  if (jwtSurprises.length) { console.log('\n! verify_jwt changed from the baseline:'); for (const s of jwtSurprises) console.log(`    ${s}`); }
console.log(flag('--keep') ? `\n  downloaded to ${tmp}\n` : '');
}

const bad = rows.filter((r) => r.status !== 'in sync' && r.status !== 'local only').length + jwtSurprises.length;
process.exit(bad ? 1 : 0);
