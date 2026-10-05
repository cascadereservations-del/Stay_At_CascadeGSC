import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import {
  CodeError, buildSums, collectLive, decryptBuffer, encryptBuffer, isInside, newestChain, planRun, pruneSets,
  purgeAllowed, readSets, sha256hex, toWinPath, verifySums,
} from '../../scripts/recovery/p5/guest-id-photos.mjs';

const SCRIPT = new URL('../../scripts/recovery/p5/guest-id-photos.mjs', import.meta.url);
const U = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const photo = (c, p) => `${U(c)}/${U(p)}.jpg`;
const live = (...paths) => paths.map((path) => ({ path, bytes: 10 }));
const set = (name, paths, complete = true, base = null) => ({
  name, kind: name.endsWith('-full') ? 'full' : 'incr', base: name.endsWith('-full') ? name : base, complete, objects: paths.map((path) => ({ path })),
});
const OCT = new Date('2026-10-05T00:20:00Z');

test('planRun: no sets gives a full with every live path', () => {
  const l = live(photo(1, 1), photo(2, 2));
  const plan = planRun(l, [], OCT);
  assert.equal(plan.kind, 'full');
  assert.equal(plan.base, null);
  assert.deepEqual(plan.todo.map((o) => o.path), [photo(1, 1), photo(2, 2)]);
});

test('planRun: same-month full plus 2 new gives an incr with exactly those 2', () => {
  const full = set('gip-20261001T002000Z-full', [photo(1, 1), photo(2, 2)]);
  const plan = planRun(live(photo(1, 1), photo(2, 2), photo(3, 3), photo(4, 4)), [full], OCT);
  assert.equal(plan.kind, 'incr');
  assert.equal(plan.base, full.name);
  assert.deepEqual(plan.todo.map((o) => o.path), [photo(3, 3), photo(4, 4)]);
});

test('planRun: an earlier incr in the chain counts as backed up', () => {
  const full = set('gip-20261001T002000Z-full', [photo(1, 1)]);
  const incr = set('gip-20261002T002000Z-incr', [photo(2, 2)], true, full.name);
  assert.equal(planRun(live(photo(1, 1), photo(2, 2)), [full, incr], OCT), null);
});

test('planRun: a new UTC month gives a full again', () => {
  const sep = set('gip-20260930T002000Z-full', [photo(1, 1)]);
  const plan = planRun(live(photo(1, 1)), [sep], OCT);
  assert.equal(plan.kind, 'full');
  assert.equal(plan.todo.length, 1);
});

test('planRun: nothing new gives null (no set is written)', () => {
  const full = set('gip-20261001T002000Z-full', [photo(1, 1)]);
  assert.equal(planRun(live(photo(1, 1)), [full], OCT), null);
});

test('planRun: a path inside an INCOMPLETE set counts as NOT backed up', () => {
  const full = set('gip-20261001T002000Z-full', [photo(1, 1)]);
  const broken = set('gip-20261003T002000Z-incr', [photo(2, 2)], false, full.name);
  const plan = planRun(live(photo(1, 1), photo(2, 2)), [full, broken], OCT);
  assert.deepEqual(plan.todo.map((o) => o.path), [photo(2, 2)]);
  const onlyBroken = planRun(live(photo(2, 2)), [set('gip-20261001T002000Z-full', [photo(2, 2)], false)], OCT);
  assert.equal(onlyBroken.kind, 'full');
});

test('pruneSets: three chains keeps the newest two', () => {
  const sets = [
    set('gip-20260801T002000Z-full', [photo(1, 1)]),
    set('gip-20260805T002000Z-incr', [photo(2, 2)], true, 'gip-20260801T002000Z-full'),
    set('gip-20260901T002000Z-full', [photo(1, 1)]),
    set('gip-20260902T002000Z-incr', [photo(3, 3)], true, 'gip-20260901T002000Z-full'),
    set('gip-20261001T002000Z-full', [photo(1, 1)]),
    set('gip-20261002T002000Z-incr', [photo(4, 4)], true, 'gip-20261001T002000Z-full'),
  ];
  assert.deepEqual(pruneSets(sets).sort(), ['gip-20260801T002000Z-full', 'gip-20260805T002000Z-incr']);
});

