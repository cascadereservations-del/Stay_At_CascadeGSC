// deno test --allow-env supabase/functions/expire-cleaning-photos/expire.test.ts - the whole run against in-memory fakes. Synthetic data only.
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import { hasMoney } from '../_shared/ops-money.ts';
import { archivedCount, fileSection, gate, labelSection, MAX_SESSIONS_PER_RUN, opsLine, parseRunMode, runExpiry, type Deps, type SessionRow, type StoredObject } from './expire.ts';

const NOW = new Date('2026-12-13T22:00:00Z');   // Sunday 22:00 UTC = Monday 06:00 Manila
const DAY = 86_400_000;
const PROP = 'e9100000-0000-4000-8000-000000000001', USER = 'e9200000-0000-4000-8000-000000000001';
const sub = (n: number) => `e93${String(n).padStart(5, '0')}-0000-4000-8000-000000000001`;
const files = (n: number) => Array.from({ length: n }, (_, i) => ({ section: 'section_afterclean', name: `photo_${i + 1}.jpg`, fileId: `DRIVEFILE${String(i).padStart(4, '0')}`, url: `https://drive.google.com/file/d/X${i}/view` }));

/** A session that passes every condition unless `over` breaks one. */
function session(n: number, over: Partial<SessionRow> = {}): SessionRow {
  return {
    id: `e94${String(n).padStart(5, '0')}-0000-4000-8000-000000000001`, created_at: new Date(NOW.getTime() - 100 * DAY - n * 60_000).toISOString(),
    submission_id: sub(n), property_id: PROP, submitted_by_user_id: USER, session_folder_id: `FOLDER${String(n).padStart(6, '0')}`,
    total_photo_count: 5, drive_files: files(5), meter_readings: [{ vision_verdict: 'ok' }], ...over,
  };
}
const prefixOf = (s: SessionRow) => `${s.property_id}/${s.submitted_by_user_id}/${s.submission_id}`;
const objs = (n: number, size = 100_000): StoredObject[] => Array.from({ length: n }, (_, i) => ({ name: `u${i}-afterclean_2026-07-01_${i}.jpg`, size, isFolder: false }));

/** Fake Storage: the buckets hold objects by prefix; remove() deletes and reports. `failRemove` simulates an API refusal, `partial` a short delete. */
function world(sessions: SessionRow[], storage: Record<string, StoredObject[]>, extra: { failRemove?: boolean; partial?: boolean } = {}) {
  const removed: string[] = [], sent: string[] = [], listed: string[] = [];
  const deps: Deps = {
    now: NOW,
    fetchCandidates: async () => sessions,
    listObjects: async (p) => { listed.push(p); return storage[p] ?? []; },
    removeObjects: async (paths) => {
      if (extra.failRemove) throw new Error('storage 500');
      const take = extra.partial ? paths.slice(0, paths.length - 1) : paths;
      removed.push(...take);
      return take;
    },
    notify: async (t) => { sent.push(t); },
  };
  return { deps, removed, sent, listed };
}

Deno.test('a fully archived, old, verified session is expired: every object in its own folder goes, through remove()', async () => {
  const s = session(1), w = world([s], { [prefixOf(s)]: objs(5) });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.expired, [{ session: s.id.slice(0, 8), objects: 5, bytes: 500_000 }]);
  assertEquals(w.removed.length, 5);
  assert(w.removed.every((p) => p.startsWith(prefixOf(s) + '/')));
  assertEquals(r.freedBytes, 500_000);
  assertEquals(w.sent.length, 1);
});

Deno.test('DRY RUN IS THE DEFAULT: no options means nothing is deleted and nobody is told', async () => {
  const s = session(1), w = world([s], { [prefixOf(s)]: objs(5) });
  const r = await runExpiry(w.deps);
  assertEquals(r.dry, true);
  assertEquals(r.expired.length, 1);
  assertEquals(r.freedBytes, 500_000);
  assertEquals(w.removed, []);
  assertEquals(w.sent, []);
  assertEquals(r.opsLine, null);
  const explicit = await runExpiry(world([s], { [prefixOf(s)]: objs(5) }).deps, { dry: undefined });
  assertEquals(explicit.dry, true);
});

Deno.test('NOT ARCHIVED: no Drive folder id means the session is kept and its storage is never even listed', async () => {
  const s = session(1, { session_folder_id: null }), w = world([s], { [prefixOf(s)]: objs(5) });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.kept, [{ session: s.id.slice(0, 8), reason: 'no_drive_folder' }]);
  assertEquals(w.removed, []);
  assertEquals(w.listed, []);
  assertEquals(w.sent, []);
});

