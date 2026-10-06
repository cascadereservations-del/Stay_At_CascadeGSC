// deno test --no-lock --node-modules-dir=auto --allow-env --allow-read guest-intake/
// SPEC-42 s4b: the save sequence (create, store, link, mark), the rollback of an unlinked object, the 12 a day limit and the OPS line.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { opsCard, savePeople, type Context, type Deps, type RpcResult } from './intake.ts';
import type { Person } from './validate.ts';

import { JPEG_GPS } from './fixtures.ts';
const JPEG = JPEG_GPS;
const ctx: Context = { ref: 'E9200001', guest_name: 'Ben Cruz', checkin_date: '2026-10-17', checkout_date: '2026-10-19', can_save: true, uploads_today: 0, max_uploads_per_day: 12 };
const person = (over: Partial<Person> = {}): Person => ({ name: 'Ben Cruz', idType: 'passport', contact: '09170001111', self: true, photo: JPEG, ...over });
const has = (b: Uint8Array, text: string) => new TextDecoder('latin1').decode(b).includes(text);
const ok = (data: unknown): RpcResult => ({ data, error: null });

function rig(handlers: Partial<Record<string, (args: Record<string, unknown>) => RpcResult>> = {}) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const stored: string[] = [], removed: string[] = [], uploaded: Uint8Array[] = [];
  const deps: Deps = {
    rpc: async (fn, args) => {
      calls.push([fn, args]);
      const h = handlers[fn];
      if (h) return h(args);
      if (fn === 'intake_save_guest_companion_v1') return ok({ ok: true, id: 'cid-1' });
      return ok({ ok: true });
    },
    upload: async (path, bytes) => { stored.push(path); uploaded.push(bytes); return null; },
    remove: async (path) => { removed.push(path); },
    uuid: () => '2c1c2c1c-0000-4000-8000-000000000001',
  };
  return { deps, calls, stored, removed, uploaded };
}

Deno.test('a booker with a photo: person, object, link, then ID on file with their contact and ID type', async () => {
  const r = rig();
  const out = await savePeople(r.deps, 'h'.repeat(64), ctx, [person()]);
  assertEquals(out, [{ name: 'Ben Cruz', ok: true, photo: true }]);
  assert(r.uploaded[0] && !has(r.uploaded[0], 'GPSLATLONG') && has(r.uploaded[0], 'JFIF'), 'the stored copy has no GPS data');
  assertEquals(r.stored, ['cid-1/2c1c2c1c-0000-4000-8000-000000000001.jpg']);
  assertEquals(r.calls.map((c) => c[0]), ['intake_save_guest_companion_v1', 'intake_save_guest_companion_v1', 'intake_save_guest_details_v1']);
  assertEquals(r.calls[1][1].p_id_photo_path, 'cid-1/2c1c2c1c-0000-4000-8000-000000000001.jpg');
  assertEquals(r.calls[2][1].p_patch, { id_on_file: true, contact_number: '09170001111', id_type: 'passport' });
});

Deno.test('a companion with a photo marks ID on file only; no contact or ID type goes to the booker record', async () => {
  const r = rig();
  await savePeople(r.deps, 'h'.repeat(64), ctx, [person({ name: 'Ana Cruz', self: false })]);
  assertEquals(r.calls[2][1].p_patch, { id_on_file: true });
});

Deno.test('a name with no photo saves the person and writes no details for a companion', async () => {
  const r = rig();
  const out = await savePeople(r.deps, 'h'.repeat(64), ctx, [person({ name: 'Ana Cruz', self: false, photo: null })]);
  assertEquals(out, [{ name: 'Ana Cruz', ok: true, photo: false }]);
  assertEquals(r.calls.map((c) => c[0]), ['intake_save_guest_companion_v1']);
  assertEquals(r.stored, []);
});

