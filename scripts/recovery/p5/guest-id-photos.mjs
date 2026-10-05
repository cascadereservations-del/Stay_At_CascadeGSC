#!/usr/bin/env node
// SPEC-40: encrypted, incremental backup of the guest-id-photos Storage bucket, a monthly restore drill, a disaster restore,
// and the purge of photo objects that lost their last guest_companions reference.
//
//   node guest-id-photos.mjs backup            daily (Task Scheduler 08:20 Manila). New objects only; first run of a UTC month is a full set.
//   node guest-id-photos.mjs drill             monthly. Decrypts the newest chain in memory, checks coverage of the live bucket and the Alfred copy.
//   node guest-id-photos.mjs restore <outDir>  disaster only, Lloyd runs it. Decrypts the newest chain into a NEW folder.
//
// Layout (workstation, and the same set names on alfred:/opt/cascade/backups/guest-id-photos):
//   <CASCADE_BACKUP_DIR>/guest-id-photos/gip-<UTC>-full|incr/{objects/<companionId>/<uuid>.<ext>.enc, MANIFEST.json, SHA256SUMS, COMPLETE}
// Encryption: openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha512 -salt, ONE file per object, the same passphrase file as the
// database backups (supabase-backup-over-alfred.sh). The passphrase is never read, printed or copied here: only its path goes to openssl.
// Plaintext lives only in memory and in pipes. The service-role key is read into memory through the stored Supabase CLI login and is
// never written, logged or passed in an argument. Output is counts only, never an object name or a guest detail.
// To decrypt one file by hand:
//   openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha512 -pass file:%USERPROFILE%\Cascade-Secrets\supabase-backup-passphrase.txt -in X.jpg.enc -out X.jpg
// Env: CASCADE_BACKUP_DIR, CASCADE_SUPABASE_PASSPHRASE_FILE, CASCADE_SSH_BIN, CASCADE_SSH_HOST (alfred), CASCADE_TAR_BIN.
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROJECT_REF = 'qkgfhsdppslwunarczeq';
const SUPABASE_URL = `https://${PROJECT_REF}.supabase.co`;
const BUCKET = 'guest-id-photos';
const JOB_BACKUP = 'guest-id-photos-backup';
const JOB_DRILL = 'guest-id-photos-drill';
const REMOTE_DIR = '/opt/cascade/backups/guest-id-photos';
const PURGE_CAP = 20;
const COVERAGE_GRACE_MS = 26 * 3600 * 1000;
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';

export const SET_RE = /^gip-(\d{8}T\d{6}Z)-(full|incr)$/;
export const PHOTO_RE = new RegExp(`^${UUID}/${UUID}\\.(jpg|jpeg|png|webp)$`);
export const PLACEHOLDER_RE = new RegExp(`^${UUID}/\\.emptyFolderPlaceholder$`);

export class CodeError extends Error {
  constructor(code) { super(code); this.code = code; }
}

// ---------- pure helpers (unit-tested) ----------

export const sha256hex = (buf) => createHash('sha256').update(buf).digest('hex');

/** Git Bash hands native node '/c/Users/..' paths; node on Windows needs 'C:/Users/..'. */
export function toWinPath(p) {
  const m = /^\/([a-zA-Z])\/(.*)$/.exec(p);
  return m ? `${m[1].toUpperCase()}:/${m[2]}` : p;
}
const nativePath = (p) => (process.platform === 'win32' ? toWinPath(p) : p);

const norm = (p) => resolve(p).replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
export function isInside(dir, parent) {
  const d = norm(dir);
  const p = norm(parent);
  return d === p || d.startsWith(`${p}/`);
}

export function stampOf(date) {
  return date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
}
const monthOfName = (name) => `${name.slice(4, 8)}-${name.slice(8, 10)}`;
const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);

/** The set plus every complete incr set that names it as base. Sets: {name, kind, base, complete, objects:[{path}]}. */
export function chainSets(sets, full) {
  return [full, ...sets.filter((s) => s.complete && s.kind === 'incr' && s.base === full.name)].sort(byName);
}
export function chainUnion(sets, full) {
  return new Set(chainSets(sets, full).flatMap((s) => s.objects.map((o) => o.path)));
}
export function newestChain(sets) {
  const fulls = sets.filter((s) => s.complete && s.kind === 'full').sort(byName);
  if (!fulls.length) return null;
  const full = fulls[fulls.length - 1];
  return { full, sets: chainSets(sets, full) };
}

