import { assert, assertEquals } from 'jsr:@std/assert@1';
import { cleanPhone, handle, parseRead, propose, type Deps, type OnFile, type Ops, type RpcOut, type Stay } from './logic.ts';

const JPEG = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0, 4, 0x4a, 0x46, 0xff, 0xda, 0, 2, 1, 2, 3, 0xff, 0xd9]);
const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));
const IMG = { base64: b64(JPEG), mime: 'image/jpeg' };
const STAY: Stay = { uid: 'cascade-direct-x', propertyId: 'p1', guestId: 'g1', guestName: 'Ana Reyes', checkin: '2026-10-08', checkout: '2026-10-11', source: 'direct' };
const GUEST: OnFile = { guestId: 'g1', name: 'Ana Maria Reyes', email: null, phone: null, idOnFile: false, idType: null, version: 3,
  companions: [{ id: 'c-old', name: 'Ben Cruz', hasPhoto: false }] };

type Rec = { profile: Array<[Record<string, unknown>, number | null]>; companions: Array<[string | null, Record<string, unknown>]>; uploads: string[]; removed: string[]; emails: string[]; reads: number; logs: string[] };
function fake(over: Partial<Deps> = {}, opsOver: Partial<Ops> = {}, guest: OnFile = GUEST, reply = '{"kind":"other"}') {
  const rec: Rec = { profile: [], companions: [], uploads: [], removed: [], emails: [], reads: 0, logs: [] };
  let n = 0;
  const ok = (data: unknown): RpcOut => ({ data, error: null });
  const ops: Ops = {
    loadGuest: () => Promise.resolve(guest),
    saveProfile: (_g, patch, v) => { rec.profile.push([patch, v]); return Promise.resolve(ok({ ok: true })); },
    saveCompanion: (_g, cid, patch) => { rec.companions.push([cid, patch]); return Promise.resolve(ok({ ok: true, id: cid ?? `c-new-${++n}` })); },
    setEmail: (_g, e) => { rec.emails.push(e); return Promise.resolve(null); },
    upload: (p) => { rec.uploads.push(p); return Promise.resolve(null); },
    remove: (p) => { rec.removed.push(p); return Promise.resolve(); },
    canManage: () => Promise.resolve(true),
    ...opsOver,
  };
  const deps: Deps = {
    authenticate: () => Promise.resolve({ ok: true, ops }),
    stay: () => Promise.resolve(STAY),
    guestProperty: () => Promise.resolve('p1'),
    recentReads: () => Promise.resolve(0),
    readImage: () => { rec.reads++; return Promise.resolve(reply); },
    readText: () => { rec.reads++; return Promise.resolve(reply); },
    uuid: () => '11111111-2222-3333-4444-555555555555',
    log: (l) => rec.logs.push(l),
    ...over,
  };
  return { deps, rec };
}
const post = (body: unknown, auth = true) => new Request('https://x.test/staff-guest-details', {
  method: 'POST', headers: { 'content-type': 'application/json', ...(auth ? { authorization: 'Bearer staff.jwt' } : {}) }, body: JSON.stringify(body),
});

Deno.test('parseRead keeps a name and type from an ID and drops numbers', () => {
  assertEquals(parseRead('{"kind":"id","name":"REYES, ANA MARIA","id_type":"Passport","nationality":"FILIPINO","number":"P1234567"}'),
    { kind: 'id', name: 'Ana Maria Reyes', idType: 'passport' }); // D-291: no nationality from an ID
  assertEquals(parseRead('{"kind":"id","name":"P1234567 ANA","id_type":"passport"}'), { kind: 'other' });
  assertEquals(parseRead('not json'), { kind: 'other' });
});

Deno.test('parseRead chat: phone, email, guests; junk becomes null', () => {
  const r = parseRead('```json\n{"kind":"chat","names":["Ben Cruz","x"],"phone":"+63 917 123 4567","email":"Ana@Mail.COM","guests":"3","nationality":null}\n```');
  assertEquals(r, { kind: 'chat', names: ['Ben Cruz'], phone: '09171234567', email: 'ana@mail.com', guests: 3, nationality: null, stayPreferences: null, birthday: null, tags: [] });
  assertEquals(parseRead('{"kind":"chat","names":[],"phone":"12","email":"no","guests":99}'), { kind: 'other' });
  assertEquals(cleanPhone('+44 7700 900123'), '+447700900123');
  assertEquals(cleanPhone('12345'), null);
});

