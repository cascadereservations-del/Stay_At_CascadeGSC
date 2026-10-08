// deno test --no-check --allow-env messenger-concierge/id-capture.test.ts
// SPEC-45 (D-320.6): a guest's ID photo in Messenger. The pure plan (id-capture.ts) and the real handle() with the probe effects and
// an in-memory db (no network): id saved as the guest's own, mismatch -> companion, no booking -> nothing, host-held -> no line,
// 3 reads a day, a refused save, a non-ID photo keeps the stray-receipt path.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { bookingIdOf, ID_READS_PER_DAY, idOpsLine, manilaDay, mayRead, planId } from './id-capture.ts';
import { idThanks } from './persona.ts';
import { lintReply, toneRules } from './voice.ts';
import { setProviderKey } from '../_shared/cascade-core/providers.ts';
import type { Flow } from './booking.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, probeEffects, graphPermission } = await import('./index.ts');

const now = new Date('2026-10-18T01:55:00Z');
const BID = '6f1c2a3b-0000-4000-8000-000000000001';
const GUEST = 'Angeleen Luz Villanueva';

// ---- the pure plan -------------------------------------------------------------------------------------------------------
Deno.test('planId: an ID whose name matches the booking is the guest\'s own; a mismatch is a companion', () => {
  const own = planId({ kind: 'id', name: 'Angeleen Villanueva', idType: 'passport' }, { bookingId: BID, bookingName: GUEST, hostHeld: false });
  assertEquals(own, { act: 'save', bookingId: BID, name: 'Angeleen Villanueva', idType: 'passport', own: true, guestLine: true });
  const other = planId({ kind: 'id', name: 'Maria Santos Cruz', idType: 'national_id' }, { bookingId: BID, bookingName: GUEST, hostHeld: false });
  assertEquals(other.act === 'save' && other.own, false);
  // a first name alone never proves it is the guest: companion, ID on file not marked
  const thin = planId({ kind: 'id', name: 'Angeleen Villanueva', idType: 'passport' }, { bookingId: BID, bookingName: 'Angel', hostHeld: false });
  assertEquals(thin.act === 'save' && thin.own, false);
});
Deno.test('planId: chat and other reads save nothing; no booking saves nothing; a host-held chat saves with no guest line', () => {
  assertEquals(planId({ kind: 'other' }, { bookingId: BID, bookingName: GUEST, hostHeld: false }), { act: 'none', reason: 'not_id' });
  assertEquals(planId({ kind: 'chat', names: [GUEST], phone: null }, { bookingId: BID, bookingName: GUEST, hostHeld: false }), { act: 'none', reason: 'not_id' });
  assertEquals(planId({ kind: 'id', name: GUEST, idType: 'passport' }, { bookingId: null, bookingName: null, hostHeld: false }), { act: 'none', reason: 'no_booking' });
  const held = planId({ kind: 'id', name: GUEST, idType: 'passport' }, { bookingId: BID, bookingName: GUEST, hostHeld: true });
  assertEquals(held.act === 'save' && held.guestLine, false);
});
Deno.test('mayRead: no booking, then 3 reads per Manila day, the count resets the next day', () => {
  assertEquals(mayRead(null, null, now), { ok: false, reason: 'no_booking' });
  const day = manilaDay(now);
  assertEquals(mayRead(BID, undefined, now), { ok: true, next: { day, n: 1 } });
  assertEquals(mayRead(BID, { day, n: ID_READS_PER_DAY - 1 }, now), { ok: true, next: { day, n: ID_READS_PER_DAY } });
  assertEquals(mayRead(BID, { day, n: ID_READS_PER_DAY }, now), { ok: false, reason: 'cap' });
  assertEquals(mayRead(BID, { day: '2026-10-17', n: 9 }, now), { ok: true, next: { day, n: 1 } });
  assertEquals(manilaDay(new Date('2026-10-17T16:30:00Z')), '2026-10-18'); // 00:30 in Manila
});
Deno.test('bookingIdOf: a uuid at any age, or the probe marker; anything else is no booking', () => {
  assertEquals(bookingIdOf({ booking_id: BID }), BID);
  assertEquals(bookingIdOf({ booking_id: 'probe' }), 'probe');
  assertEquals(bookingIdOf({ booking_id: 'b-angel' }), null);
  assertEquals(bookingIdOf(null), null);
});
Deno.test('the guest line: calm, no exclamation, no name read, no number, passes the voice rules in every register', () => {
  for (const l of ['en', 'tl', 'bis'] as const) {
    const m = idThanks(l);
    assertEquals(lintReply(m), [], `${l}: ${m}`);
    assertEquals(toneRules(m, l), [], `${l}: ${m}`);
    assert(!/!|\d/.test(m), m);
  }
  assertEquals(idThanks('en'), 'Thank you, we have your ID for the reservation. It is kept privately and only the host sees it.');
});
Deno.test('the OPS notice: what happened first, the ID type, match or companion, never the name read', () => {
  const p = (own: boolean, guestLine = true) => ({ act: 'save' as const, bookingId: BID, name: 'Maria Santos Cruz', idType: 'national_id' as const, own, guestLine });
  const own = idOpsLine('Angel', p(true), { ok: true }, 'L');
  assert(own.startsWith('Angel sent an ID in Messenger; saved to the guest record as a national ID.'), own);
  const comp = idOpsLine('Angel', p(false), { ok: true }, 'L');
  assert(/as a companion \(a national ID\)/.test(comp) && /does not match the booking name/.test(comp), comp);
  const no = idOpsLine(null, p(true), { ok: false, reason: 'not_confirmed' }, 'L');
  assert(no.startsWith('A guest sent an ID in Messenger; it was not saved (the booking is not confirmed yet).'), no);
  assert(/handling this chat/.test(idOpsLine('Angel', p(true, false), { ok: true }, 'L')));
  for (const t of [own, comp, no]) assert(!/Maria|Santos|Cruz|PHP|₱/.test(t), t);
});
Deno.test('graphPermission: (#10) and 2xx permission codes, not other Graph errors', () => {
  assert(graphPermission({ code: 10, message: '(#10) Application does not have permission for this action' }));
  assert(graphPermission({ code: 230, message: 'Requires pages_messaging permission' }));
  assert(!graphPermission({ code: 100, message: 'Invalid parameter' }));
  assert(!graphPermission(undefined));
});