/**
 * What this run must back up. live: [{path, bytes}]. Returns null when there is nothing to write.
 * Only COMPLETE sets count: a path that sits only in an INCOMPLETE set is not backed up.
 */
export function planRun(live, sets, now = new Date()) {
  const complete = sets.filter((s) => s.complete);
  const month = now.toISOString().slice(0, 7);
  const fulls = complete.filter((s) => s.kind === 'full' && monthOfName(s.name) === month).sort(byName);
  if (!fulls.length) return live.length ? { kind: 'full', base: null, todo: [...live] } : null;
  const full = fulls[fulls.length - 1];
  const have = chainUnion(complete, full);
  const todo = live.filter((o) => !have.has(o.path));
  return todo.length ? { kind: 'incr', base: full.name, todo } : null;
}

/**
 * Set names to delete: keep the newest two COMPLETE chains. Never prune with fewer than two COMPLETE fulls.
 * A set without COMPLETE is never counted and never pruned, so the next run retries it.
 */
export function pruneSets(sets) {
  const complete = sets.filter((s) => s.complete);
  const fulls = complete.filter((s) => s.kind === 'full').map((s) => s.name).sort().reverse();
  if (fulls.length < 2) return [];
  const keep = new Set(fulls.slice(0, 2));
  const oldestKept = fulls[1];
  return complete
    .filter((s) => (s.kind === 'full'
      ? !keep.has(s.name)
      : !(keep.has(s.base) || (!fulls.includes(s.base) && s.name > oldestKept))))
    .map((s) => s.name);
}

/** due paths that may be deleted now: a placeholder (0 bytes, nothing to keep) or a path already in the mirrored chain; capped. */
export function purgeAllowed(due, backedUp, cap = PURGE_CAP) {
  return due.filter((p) => PLACEHOLDER_RE.test(p) || (PHOTO_RE.test(p) && backedUp.has(p))).slice(0, cap);
}

export function buildSums(entries) {
  return entries.map((e) => `${e.hash}  ${e.rel}\n`).join('');
}
const SUMS_LINE = /^([0-9a-f]{64}) {2}(objects\/[0-9a-f/-]+\.[a-z]+\.enc)$/;
/** Reads dir/SHA256SUMS and rehashes every file. Returns {ok, count}. */
export function verifySums(dir) {
  const lines = readFileSync(join(dir, 'SHA256SUMS'), 'utf8').split('\n').filter(Boolean);
  let ok = lines.length > 0;
  for (const line of lines) {
    const m = SUMS_LINE.exec(line);
    if (!m || !existsSync(join(dir, m[2])) || sha256hex(readFileSync(join(dir, m[2]))) !== m[1]) ok = false;
  }
  return { ok, count: lines.length };
}

const OPENSSL_BASE = ['enc', '-aes-256-cbc', '-pbkdf2', '-iter', '600000', '-md', 'sha512'];
function openssl(extra, buf, passFile, code) {
  const r = spawnSync('openssl', [...OPENSSL_BASE, ...extra, '-pass', `file:${passFile}`], { input: buf, maxBuffer: 256 * 1024 * 1024 });
  if (r.status !== 0 || !r.stdout || r.stdout.length === 0) throw new CodeError(code);
  return r.stdout;
}
export const encryptBuffer = (buf, passFile) => openssl(['-salt'], buf, passFile, 'ENCRYPT');
export const decryptBuffer = (buf, passFile) => openssl(['-d'], buf, passFile, 'DECRYPT');

/**
 * Lists the bucket through listPage(prefix, offset) -> array. Loops until a page is EMPTY (a server cap below the requested limit
 * cannot silently truncate the result). Folders have id null. Any name that is not <uuid>/<uuid>.<ext> stops the run: ODD_NAME.
 * Returns {live: [{path, bytes, createdAt}], all: Set of every object path including placeholders}.
 */