Deno.test('propose: own ID, new companions only, nationality only from text', () => {
  const p = propose([
    { image: 0, read: { kind: 'id', name: 'Ana Maria Reyes', idType: 'national_id' } },
    { image: 1, read: { kind: 'chat', names: ['Ana Reyes', 'Ben Cruz', 'Carla Dizon'], phone: '09171234567', email: null, guests: 3, nationality: 'Korean', stayPreferences: null, birthday: null, tags: [] } },
    { image: 2, read: { kind: 'other' } },
  ], GUEST);
  assertEquals(p.ids, [{ image: 0, name: 'Ana Maria Reyes', id_type: 'national_id', own: true }]);
  assertEquals(p.companions, ['Carla Dizon']);
  assertEquals(p.nationality, 'Korean');
  assertEquals(p.images, ['id', 'chat', 'other']);
  assertEquals([p.phone, p.guests], ['09171234567', 3]);
});

Deno.test('401 without a token; 403 passes through; nothing read', async () => {
  const { deps, rec } = fake();
  assertEquals((await handle(post({ action: 'context', uid: 'u' }, false), deps)).status, 401);
  const denied = fake({ authenticate: () => Promise.resolve({ ok: false, status: 403, error: 'staff_access_denied' }) });
  const res = await handle(post({ action: 'extract', uid: 'u', text: 'hi' }), denied.deps);
  assertEquals(res.status, 403);
  assertEquals(rec.reads + denied.rec.reads, 0);
});

Deno.test('a stay with no guest record is 409; unknown stay 404', async () => {
  const a = fake({ stay: () => Promise.resolve({ ...STAY, guestId: null }) });
  assertEquals((await handle(post({ action: 'context', uid: 'u' }), a.deps)).status, 409);
  const b = fake({ stay: () => Promise.resolve(null) });
  assertEquals((await handle(post({ action: 'context', uid: 'u' }), b.deps)).status, 404);
});

Deno.test('extract writes nothing and returns the proposal', async () => {
  const { deps, rec } = fake({}, {}, GUEST, '{"kind":"chat","names":["Carla Dizon"],"phone":"09171234567","email":null,"guests":2}');
  const res = await handle(post({ action: 'extract', uid: 'u', text: 'We are 2, Carla Dizon, 09171234567', images: [IMG] }), deps);
  assertEquals(res.status, 200);
  const j = await res.json();
  assertEquals(j.proposal.companions, ['Carla Dizon']);
  assertEquals(j.proposal.guests, 2);
  assertEquals(rec.reads, 2);
  assertEquals(rec.profile.length + rec.companions.length + rec.uploads.length + rec.emails.length, 0);
  assert(!rec.logs.join().includes('Carla') && !rec.logs.join().includes('0917'));
});

Deno.test('extract refuses too many images and a bad mime', async () => {
  const { deps } = fake();
  assertEquals((await handle(post({ action: 'extract', uid: 'u', images: [IMG, IMG, IMG, IMG, IMG] }), deps)).status, 400);
  assertEquals((await handle(post({ action: 'extract', uid: 'u', images: [{ base64: 'AAAA', mime: 'image/gif' }] }), deps)).status, 400);
  assertEquals((await handle(post({ action: 'extract', uid: 'u' }), deps)).status, 400);
});

Deno.test('save: companion, own ID photo on the exact-name row, profile patch, email fill', async () => {
  const { deps, rec } = fake();
  const res = await handle(post({ action: 'save', uid: 'u', phone: '0917 123 4567', email: 'Ana@Mail.com',
    companions: ['Carla Dizon', 'Ben Cruz', 'Ana Reyes'], ids: [{ name: 'Ana Maria Reyes', id_type: 'passport', image: IMG }] }), deps);
  assertEquals(res.status, 200);
  // Carla created; Ben exists; Ana is the guest. Own ID: a new row named exactly as the guest record, then the photo linked.
  assertEquals(rec.companions[0], [null, { name: 'Carla Dizon' }]);
  assertEquals(rec.companions[1], [null, { name: 'Ana Maria Reyes' }]);
  assertEquals(rec.companions[2], ['c-new-2', { id_photo_path: 'c-new-2/11111111-2222-3333-4444-555555555555.jpg', id_type: 'passport' }]);
  assertEquals(rec.uploads, ['c-new-2/11111111-2222-3333-4444-555555555555.jpg']);
  assertEquals(rec.profile, [[{ contact_number: '09171234567', id_on_file: true, id_type: 'passport' }, 3]]);
  assertEquals(rec.emails, ['ana@mail.com']);
});