Deno.test('each archive condition that is false keeps the session (count short, count long, zero photos, no list, entry without a file id)', async () => {
  const bad: Partial<SessionRow>[] = [
    { drive_files: files(4) },                                        // archive holds fewer files than total_photo_count
    { drive_files: files(6) },                                        // more than the stored count
    { total_photo_count: 0, drive_files: [] },                        // nothing was recorded as photographed
    { drive_files: null },                                            // older Code.gs, ids never stored
    { total_photo_count: null },
    { drive_files: [...files(4), { section: 'x', name: 'photo_5.jpg', url: 'https://drive.google.com/file/d/Z/view' }] },   // fifth entry has no fileId
    { drive_files: [...files(4), { section: 'x', name: 'photo_5.jpg', fileId: '  ' }] },
  ];
  for (const [i, over] of bad.entries()) {
    const s = session(i + 1, over), w = world([s], { [prefixOf(s)]: objs(5) });
    const r = await runExpiry(w.deps, { dry: false });
    assertEquals(r.expired, [], `case ${i}`);
    assertEquals(w.removed, [], `case ${i}`);
    assertEquals(r.kept[0].reason, 'archive_incomplete', `case ${i}`);
  }
});

Deno.test('too young (inside 90 days) is kept even if the candidate list hands it over', async () => {
  const s = session(1, { created_at: new Date(NOW.getTime() - 89 * DAY).toISOString() }), w = world([s], { [prefixOf(s)]: objs(5) });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.kept[0].reason, 'too_young');
  assertEquals(w.removed, []);
});

Deno.test('meter photos: a session whose meter photo was never verified (null) or errored is kept; "ok", "mismatch" and no reading at all are expired', async () => {
  const keep: SessionRow['meter_readings'][] = [[{ vision_verdict: null }], [{ vision_verdict: 'error' }], { vision_verdict: null }, [{ vision_verdict: 'ok' }, { vision_verdict: null }]];
  for (const [i, m] of keep.entries()) {
    const s = session(i + 1, { meter_readings: m }), w = world([s], { [prefixOf(s)]: objs(5) });
    const r = await runExpiry(w.deps, { dry: false });
    assertEquals(r.kept[0].reason, 'meter_unverified', `case ${i}`);
    assertEquals(w.removed, []);
  }
  for (const [i, m] of ([[{ vision_verdict: 'ok' }], [{ vision_verdict: 'mismatch' }], [{ vision_verdict: 'unreadable' }], [], null, { vision_verdict: 'not_a_meter' }] as SessionRow['meter_readings'][]).entries()) {
    const s = session(i + 1, { meter_readings: m }), w = world([s], { [prefixOf(s)]: objs(5) });
    const r = await runExpiry(w.deps, { dry: false });
    assertEquals(r.expired.length, 1, `go case ${i}`);
  }
});

Deno.test('a folder with MORE objects than the archive has files is kept whole (a retake may not be in Drive)', async () => {
  const s = session(1), w = world([s], { [prefixOf(s)]: objs(6) });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.kept[0].reason, 'extra_objects');
  assertEquals(w.removed, []);
});

Deno.test('fewer objects than the archive (a page reload left some elsewhere) still expires only what is in the session folder', async () => {
  const s = session(1), w = world([s], { [prefixOf(s)]: objs(3) });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.expired[0].objects, 3);
  assertEquals(w.removed.length, 3);
});

Deno.test('an empty folder, a sub-folder or a path that could escape the session folder is never deleted', async () => {
  const s1 = session(1), s2 = session(2), s3 = session(3, { submission_id: '../../etc' });
  const w = world([s1, s2, s3], { [prefixOf(s1)]: [], [prefixOf(s2)]: [{ name: 'nested', size: null, isFolder: true }, ...objs(2)] });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.kept.map((k) => k.reason).sort(), ['bad_path', 'nothing_in_storage', 'unexpected_layout']);
  assertEquals(w.removed, []);
  const s4 = session(4), w2 = world([s4], { [prefixOf(s4)]: [{ name: '../other/x.jpg', size: 1, isFolder: false }] });
  assertEquals((await runExpiry(w2.deps, { dry: false })).kept[0].reason, 'unexpected_layout');
});

Deno.test('legacy sessions with no per-session folder (date-folder photos) find nothing to delete', async () => {
  const s = session(1, { submitted_by_user_id: null }), w = world([s], { '2026-07-04': objs(30) });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.kept[0].reason, 'bad_path');
  assertEquals(w.removed, []);
});

Deno.test(`at most ${MAX_SESSIONS_PER_RUN} sessions per run, the rest wait for next Monday`, async () => {
  const list = Array.from({ length: 14 }, (_, i) => session(i + 1)), storage: Record<string, StoredObject[]> = {};
  for (const s of list) storage[prefixOf(s)] = objs(5);
  const w = world(list, storage);
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.expired.length, MAX_SESSIONS_PER_RUN);
  assertEquals(w.removed.length, MAX_SESSIONS_PER_RUN * 5);
  const dry = await runExpiry(world(list, storage).deps);
  assertEquals(dry.expired.length, MAX_SESSIONS_PER_RUN);
});