export async function collectLive(listPage) {
  const listAll = async (prefix) => {
    const out = [];
    for (let offset = 0; ;) {
      const page = await listPage(prefix, offset);
      if (!Array.isArray(page)) throw new CodeError('LIST');
      if (page.length === 0) return out;
      out.push(...page);
      offset += page.length;
      if (offset > 100000) throw new CodeError('LIST');
    }
  };
  const live = [];
  const all = new Set();
  let odd = 0;
  for (const top of await listAll('')) {
    if (top.id != null) { odd += 1; continue; }
    for (const e of await listAll(`${top.name}/`)) {
      if (e.id == null) { odd += 1; continue; }
      const path = `${top.name}/${e.name}`;
      all.add(path);
      if (PLACEHOLDER_RE.test(path)) continue;
      const bytes = e.metadata?.size;
      if (!PHOTO_RE.test(path)) { odd += 1; continue; }
      if (!Number.isInteger(bytes) || bytes < 0 || !e.created_at) throw new CodeError('LIST');
      live.push({ path, bytes, createdAt: e.created_at });
    }
  }
  if (odd > 0) throw new CodeError('ODD_NAME');
  return { live, all };
}

// ---------- disk ----------

export function readSets(root) {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true })
    .filter((d) => d.isDirectory() && SET_RE.test(d.name))
    .map((d) => {
      const dir = join(root, d.name);
      const kind = SET_RE.exec(d.name)[2];
      let complete = existsSync(join(dir, 'COMPLETE')) && !existsSync(join(dir, 'INCOMPLETE'));
      let objects = [];
      let base = kind === 'full' ? d.name : null;
      if (complete) {
        try {
          const m = JSON.parse(readFileSync(join(dir, 'MANIFEST.json'), 'utf8'));
          objects = m.objects.map((o) => ({ path: o.path, bytes: o.bytes, sha256: o.sha256 }));
          if (kind === 'incr') base = SET_RE.test(m.base ?? '') ? m.base : null;
        } catch { complete = false; }
      }
      return { name: d.name, dir, kind, base, complete, objects };
    })
    .sort(byName);
}

function decryptChain(chain, passFile, onFile) {
  let count = 0;
  for (const s of chain.sets) {
    for (const o of s.objects) {
      const plain = decryptBuffer(readFileSync(join(s.dir, 'objects', `${o.path}.enc`)), passFile);
      if (plain.length !== o.bytes || sha256hex(plain) !== o.sha256) throw new CodeError('DECRYPT');
      if (onFile) onFile(o.path, plain);
      count += 1;
    }
  }
  return count;
}

// ---------- network ----------

let serviceKey = null;

function fetchServiceKey() {
  const run = (extra) => spawnSync(`npx supabase projects api-keys --project-ref ${PROJECT_REF} -o json${extra}`, {
    shell: true, encoding: 'utf8', maxBuffer: 1 << 20,
  });
  const jwt = /^eyJ[\w-]+\.[\w-]+\.[\w-]+$/;
  for (const extra of ['', ' --reveal']) {
    const r = run(extra);
    let entry;
    try { entry = JSON.parse(r.stdout).find((k) => k.name === 'service_role'); } catch { throw new CodeError('KEY_FETCH'); }
    // No legacy service_role (only an sb_secret_ key) means the header rules differ: stop and ask Lloyd.
    if (!entry) throw new CodeError('KEY_FETCH');
    if (jwt.test(entry.api_key ?? '')) return entry.api_key;
  }
  throw new CodeError('KEY_FETCH');
}

async function api(method, path, body, code = 'NETWORK') {
  try {
    return await fetch(SUPABASE_URL + path, {
      method,
      headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(120000),
    });
  } catch { throw new CodeError(code); }
}