Deno.test('save: a failed link removes the stored photo; an email on file is kept', async () => {
  const { deps, rec } = fake({}, {
    saveCompanion: (_g, cid, _patch) => Promise.resolve(cid ? { data: null, error: { message: 'x', code: '42501' } } : { data: { ok: true, id: 'c9' }, error: null }),
  }, { ...GUEST, email: 'old@mail.com' });
  const res = await handle(post({ action: 'save', uid: 'u', email: 'new@mail.com', ids: [{ name: 'Dan Lim', id_type: 'drivers_license', image: IMG }] }), deps);
  assertEquals(res.status, 207);
  const j = await res.json();
  assertEquals(rec.removed, ['c9/11111111-2222-3333-4444-555555555555.jpg']);
  assertEquals(j.saved, [{ what: 'id_photo', ok: false, reason: 'denied' }, { what: 'email', ok: false, reason: 'email_kept' }]);
  assertEquals(rec.emails.length, 0);
  assertEquals(rec.profile.length, 0);
});

Deno.test('save: edited fields are checked again; a non-image ID is never stored', async () => {
  const { deps, rec } = fake();
  assertEquals((await handle(post({ action: 'save', uid: 'u', phone: 'call me' }), deps)).status, 400);
  assertEquals((await handle(post({ action: 'save', uid: 'u', companions: ['A 12345678'] }), deps)).status, 400);
  const png = { base64: btoa('not really an image at all'), mime: 'image/png' };
  assertEquals((await handle(post({ action: 'save', uid: 'u', ids: [{ name: 'Dan Lim', image: png }] }), deps)).status, 400);
  assertEquals((await handle(post({ action: 'save', uid: 'u' }), deps)).status, 400);
  // Guest count and nationality are shown in the sheet but never saved.
  assertEquals((await (await handle(post({ action: 'save', uid: 'u', guests: 3, phone: '09171234567' }), deps)).json()).error, 'not_saved_field');
  assertEquals((await handle(post({ action: 'save', uid: 'u', nationality: 'Filipino' }), deps)).status, 400);
  assertEquals(rec.uploads.length + rec.companions.length + rec.profile.length, 0);
});

Deno.test('own ID never lands on a loosely matched companion; an exact row is reused', async () => {
  // "Ana Reyes" loosely matches the guest "Ana Maria Reyes" but may be another person: a new exact-name row is made.
  const g = { ...GUEST, companions: [{ id: 'c-loose', name: 'Ana Reyes', hasPhoto: false }] };
  const { deps, rec } = fake({}, {}, g);
  const res = await handle(post({ action: 'save', uid: 'u', ids: [{ name: 'Ana Maria Reyes', id_type: 'passport', image: IMG }] }), deps);
  assertEquals(res.status, 200);
  assertEquals(rec.companions[0], [null, { name: 'Ana Maria Reyes' }]);
  assert(rec.uploads[0].startsWith('c-new-1/'));
  const e = fake({}, {}, { ...GUEST, companions: [{ id: 'c-exact', name: ' ana maria  reyes', hasPhoto: false }] });
  await handle(post({ action: 'save', uid: 'u', ids: [{ name: 'Ana Maria Reyes', id_type: 'passport', image: IMG }] }), e.deps);
  assertEquals(e.rec.companions[0][0], 'c-exact');
  assert(e.rec.uploads[0].startsWith('c-exact/'));
});

Deno.test('reads over the hourly cap are refused before any model call; an unreadable count fails closed', async () => {
  const a = fake({ recentReads: () => Promise.resolve(39) });
  const res = await handle(post({ action: 'extract', uid: 'u', text: 'hi', images: [IMG] }), a.deps);
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error, 'too_many_reads');
  assertEquals(a.rec.reads, 0);
  const b = fake({ recentReads: () => Promise.reject(new Error('db')) });
  assertEquals((await handle(post({ action: 'extract', uid: 'u', text: 'hi' }), b.deps)).status, 429);
  const c = fake({ recentReads: () => Promise.resolve(38) });
  assertEquals((await handle(post({ action: 'extract', uid: 'u', text: 'hi', images: [IMG] }), c.deps)).status, 200);
});