Deno.test('a file that is not JPEG, PNG or WebP is refused before anything is saved', async () => {
  const r = rig();
  const out = await savePeople(r.deps, 'h'.repeat(64), ctx, [person({ photo: new TextEncoder().encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>') })]);
  assertEquals(out, [{ name: 'Ben Cruz', ok: false, photo: false, reason: 'photo_type' }]);
  assertEquals(r.calls.length + r.stored.length, 0);
});

Deno.test('a link that fails removes the object it stored, so no photo sits unreferenced', async () => {
  const r = rig({ intake_save_guest_companion_v1: (a) => a.p_id_photo_path ? { data: null, error: { message: 'boom' } } : ok({ ok: true, id: 'cid-1' }) });
  const out = await savePeople(r.deps, 'h'.repeat(64), ctx, [person()]);
  assertEquals(out[0].reason, 'save_failed');
  assertEquals(r.removed, r.stored);
  assertEquals(r.stored.length, 1);
});

Deno.test('a failed upload links nothing and a refused person does not stop the next one', async () => {
  const r = rig({ intake_save_guest_companion_v1: (a) => a.p_name === 'Bad Name' ? ok({ ok: false, reason: 'invalid_token' }) : ok({ ok: true, id: 'cid-1' }) });
  r.deps.upload = async () => 'storage down';
  const out = await savePeople(r.deps, 'h'.repeat(64), ctx, [person({ name: 'Bad Name' }), person({ name: 'Ana Cruz', self: false, photo: null })]);
  assertEquals(out.map((o) => o.ok), [false, true]);
});

Deno.test('the 12 a day limit: photos past it are refused before any upload, names still save', async () => {
  const r = rig();
  const out = await savePeople(r.deps, 'h'.repeat(64), { ...ctx, uploads_today: 11 }, [person({ self: false }), person({ name: 'Ana Cruz', self: false }), person({ name: 'Cy Cruz', self: false, photo: null })]);
  assertEquals(out.map((o) => [o.ok, o.reason]), [[true, undefined], [false, 'rate_limited'], [true, undefined]]);
  assertEquals(r.stored.length, 1);
});

Deno.test('the database backstop: a rate_limited link answer removes the object and reports the limit', async () => {
  const r = rig({ intake_save_guest_companion_v1: (a) => a.p_id_photo_path ? ok({ ok: false, reason: 'rate_limited' }) : ok({ ok: true, id: 'cid-1' }) });
  const out = await savePeople(r.deps, 'h'.repeat(64), ctx, [person()]);
  assertEquals(out[0].reason, 'rate_limited');
  assertEquals(r.removed.length, 1);
});

Deno.test('details failing after the photo is linked is reported, not hidden, and the photo stays linked', async () => {
  const r = rig({ intake_save_guest_details_v1: () => ({ data: null, error: { message: 'boom' } }) });
  const out = await savePeople(r.deps, 'h'.repeat(64), ctx, [person()]);
  assertEquals(out, [{ name: 'Ben Cruz', ok: false, photo: true, reason: 'save_failed' }]);
  assertEquals(r.removed.length, 0);
});

Deno.test('OPS line: who and what first, the stay, no action; no phone, money, link or ID detail; silent when nothing saved', () => {
  const card = opsCard(ctx, [{ name: 'Ben Cruz', ok: true, photo: true }, { name: 'Ana Cruz', ok: true, photo: true }, { name: 'Cy Cruz', ok: false, photo: false, reason: 'save_failed' }])!;
  assert(card.includes('Ben Cruz sent 2 IDs before arrival.'), card);
  assert(card.includes('No action needed.'));
  assert(card.includes('E9200001') && card.includes('2026-10-17'));
  assert(!/₱|\b(php|paid|payment|deposit|balance|fee|receipt)\b/i.test(card), 'no booking money in OPS (D-306)');
  assert(!/(?:\+63|\b0)9\d{9}|https?:|@/.test(card), 'no phone, link or e-mail in OPS');
  assert(!/passport|licen[cs]e|national id/i.test(card), 'no ID detail in OPS');
  assertEquals(opsCard(ctx, [{ name: 'Ben Cruz', ok: false, photo: false, reason: 'save_failed' }]), null);
  assert(opsCard(ctx, [{ name: 'Ben Cruz', ok: true, photo: false }])!.includes('1 guest name (no ID photos yet)'));
});