async function rpc(fn, args, code) {
  const res = await api('POST', `/rest/v1/rpc/${fn}`, args, code);
  if (!res.ok) throw new CodeError(code);
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

async function heartbeat(job, phase, errorCode = null) {
  await rpc('record_job_heartbeat', { p_job_name: job, p_phase: phase, p_error_code: errorCode }, 'HEARTBEAT');
}

async function listLive() {
  return collectLive(async (prefix, offset) => {
    const res = await api('POST', `/storage/v1/object/list/${BUCKET}`, {
      prefix, limit: 1000, offset, sortBy: { column: 'name', order: 'asc' },
    }, 'LIST');
    if (!res.ok) throw new CodeError('LIST');
    return res.json();
  });
}

// ---------- Alfred mirror (ciphertext only; Alfred never sees the passphrase) ----------

function sshTools(cfg) {
  const env = { ...process.env, MSYS_NO_PATHCONV: '1' };
  const opts = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20'];
  const run = (cmd) => spawnSync(cfg.sshBin, [...opts, cfg.sshHost, cmd], { encoding: 'utf8', env });
  const safe = (names) => { for (const n of names) if (!SET_RE.test(n)) throw new CodeError('MIRROR'); return names; };
  return {
    /** Set names on Alfred whose SHA256SUMS verify and that carry COMPLETE. */
    verified(names) {
      if (!names.length) return new Set();
      const r = run(`umask 077; mkdir -p ${REMOTE_DIR}; cd ${REMOTE_DIR} || exit 0; for s in ${safe(names).join(' ')}; do (cd "$s" 2>/dev/null && test -f COMPLETE && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 && echo "OK $s"); done; exit 0`);
      if (r.status !== 0) throw new CodeError('MIRROR');
      return new Set(r.stdout.split('\n').filter((l) => l.startsWith('OK ')).map((l) => l.slice(3).trim()));
    },
    send(name) {
      safe([name]);
      return new Promise((done, fail) => {
        const tar = spawn(cfg.tarBin, ['-cf', '-', name], { cwd: cfg.root, stdio: ['ignore', 'pipe', 'ignore'] });
        const sh = spawn(cfg.sshBin, [...opts, cfg.sshHost, `umask 077 && mkdir -p ${REMOTE_DIR} && rm -rf ${REMOTE_DIR}/${name} && tar -xf - -C ${REMOTE_DIR}`],
          { stdio: ['pipe', 'ignore', 'ignore'], env });
        let tarCode = null;
        let shCode = null;
        const settle = () => { if (tarCode !== null && shCode !== null) (tarCode === 0 && shCode === 0 ? done() : fail(new CodeError('MIRROR'))); };
        sh.stdin.on('error', () => {});
        tar.stdout.pipe(sh.stdin);
        tar.on('error', () => fail(new CodeError('MIRROR')));
        sh.on('error', () => fail(new CodeError('MIRROR')));
        tar.on('close', (c) => { tarCode = c; settle(); });
        sh.on('close', (c) => { shCode = c; settle(); });
      });
    },
    remove(name) {
      safe([name]);
      if (run(`rm -rf ${REMOTE_DIR}/${name}`).status !== 0) throw new CodeError('PRUNE');
    },
  };
}

// ---------- backup ----------

async function writeSet(cfg, plan, now) {
  const name = `gip-${stampOf(now)}-${plan.kind}`;
  const dir = join(cfg.root, name);
  mkdirSync(join(dir, 'objects'), { recursive: true });
  writeFileSync(join(dir, 'INCOMPLETE'), 'Backup has not completed.\n');
  try {
    const objects = [];
    const sums = [];
    let bytes = 0;
    for (const o of plan.todo) {
      const res = await api('GET', `/storage/v1/object/${BUCKET}/${o.path.split('/').map(encodeURIComponent).join('/')}`, undefined, 'DOWNLOAD');
      if (!res.ok) throw new CodeError('DOWNLOAD');
      const plain = Buffer.from(await res.arrayBuffer());
      if (plain.length !== o.bytes) throw new CodeError('SIZE_MISMATCH');
      const sha = sha256hex(plain);
      const cipher = encryptBuffer(plain, cfg.passFile);
      // Decrypt it back now: a bad passphrase file is caught today, not at restore time.
      let back;
      try { back = decryptBuffer(cipher, cfg.passFile); } catch { throw new CodeError('ENCRYPT_VERIFY'); }
      if (sha256hex(back) !== sha) throw new CodeError('ENCRYPT_VERIFY');
      const rel = `objects/${o.path}.enc`;
      mkdirSync(dirname(join(dir, rel)), { recursive: true });
      writeFileSync(join(dir, rel), cipher);
      objects.push({ path: o.path, bytes: plain.length, sha256: sha });
      sums.push({ hash: sha256hex(cipher), rel });
      bytes += plain.length;
    }
    writeFileSync(join(dir, 'MANIFEST.json'), `${JSON.stringify({ kind: plan.kind, base: plan.base ?? name, created_at_utc: now.toISOString(), objects }, null, 2)}\n`);
    writeFileSync(join(dir, 'SHA256SUMS'), buildSums(sums));
    rmSync(join(dir, 'INCOMPLETE'));
    writeFileSync(join(dir, 'COMPLETE'), `${stampOf(now)}\n`);
    return { name, bytes, count: objects.length };
  } catch (e) {
    if (SET_RE.test(name)) rmSync(dir, { recursive: true, force: true });
    throw e;
  }
}

async function purge(all, backedUp) {
  const status = await rpc('guest_id_photo_purge_status_v1', {}, 'PURGE');
  const due = Array.isArray(status?.due) ? status.due : [];
  const allowed = purgeAllowed(due, backedUp);
  // A due path whose object is already gone only needs its queue row cleared (the RPC re-checks storage.objects itself).
  const gone = due.filter((p) => !all.has(p) && !allowed.includes(p) && (PHOTO_RE.test(p) || PLACEHOLDER_RE.test(p)));
  let purged = 0;
  if (allowed.length) {
    const res = await api('DELETE', `/storage/v1/object/${BUCKET}`, { prefixes: allowed }, 'PURGE');
    if (!res.ok) throw new CodeError('PURGE');
    purged = await rpc('guest_id_photo_purge_done_v1', { p_paths: allowed }, 'PURGE');
  }
  const cleared = gone.length ? await rpc('guest_id_photo_purge_done_v1', { p_paths: gone }, 'PURGE') : 0;
  return {
    purged, cleared,
    dueNotBackedUp: due.length - allowed.length - gone.length,
    queuedNotDue: Math.max(0, Number(status?.queued ?? 0) - due.length),
  };
}

async function backupBody(cfg) {
  const now = new Date();
  const { live, all } = await listLive();
  if (live.length === 0) throw new CodeError('LIST_EMPTY');
  let sets = readSets(cfg.root);
  const plan = planRun(live, sets, now);
  const made = plan ? await writeSet(cfg, plan, now) : null;
  if (made) sets = readSets(cfg.root);

  const doomed = new Set(pruneSets(sets));
  const keepNames = sets.filter((s) => s.complete && !doomed.has(s.name)).map((s) => s.name);
  const remote = sshTools(cfg);
  let ok = remote.verified(keepNames);
  for (const n of keepNames.filter((x) => !ok.has(x))) await remote.send(n);
  ok = remote.verified(keepNames);
  if (keepNames.some((n) => !ok.has(n))) throw new CodeError('MIRROR');

  for (const name of doomed) {
    if (!SET_RE.test(name)) throw new CodeError('PRUNE');
    remote.remove(name);
    rmSync(join(cfg.root, name), { recursive: true, force: true });
  }

  const chain = newestChain(sets.filter((s) => !doomed.has(s.name)));
  const backedUp = new Set(chain ? chain.sets.filter((s) => ok.has(s.name)).flatMap((s) => s.objects.map((o) => o.path)) : []);
  const p = await purge(all, backedUp);
  return [
    `kind=${made ? plan.kind : 'none'}`, `new=${made ? made.count : 0}`, `bytes=${made ? made.bytes : 0}`,
    `chain_objects=${backedUp.size}`, 'mirrored=yes', `pruned=${doomed.size}`, `purged=${p.purged}`,
    `cleared_gone=${p.cleared}`, `due_not_backed_up=${p.dueNotBackedUp}`, `queued_not_due=${p.queuedNotDue}`,
  ].join(' ');
}

// ---------- drill ----------

async function drillBody(cfg) {
  const chain = newestChain(readSets(cfg.root));
  if (!chain) throw new CodeError('NO_CHAIN');
  let manifestCount = 0;
  for (const s of chain.sets) {
    const sums = verifySums(s.dir);
    if (!sums.ok || sums.count !== s.objects.length) throw new CodeError('CHECKSUM');
    manifestCount += s.objects.length;
  }
  const decryptedOk = decryptChain(chain, cfg.passFile);
  if (decryptedOk !== manifestCount) throw new CodeError('DECRYPT');

  const { live } = await listLive();
  const have = new Set(chain.sets.flatMap((s) => s.objects.map((o) => o.path)));
  const uncovered = live.filter((o) => Date.now() - Date.parse(o.createdAt) > COVERAGE_GRACE_MS && !have.has(o.path)).length;
  if (uncovered > 0) throw new CodeError('UNCOVERED');

  const names = chain.sets.map((s) => s.name);
  const mirrorOk = sshTools(cfg).verified(names).size;
  if (mirrorOk !== names.length) throw new CodeError('MIRROR');

  const status = await rpc('guest_id_photo_purge_status_v1', {}, 'PURGE');
  return `drill PASS chain=${chain.full.name} sets=${names.length} objects=${manifestCount} decrypted_ok=${decryptedOk} uncovered=${uncovered} mirror_ok=${mirrorOk} unqueued_orphans=${Number(status?.unqueued_orphans ?? 0)}`;
}

// ---------- restore (disaster only) ----------

function restoreBody(cfg, outDirArg) {
  if (!outDirArg) throw new CodeError('USAGE');
  const out = resolve(nativePath(outDirArg));
  if (existsSync(out)) throw new CodeError('OUT_EXISTS');
  if (/onedrive/i.test(out) || isInside(out, cfg.repoRoot)) throw new CodeError('OUT_FORBIDDEN');
  for (let d = dirname(out); ; d = dirname(d)) {
    if (existsSync(join(d, '.git'))) throw new CodeError('OUT_FORBIDDEN');
    if (dirname(d) === d) break;
  }
  const chain = newestChain(readSets(cfg.root));
  if (!chain) throw new CodeError('NO_CHAIN');
  mkdirSync(out, { recursive: true });
  const n = decryptChain(chain, cfg.passFile, (path, plain) => {
    mkdirSync(join(out, dirname(path)), { recursive: true });
    writeFileSync(join(out, path), plain);
  });
  return `restore OK files=${n} sets=${chain.sets.length}`;
}

// ---------- entry ----------

function config() {
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
  const backupDir = nativePath(process.env.CASCADE_BACKUP_DIR || 'C:/Cascade-Backups');
  const passFile = nativePath(process.env.CASCADE_SUPABASE_PASSPHRASE_FILE || join(homedir(), 'Cascade-Secrets', 'supabase-backup-passphrase.txt'));
  const win = process.platform === 'win32';
  const sshDefault = win && existsSync('C:/Windows/System32/OpenSSH/ssh.exe') ? 'C:/Windows/System32/OpenSSH/ssh.exe' : 'ssh';
  // Refuse a backup dir inside the repo, a missing or empty passphrase file.
  if (isInside(backupDir, repoRoot)) throw new CodeError('BACKUP_DIR_IN_REPO');
  if (!existsSync(passFile) || readFileSync(passFile).length === 0) throw new CodeError('PASSPHRASE_FILE');
  const root = join(backupDir, 'guest-id-photos');
  mkdirSync(root, { recursive: true });
  return {
    repoRoot, root, passFile,
    sshBin: nativePath(process.env.CASCADE_SSH_BIN || sshDefault),
    sshHost: process.env.CASCADE_SSH_HOST || 'alfred',
    tarBin: process.env.CASCADE_TAR_BIN || 'tar',
  };
}

const hbCode = (e) => (e instanceof CodeError ? e.code : 'UNEXPECTED').replace(/[^A-Z0-9_]/g, '_').slice(0, 64);

async function monitored(job, body) {
  serviceKey = fetchServiceKey();
  await heartbeat(job, 'started');
  try {
    const line = await body();
    await heartbeat(job, 'succeeded');
    return line;
  } catch (e) {
    try { await heartbeat(job, 'failed', hbCode(e)); } catch { /* the original failure is the one to report */ }
    throw e;
  }
}

async function main() {
  const [mode, arg] = process.argv.slice(2);
  try {
    if (!['backup', 'drill', 'restore'].includes(mode)) throw new CodeError('USAGE');
    const cfg = config();
    const line = mode === 'backup' ? await monitored(JOB_BACKUP, () => backupBody(cfg))
      : mode === 'drill' ? await monitored(JOB_DRILL, () => drillBody(cfg))
        : restoreBody(cfg, arg);
    console.log(line);
  } catch (e) {
    console.error(`guest-id-photos ${mode ?? ''} FAILED code=${e instanceof CodeError ? e.code : 'UNEXPECTED'}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && norm(process.argv[1]) === norm(fileURLToPath(import.meta.url))) await main();