test('pruneSets: a single chain, or one full plus a stray, prunes nothing', () => {
  const one = [set('gip-20261001T002000Z-full', [photo(1, 1)]), set('gip-20261002T002000Z-incr', [photo(2, 2)], true, 'gip-20261001T002000Z-full')];
  assert.deepEqual(pruneSets(one), []);
  assert.deepEqual(pruneSets([...one, set('gip-20260901T002000Z-full', [], false)]), []);
});

test('pruneSets: a set without COMPLETE is never counted and never pruned', () => {
  const sets = [
    set('gip-20260801T002000Z-full', [photo(1, 1)]),
    set('gip-20260901T002000Z-full', [photo(1, 1)]),
    set('gip-20260915T002000Z-incr', [photo(2, 2)], false, 'gip-20260901T002000Z-full'),
    set('gip-20261001T002000Z-full', [photo(1, 1)], false),
  ];
  // The October full is incomplete, so only two complete fulls exist and the two newest are kept: nothing is pruned.
  assert.deepEqual(pruneSets(sets), []);
  const third = [...sets, set('gip-20261001T002000Z-full', [photo(1, 1)])].filter((s) => s.complete);
  assert.deepEqual(pruneSets([...third, set('gip-20260705T002000Z-incr', [], false, 'x')]), ['gip-20260801T002000Z-full']);
});

test('pruneSets: a stray complete incr older than the oldest kept chain goes, a newer one stays', () => {
  const sets = [
    set('gip-20260901T002000Z-full', []), set('gip-20261001T002000Z-full', []),
    set('gip-20260720T002000Z-incr', [], true, 'gip-20260701T002000Z-full'),
    set('gip-20260920T002000Z-incr', [], true, 'gip-20260801T002000Z-full'),
  ];
  assert.deepEqual(pruneSets(sets), ['gip-20260720T002000Z-incr']);
});

test('newestChain: the newest complete full and the complete incrs naming it', () => {
  const sets = [
    set('gip-20260901T002000Z-full', []), set('gip-20260902T002000Z-incr', [], true, 'gip-20260901T002000Z-full'),
    set('gip-20261001T002000Z-full', []), set('gip-20261003T002000Z-incr', [], true, 'gip-20261001T002000Z-full'),
    set('gip-20261004T002000Z-incr', [], false, 'gip-20261001T002000Z-full'),
  ];
  const chain = newestChain(sets);
  assert.equal(chain.full.name, 'gip-20261001T002000Z-full');
  assert.deepEqual(chain.sets.map((s) => s.name), ['gip-20261001T002000Z-full', 'gip-20261003T002000Z-incr']);
  assert.equal(newestChain([]), null);
});

test('purgeAllowed: due intersect (chain or placeholder), capped at 20', () => {
  const placeholder = `${U(50)}/.emptyFolderPlaceholder`;
  const inChain = photo(1, 1);
  const notInChain = photo(2, 2);
  const allowed = purgeAllowed([inChain, notInChain, placeholder], new Set([inChain]));
  assert.deepEqual(allowed, [inChain, placeholder]);
  const many = Array.from({ length: 30 }, (_, i) => photo(i + 100, i + 100));
  assert.equal(purgeAllowed(many, new Set(many)).length, 20);
  assert.deepEqual(purgeAllowed(['jane-doe/passport.jpg'], new Set(['jane-doe/passport.jpg'])), [], 'a path that is not uuid-shaped is never purged');
});