// ---- the real handle() ----------------------------------------------------------------------------------------------------
type Call = { fx: string; text?: string; detail?: Record<string, unknown> };
// deno-lint-ignore no-explicit-any
function fakeDb(row: any) {
  // deno-lint-ignore no-explicit-any
  const writes: Array<{ table: string; v: any }> = [];
  // deno-lint-ignore no-explicit-any
  const q = (table: string): any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    // deno-lint-ignore no-explicit-any
    if (k === 'upsert' || k === 'insert' || k === 'update') return (v: any) => { writes.push({ table, v }); return q(table); };
    return () => q(table);
  } });
  return { db: { from: (t: string) => q(t), rpc: () => Promise.resolve({ data: [], error: null }) }, writes };
}
const realFetch = globalThis.fetch;
const ago = (m: number) => new Date(now.getTime() - m * 60_000).toISOString();
/** A confirmed booking well past lastRef's 8 days (an ID often comes near check-in). */
const booked = (extra: Partial<Flow> = {}): Flow => ({ step: 'confirmed', checkin: '2026-10-19', checkout: '2026-10-22', pax: 2, lang: 'en', name: GUEST, ref: 'DIR-ANGEL', booking_id: BID,
  started_at: ago(20 * 1440), updated_at: ago(15 * 1440), ...extra });