Deno.test('no manage_operations on the stay property is 403 for every action', async () => {
  for (const action of ['context', 'extract', 'save']) {
    const { deps, rec } = fake({}, { canManage: () => Promise.resolve(false) });
    const res = await handle(post({ action, uid: 'u', text: 'hi', phone: '09171234567' }), deps);
    assertEquals(res.status, 403, action);
    assertEquals(rec.reads + rec.profile.length, 0);
  }
});

// ---- s82 lane G (Staff 3.2): guest_id requests, preferences / birthday / tags, replace_id / remove_id, preflight ----
const GID = '0a1b2c3d-0000-4000-8000-000000000001', CID = '0a1b2c3d-0000-4000-8000-0000000000c1';
const GUEST2: OnFile = { ...GUEST, guestId: GID, stayPreferences: 'Quiet room', tags: ['anniversary'], birthday: null,
  companions: [{ id: CID, name: 'Ben Cruz', hasPhoto: true }] };

Deno.test('G: preflight allows authorization, apikey, x-client-info and content-type', async () => {
  const { deps } = fake();
  const res = await handle(new Request('https://x.test/staff-guest-details', { method: 'OPTIONS' }), deps);
  assertEquals(res.status, 204);
  const h = (res.headers.get('access-control-allow-headers') ?? '').toLowerCase();
  for (const k of ['authorization', 'apikey', 'x-client-info', 'content-type']) assert(h.includes(k), k);
  assert((res.headers.get('access-control-allow-methods') ?? '').includes('POST'));
});

Deno.test('G: context by guest_id returns features and needs no stay; unknown guest 404; bad id 400', async () => {
  const a = fake({ stay: () => Promise.reject(new Error('stay must not be read')) }, {}, GUEST2);
  const res = await handle(post({ action: 'context', guest_id: GID }), a.deps);
  assertEquals(res.status, 200);
  const j = await res.json();
  assertEquals(j.stay, null);
  assertEquals(j.features, { guest_id: true, preferences: true, replace_id: true, remove_id: true });
  assertEquals((await handle(post({ action: 'context', guest_id: GID }), fake({ guestProperty: () => Promise.resolve(null) }).deps)).status, 404);
  assertEquals((await handle(post({ action: 'context', guest_id: 'nope' }), a.deps)).status, 400);
  assertEquals((await handle(post({ action: 'context', guest_id: GID }), fake({}, { canManage: () => Promise.resolve(false) }, GUEST2).deps)).status, 403);
});

Deno.test('G: extract proposes preferences, birthday and tags from a chat and skips what is on file', async () => {
  const reply = '{"kind":"chat","names":[],"phone":null,"email":null,"guests":2,"stay_preferences":"Late arrival, allergic to nuts","birthday":"1990-05-17","tags":["Anniversary","Vegetarian","vegetarian"]}';
  const { deps, rec } = fake({}, {}, GUEST2, reply);
  const j = await (await handle(post({ action: 'extract', guest_id: GID, text: 'hi' }), deps)).json();
  assertEquals(j.proposal.stay_preferences, 'Late arrival, allergic to nuts');
  assertEquals(j.proposal.birthday, '1990-05-17');
  assertEquals(j.proposal.tags, ['vegetarian']); // anniversary is on file; the repeat is dropped
  assertEquals(rec.profile.length + rec.companions.length, 0);
  assert(!rec.logs.join().includes('1990'));
  // A birthday from an ID image is never proposed, and a year-less date is dropped.
  assertEquals(parseRead('{"kind":"id","name":"Ana Reyes","id_type":"passport","birthday":"1990-05-17"}'), { kind: 'id', name: 'Ana Reyes', idType: 'passport' });
  assertEquals((parseRead('{"kind":"chat","names":["Ana Reyes"],"birthday":"05-17"}') as { birthday: string | null }).birthday, null);
});

Deno.test('G: save writes preferences, birthday and tags only through save_guest_profile_v1 with version and reason', async () => {
  const rec = { profile: [] as Array<[Record<string, unknown>, number | null]>, reason: '' };
  const { deps, rec: r2 } = fake({}, { saveProfile: (_g, patch, v, r) => { rec.profile.push([patch, v]); rec.reason = r; return Promise.resolve({ data: { ok: true }, error: null }); } }, GUEST2);
  const res = await handle(post({ action: 'save', guest_id: GID, stay_preferences: 'Ground floor', birthday: '1990-05-17', tags: ['Vegetarian', 'anniversary'], expected_version: 5, reason: 'Guest asked in chat' }), deps);
  assertEquals(res.status, 200);
  assertEquals(rec.profile, [[{ stay_preferences: 'Quiet room\nGround floor', birthday: '1990-05-17', tags: ['anniversary', 'vegetarian'] }, 5]]);
  assertEquals(rec.reason, 'Guest asked in chat');
  assertEquals(r2.companions.length + r2.uploads.length, 0);
});

