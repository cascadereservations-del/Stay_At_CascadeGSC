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
  assertEquals(r, { kind: 'chat', names: ['Ben Cruz'], phone: '09171234567', email: 'ana@mail.com', guests: 3, nationality: null });
  assertEquals(parseRead('{"kind":"chat","names":[],"phone":"12","email":"no","guests":99}'), { kind: 'other' });
  assertEquals(cleanPhone('+44 7700 900123'), '+447700900123');
  assertEquals(cleanPhone('12345'), null);
});

Deno.test('propose: own ID, new companions only, nationality only from text', () => {
  const p = propose([
    { image: 0, read: { kind: 'id', name: 'Ana Maria Reyes', idType: 'national_id' } },
    { image: 1, read: { kind: 'chat', names: ['Ana Reyes', 'Ben Cruz', 'Carla Dizon'], phone: '09171234567', email: null, guests: 3, nationality: 'Korean' } },
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