async function photo(o: { flow?: Flow | null; idName?: string; human?: string | null; url?: string; saveFails?: string } = {}) {
  globalThis.fetch = (() => Promise.resolve(new Response('{}', { status: 500 }))) as typeof fetch; // no network
  setProviderKey('test');
  const row = { psid: 'probe:id45', guest_name: 'Angel', human_until: o.human ?? null, bot_turns: 1, last_risk: null, last_mid: null, booking_flow: o.flow === undefined ? booked() : o.flow,
    history: [{ role: 'guest', text: 'Here is my ID po', at: ago(5) }, { role: 'bot', text: 'Thank you.', at: ago(4) }] };
  const { db, writes } = fakeDb(row);
  const calls: Call[] = [];
  // deno-lint-ignore no-explicit-any
  const fx = probeEffects(calls as any, o.idName ?? GUEST, now);
  if (o.saveFails) fx.idSave = (_db, plan) => { calls.push({ fx: 'id_save', detail: { own: plan.own } }); return Promise.resolve({ ok: false, reason: o.saveFails }); };
  try {
    // deno-lint-ignore no-explicit-any
    await handle(db as any, { sender: { id: 'probe:id45' }, recipient: { id: 'page' }, message: { mid: 'm-' + Math.random(), attachments: [{ type: 'image', payload: { url: o.url ?? 'https://example.invalid/id.jpg' } }] } }, 'auto', fx, now);
  } finally { globalThis.fetch = realFetch; setProviderKey(null); }
  const reply = calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n');
  const ops = calls.filter((c) => c.fx === 'ops').map((c) => c.text ?? '');
  const saved = writes.filter((w) => w.table === 'concierge_threads').at(-1)?.v;
  return { reply, ops, calls, saved };
}

Deno.test('handle: the guest\'s own ID is saved (ID on file), the guest gets the thank-you, OPS one text notice; no name, no handoff', async () => {
  const r = await photo();
  assertEquals(r.calls.find((c) => c.fx === 'id_save')?.detail?.own, true);
  assertEquals(r.reply, idThanks('en'));
  assertEquals(r.ops.length, 1);
  assert(r.ops[0].includes('Angel sent an ID in Messenger; saved to the guest record as a national ID.'), r.ops[0]);
  assert(!r.calls.some((c) => c.fx === 'handoff'));
  assertEquals(r.saved.booking_flow.id_reads, { day: manilaDay(now), n: 1 });
  assertEquals(r.saved.booking_flow.updated_at, booked().updated_at); // the read count never revives a lapsed flow
});
Deno.test('handle: a different name on the ID is saved as a companion and OPS says so', async () => {
  const r = await photo({ idName: 'Maria Santos Cruz' });
  assertEquals(r.calls.find((c) => c.fx === 'id_save')?.detail?.own, false);
  assertEquals(r.reply, idThanks('en'));
  assert(/as a companion/.test(r.ops[0]) && !/Maria/.test(r.ops.join('\n')), r.ops[0]);
});
Deno.test('handle: no booking on the thread - no ID read at all (today\'s attachment path)', async () => {
  const r = await photo({ flow: null });
  assert(!r.calls.some((c) => c.fx === 'id_read' || c.fx === 'id_save'));
  assert(r.reply !== idThanks('en'));
});
Deno.test('handle: a host-held chat (D-317) still saves the ID, sends the guest nothing, and OPS gets one notice', async () => {
  const r = await photo({ human: new Date(now.getTime() + 86_400_000).toISOString() });
  assertEquals(r.calls.find((c) => c.fx === 'id_save')?.detail?.guest_line, false);
  assertEquals(r.reply, '');
  assertEquals(r.ops.length, 1);
  assert(/handling this chat/.test(r.ops[0]), r.ops[0]);
});
Deno.test('handle: the fourth photo of the Manila day is not read', async () => {
  const r = await photo({ flow: booked({ id_reads: { day: manilaDay(now), n: ID_READS_PER_DAY } }) });
  assert(!r.calls.some((c) => c.fx === 'id_read'));
  assertEquals(r.saved.booking_flow.id_reads.n, ID_READS_PER_DAY);
});
Deno.test('handle: a refused save - nothing saved, the guest gets the file line, OPS says it was not saved', async () => {
  const r = await photo({ saveFails: 'not_confirmed' });
  assert(r.reply.startsWith('Thank you, we have your file'), r.reply);
  assert(/it was not saved \(the booking is not confirmed yet\)/.test(r.ops[0]), r.ops[0]);
});
Deno.test('handle: a photo that is not an ID keeps the stray-receipt path', async () => {
  const r = await photo({ url: 'https://example.invalid/receipt.jpg', flow: booked({ step: 'receipt_sent', updated_at: ago(60) }) }); // inside lastRef's 8 days
  assertEquals(r.calls.find((c) => c.fx === 'id_read')?.detail?.kind, 'other');
  assert(!r.calls.some((c) => c.fx === 'id_save'));
  assert(r.calls.some((c) => c.fx === 'handoff' && c.detail?.risk === 'payment'));
});