test('encrypt then decrypt a 2 KB buffer through the real openssl and compare the sha256', (t) => {
  if (spawnSync('openssl', ['version']).status !== 0) return t.skip('openssl is not installed');
  const dir = mkdtempSync(join(tmpdir(), 'gip-test-'));
  try {
    const pass = join(dir, 'pass.txt');
    writeFileSync(pass, 'test-passphrase-not-a-real-secret\n');
    const plain = Buffer.alloc(2048);
    for (let i = 0; i < plain.length; i += 1) plain[i] = (i * 31 + 7) & 255;
    const cipher = encryptBuffer(plain, pass);
    assert.equal(cipher.subarray(0, 8).toString('latin1'), 'Salted__');
    assert.notDeepEqual(cipher.subarray(16, 64), plain.subarray(0, 48));
    assert.equal(sha256hex(decryptBuffer(cipher, pass)), sha256hex(plain));
    const other = join(dir, 'other.txt');
    writeFileSync(other, 'a different passphrase\n');
    assert.throws(() => decryptBuffer(cipher, other), CodeError, 'a wrong passphrase must not decrypt');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('verifySums catches a tampered file; readSets tells COMPLETE from INCOMPLETE', () => {
  const root = mkdtempSync(join(tmpdir(), 'gip-sets-'));
  try {
    const mk = (name, { complete, incomplete, manifest }) => {
      const dir = join(root, name);
      mkdirSync(join(dir, 'objects', U(1)), { recursive: true });
      const body = Buffer.from('ciphertext-stand-in');
      writeFileSync(join(dir, 'objects', U(1), `${U(1)}.jpg.enc`), body);
      writeFileSync(join(dir, 'SHA256SUMS'), buildSums([{ hash: sha256hex(body), rel: `objects/${U(1)}/${U(1)}.jpg.enc` }]));
      if (manifest) writeFileSync(join(dir, 'MANIFEST.json'), JSON.stringify(manifest));
      if (complete) writeFileSync(join(dir, 'COMPLETE'), 'x');
      if (incomplete) writeFileSync(join(dir, 'INCOMPLETE'), 'x');
      return dir;
    };
    const good = mk('gip-20261001T002000Z-full', { complete: true, manifest: { kind: 'full', base: 'gip-20261001T002000Z-full', objects: [{ path: photo(1, 1), bytes: 3, sha256: 'a' }] } });
    mk('gip-20261002T002000Z-incr', { complete: true, incomplete: true, manifest: { kind: 'incr', base: 'gip-20261001T002000Z-full', objects: [] } });
    mk('gip-20261003T002000Z-incr', { complete: true, manifest: null });
    mkdirSync(join(root, 'not-a-set'));
    const sets = readSets(root);
    assert.deepEqual(sets.map((s) => [s.name, s.complete]), [
      ['gip-20261001T002000Z-full', true], ['gip-20261002T002000Z-incr', false], ['gip-20261003T002000Z-incr', false],
    ]);
    assert.deepEqual(verifySums(good), { ok: true, count: 1 });
    writeFileSync(join(good, 'objects', U(1), `${U(1)}.jpg.enc`), 'tampered');
    assert.equal(verifySums(good).ok, false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('collectLive: pages until an empty page, lists folders, skips placeholders, stops on an odd name', async () => {
  const objectsIn = { [`${U(1)}/`]: [
    { id: 'a', name: `${U(11)}.jpg`, created_at: '2026-10-01T00:00:00Z', metadata: { size: 5 } },
    { id: 'b', name: `${U(12)}.png`, created_at: '2026-10-02T00:00:00Z', metadata: { size: 6 } },
    { id: 'c', name: `${U(13)}.webp`, created_at: '2026-10-03T00:00:00Z', metadata: { size: 7 } },
  ], [`${U(2)}/`]: [{ id: 'p', name: '.emptyFolderPlaceholder', created_at: '2026-10-01T00:00:00Z', metadata: { size: 0 } }] };
  const root = [{ id: null, name: U(1) }, { id: null, name: U(2) }];
  // A server that caps every page at 2 entries, whatever limit was asked for: a "page shorter than limit" stop would lose the third.
  const listPage = async (prefix, offset) => (prefix === '' ? root : objectsIn[prefix]).slice(offset, offset + 2);
  const { live: found, all } = await collectLive(listPage);
  assert.deepEqual(found.map((o) => o.path), [photo(1, 11), `${U(1)}/${U(12)}.png`, `${U(1)}/${U(13)}.webp`]);
  assert.equal(found[1].bytes, 6);
  assert.ok(all.has(`${U(2)}/.emptyFolderPlaceholder`) && all.size === 4);

  objectsIn[`${U(1)}/`].push({ id: 'z', name: 'jane-doe-passport.jpg', created_at: '2026-10-04T00:00:00Z', metadata: { size: 1 } });
  await assert.rejects(collectLive(listPage), (e) => e instanceof CodeError && e.code === 'ODD_NAME');
});

test('isInside and toWinPath', () => {
  assert.ok(isInside('C:/repo/sub/dir', 'C:/repo'));
  assert.ok(isInside('C:\\Repo', 'c:/repo'));
  assert.ok(!isInside('C:/repo-other', 'C:/repo'));
  assert.ok(!isInside('C:/Cascade-Backups', 'C:/Users/Lloyd/Claude/Projects/Cascade/direct-booking-waves-0-1-sol'));
  assert.equal(toWinPath('/c/Users/Lloyd/x.txt'), 'C:/Users/Lloyd/x.txt');
  assert.equal(toWinPath('C:/already'), 'C:/already');
});

test('source scan: encryption settings, ordering, repo guard, key hygiene, single guarded DELETE', () => {
  const text = readFileSync(SCRIPT, 'utf8');
  for (const token of ["'-pbkdf2'", "'-iter'", "'600000'", "'-md'", "'sha512'", "'-salt'"]) assert.ok(text.includes(token), token);

  const sums = text.indexOf("writeFileSync(join(dir, 'SHA256SUMS')");
  const complete = text.indexOf("writeFileSync(join(dir, 'COMPLETE')");
  assert.ok(sums > 0 && complete > sums, 'COMPLETE is written after SHA256SUMS');
  assert.ok(text.indexOf("writeFileSync(join(dir, 'INCOMPLETE')") < sums, 'INCOMPLETE is written first');

  assert.match(text, /isInside\(backupDir, repoRoot\)[^\n]*BACKUP_DIR_IN_REPO/);
  assert.match(text, /PASSPHRASE_FILE/);

  const consoleLines = text.split('\n').filter((l) => /\bconsole\./.test(l));
  assert.ok(consoleLines.length > 0);
  assert.ok(consoleLines.every((l) => !/serviceKey/.test(l)), 'no console call references the key');
  assert.ok(!/spawn(Sync)?\([^)]*serviceKey/s.test(text), 'no spawn argument carries the key');
  assert.ok(!/process\.argv[^\n]*serviceKey|serviceKey[^\n]*process\.argv/.test(text));
  assert.ok(!/(writeFileSync|appendFileSync)\([^)]*serviceKey/.test(text), 'the key is never written to disk');
  assert.ok(!/passFile[^\n]*readFileSync\(.*toString/.test(text), 'the passphrase file is never read as text');

  const deletes = text.match(/'DELETE'/g) ?? [];
  assert.equal(deletes.length, 1, 'the Storage delete is the only DELETE');
  assert.ok(text.indexOf('purgeAllowed(due, backedUp)') > 0 && text.indexOf('purgeAllowed(due, backedUp)') < text.indexOf("'DELETE'"),
    'the chain filter runs before the delete');
  assert.ok(!/\bdelete\s+from\b/i.test(text), 'no SQL delete from this script');
  assert.ok(/guest_id_photo_purge_done_v1/.test(text) && /guest-id-photos-backup/.test(text) && /guest-id-photos-drill/.test(text));
});