Deno.test('kept sessions do not use up the cap', async () => {
  const kept = Array.from({ length: 12 }, (_, i) => session(i + 1, { session_folder_id: null })), good = session(20), w = world([...kept, good], { [prefixOf(good)]: objs(5) });
  assertEquals((await runExpiry(w.deps, { dry: false })).expired.length, 1);
});

Deno.test('a Storage refusal is reported and the session is not counted as moved; no OPS line then', async () => {
  const s = session(1), w = world([s], { [prefixOf(s)]: objs(5) }, { failRemove: true });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.expired, []);
  assertEquals(r.failed.length, 1);
  assertEquals(w.sent, []);
});

Deno.test('a short delete is a failure to retry, not a moved session', async () => {
  const s = session(1), w = world([s], { [prefixOf(s)]: objs(5) }, { partial: true });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.expired, []);
  assertStringIncludes(r.failed[0].error, 'removed 4 of 5');
  assertEquals(w.sent, []);
});

Deno.test('nothing to move: silent (no OPS line)', async () => {
  const w = world([session(1, { session_folder_id: null })], {});
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.opsLine, null);
  assertEquals(w.sent, []);
});

Deno.test('archivedCount counts only entries that carry a file id', () => {
  assertEquals(archivedCount(files(3)), 3);
  assertEquals(archivedCount([{ fileId: '' }, null, {}, { fileId: 7 }]), 0);
  assertEquals(archivedCount('nope'), 0);
});

Deno.test('gate returns the session folder as property/user/submission', () => {
  const s = session(1), g = gate(s, NOW);
  assert(g.ok);
  if (g.ok) assertEquals(g.prefix, prefixOf(s));
});

Deno.test('OPS line: the approved wording, Manila weekday, one decimal, singular for one', () => {
  assertEquals(opsLine(6, 8_400_000, NOW), '📦 Photo archive tidy-up — Monday. 6 cleanings older than 90 days moved off Supabase (all 6 already in Drive). Freed 8.4 MB. Nothing else touched.');
  assertStringIncludes(opsLine(1, 1_250_000, NOW), '1 cleaning older than 90 days moved off Supabase (it was already in Drive).');
  assertStringIncludes(opsLine(1, 1_250_000, NOW), 'Freed 1.3 MB.');
});

Deno.test('D-306: the OPS line carries no money, whatever is fed to it (money-shaped strings read as 0)', () => {
  const MONEY = ['PHP 4,550', '₱2,800', '₱1,780', 'P-1,780', '2,000 pesos', 'ang total 4550'];
  for (const m of MONEY) {
    const line = opsLine(m as unknown as number, m as unknown as number, NOW);
    assertFalse(hasMoney(line), `money-shaped input leaked: ${m} -> ${line}`);
    for (const bad of ['PHP', '₱', '4,550', '2,800', '1,780', 'pesos', 'total']) assertFalse(line.includes(bad), `${bad} in ${line}`);
  }
  assertFalse(hasMoney(opsLine(6, 8_400_000, NOW)));
  assertFalse(hasMoney(opsLine(1, 0, NOW)));
  assertStringIncludes(opsLine(NaN, -5, NOW), 'Freed 0.0 MB');
});

Deno.test('D-306: what the run sends to OPS is only that line, even when session data holds money-shaped text', async () => {
  const s = session(1, { session_folder_id: 'PHP 4,550 ₱2,800 deposit' }), w = world([s], { [prefixOf(s)]: objs(5) });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.expired.length, 1);
  assertEquals(w.sent.length, 1);
  assertFalse(hasMoney(w.sent[0]));
  for (const bad of ['PHP', '₱', '4,550', 'deposit']) assertFalse(w.sent[0].includes(bad));
});

const named = (names: string[], size = 100_000): StoredObject[] => names.map((name) => ({ name, size, isFolder: false }));
const entry = (section: string, i: number) => ({ section, name: `photo_${i}.jpg`, fileId: `DRIVEFILE${String(i).padStart(4, '0')}`, url: '' });