Deno.test('G: save refuses bad preference, birthday, tags, reason and version; old clients still work', async () => {
  const { deps, rec } = fake({}, {}, GUEST2);
  const bad = async (extra: Record<string, unknown>) => (await handle(post({ action: 'save', guest_id: GID, ...extra }), deps)).status;
  assertEquals(await bad({ birthday: '2999-01-01' }), 400);
  assertEquals(await bad({ birthday: 'last week' }), 400);
  assertEquals(await bad({ tags: 'vip' }), 400);
  assertEquals(await bad({ stay_preferences: 'x'.repeat(4001) }), 400);
  assertEquals(await bad({ stay_preferences: 'Quiet', reason: 'no' }), 400);
  assertEquals(await bad({ stay_preferences: 'Quiet', expected_version: 0 }), 400);
  assertEquals(rec.profile.length, 0);
  // an old client (uid, phone only, none of the new keys) is unchanged
  assertEquals((await handle(post({ action: 'save', uid: 'u', phone: '0917 123 4567' }), fake().deps)).status, 200);
});

Deno.test('G: a stale version surfaces as changed, not as a silent overwrite', async () => {
  const { deps } = fake({}, { saveProfile: () => Promise.resolve({ data: null, error: { message: 'x', code: '40001' } }) }, GUEST2);
  const res = await handle(post({ action: 'save', guest_id: GID, birthday: '1990-05-17', expected_version: 2 }), deps);
  assertEquals(res.status, 207);
  assertEquals((await res.json()).saved, [{ what: 'profile', ok: false, reason: 'changed' }]);
});

Deno.test('G: replace_id uploads, links through the companion RPC and never deletes the old object', async () => {
  const { deps, rec } = fake({}, {}, GUEST2);
  const res = await handle(post({ action: 'replace_id', guest_id: GID, companion_id: CID, id_type: 'passport', image: IMG, reason: 'Clearer photo' }), deps);
  assertEquals(res.status, 200);
  assertEquals(rec.uploads, [`${CID}/11111111-2222-3333-4444-555555555555.jpg`]);
  assertEquals(rec.companions, [[CID, { id_photo_path: `${CID}/11111111-2222-3333-4444-555555555555.jpg`, id_type: 'passport' }]]);
  assertEquals(rec.removed, []);
  // a failed link removes only the NEW object
  const f = fake({}, { saveCompanion: () => Promise.resolve({ data: null, error: { message: 'x', code: '42501' } }) }, GUEST2);
  const r2 = await handle(post({ action: 'replace_id', guest_id: GID, companion_id: CID, image: IMG }), f.deps);
  assertEquals(r2.status, 207);
  assertEquals(f.rec.removed.length, 1);
  assertEquals((await handle(post({ action: 'replace_id', guest_id: GID, companion_id: CID, image: { base64: btoa('plain text'), mime: 'image/png' } }), fake({}, {}, GUEST2).deps)).status, 400);
});

Deno.test('G: remove_id clears the path only; a stranger companion id is 404; a missing photo is a no-op', async () => {
  const { deps, rec } = fake({}, {}, GUEST2);
  assertEquals((await handle(post({ action: 'remove_id', guest_id: GID, companion_id: CID }), deps)).status, 200);
  assertEquals(rec.companions, [[CID, { id_photo_path: null }]]);
  assertEquals(rec.removed, []);
  assertEquals((await handle(post({ action: 'remove_id', guest_id: GID, companion_id: '0a1b2c3d-0000-4000-8000-0000000000ff' }), deps)).status, 404);
  assertEquals((await handle(post({ action: 'remove_id', guest_id: GID, companion_id: 'x' }), deps)).status, 400);
  const none = fake({}, {}, { ...GUEST2, companions: [{ id: CID, name: 'Ben', hasPhoto: false }] });
  assertEquals((await handle(post({ action: 'remove_id', guest_id: GID, companion_id: CID }), none.deps)).status, 200);
  assertEquals(none.rec.companions.length, 0);
});