Deno.test('SECTIONS: an archive of 24 with no condition entries while Storage holds 8 condition photos is kept whole', async () => {
  const drive = [...Array.from({ length: 12 }, (_, i) => entry('section_preclean', i)), ...Array.from({ length: 12 }, (_, i) => entry('section_afterclean', 100 + i))];
  const s = session(1, { total_photo_count: 24, drive_files: drive });
  const stored = [...objs(12).map((o, i) => ({ ...o, name: `u${i}-preclean_x_${i}.jpg` })), ...objs(4).map((o, i) => ({ ...o, name: `u${i}-afterclean_x_${i}.jpg` })), ...objs(8).map((o, i) => ({ ...o, name: `u${i}-condition_x_${i}.jpg` }))];
  const w = world([s], { [prefixOf(s)]: stored });
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.kept, [{ session: s.id.slice(0, 8), reason: 'section_not_archived' }]);
  assertEquals(r.keptReasons, { section_not_archived: 1 });
  assertEquals(w.removed, []);
});

Deno.test('SECTIONS: an object whose name maps to no section is kept; matching sections with real Drive label spellings expire', async () => {
  const s1 = session(1), w1 = world([s1], { [prefixOf(s1)]: named(['u-mystery.jpg', ...objs(2).map((o) => o.name)]) });
  assertEquals((await runExpiry(w1.deps, { dry: false })).kept[0].reason, 'section_not_archived');
  const drive = [entry('After-Clean', 1), entry('section_preclean', 2), entry('Meter_Readings', 3), entry('Unit_Condition', 4), entry('issue_check_sink', 5)];
  const s2 = session(2, { drive_files: drive });
  const w2 = world([s2], { [prefixOf(s2)]: named(['a-afterclean_1.jpg', 'a-preclean_1.jpg', 'a-water_meter_1.jpg', 'a-condition_1.jpg', 'a-issue_sink_1.jpg']) });
  const r = await runExpiry(w2.deps, { dry: false });
  assertEquals(r.expired.length, 1);
  assertEquals(w2.removed.length, 5);
});

Deno.test('SECTIONS: filename and label mapping', () => {
  assertEquals(['x-preclean_1.jpg', 'x-afterclean_1', 'x-bedroom_1', 'x-kitchen_1', 'x-electric_meter_1', 'x-water_meter_1', 'x-issue_1', 'x-condition_1', 'x-photo_1'].map(fileSection),
    ['preclean', 'afterclean', 'bedroom', 'kitchen', 'meter', 'meter', 'issue', 'condition', 'other']);
  assertEquals(['section_afterclean', 'After-Clean', 'Pre-Clean', 'Meter_Readings', 'section_meter', 'Unit_Condition', 'issue_check_x', 'Bedroom & Living Room', 'Kitchen & Bathroom', 'x', undefined].map(labelSection),
    ['afterclean', 'afterclean', 'preclean', 'meter', 'meter', 'condition', 'issue', 'bedroom', 'kitchen', 'other', 'other']);
});

Deno.test('CAP: sessions that reach remove() count against the 10, even when remove deletes but reports nothing', async () => {
  const list = Array.from({ length: 14 }, (_, i) => session(i + 1)), storage: Record<string, StoredObject[]> = {};
  for (const s of list) storage[prefixOf(s)] = objs(5);
  let calls = 0;
  const deps: Deps = { now: NOW, fetchCandidates: async () => list, listObjects: async (p) => storage[p] ?? [], removeObjects: async () => { calls += 1; return []; } };
  const r = await runExpiry(deps, { dry: false });
  assertEquals(calls, MAX_SESSIONS_PER_RUN);
  assertEquals(r.failed.length, MAX_SESSIONS_PER_RUN);
  assertEquals(r.expired, []);
});

Deno.test('KEPT REASONS: counted per reason in the result, so permanent keeps are visible; no OPS line at 0 expired', async () => {
  const list = [session(1, { session_folder_id: null }), session(2, { session_folder_id: null }), session(3, { meter_readings: [{ vision_verdict: null }] })];
  const w = world(list, {});
  const r = await runExpiry(w.deps, { dry: false });
  assertEquals(r.keptReasons, { no_drive_folder: 2, meter_unverified: 1 });
  assertEquals(r.opsLine, null);
  assertEquals(w.sent, []);
});

Deno.test('RUN MODE: only ?delete=1 with the right secret is real; ?delete=true, ?delete=0 and no query are dry; a missing or wrong secret is 401', () => {
  const U = 'https://x.test/functions/v1/expire-cleaning-photos';
  assertEquals(parseRunMode(U + '?delete=1', 'sekret', 'sekret'), { ok: true, dry: false });
  for (const q of ['?delete=true', '?delete=0', '?delete=', '']) assertEquals(parseRunMode(U + q, 'sekret', 'sekret'), { ok: true, dry: true }, q);
  for (const [h, sec] of [[null, 'sekret'], ['wrong!', 'sekret'], ['sekret', ''], ['', ''], [null, '']] as [string | null, string][]) {
    assertEquals(parseRunMode(U + '?delete=1', h, sec), { ok: false, status: 401 });
  }
});
