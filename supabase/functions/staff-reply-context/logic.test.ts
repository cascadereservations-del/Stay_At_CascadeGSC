import { assert, assertEquals } from 'jsr:@std/assert@1';
import { SEED_CARD } from '../_shared/cascade-core/pricing.ts';
import { handleReplyContext, type Booking, type Deps, type Thread, type Turn } from './logic.ts';

const NOW = new Date('2026-11-28T04:00:00Z'); // Manila 12:00, 2026-11-28
const PSID = 'zz-psid-1';
const BID = '7f3a21c9-1111-4111-8111-111111111111';
const OTHER = '9a8b7c6d-2222-4222-8222-222222222222';
const GID = '33333333-3333-4333-8333-333333333333';
const guest = (text: string, at: string): Turn => ({ role: 'guest', text, at });
const bot = (text: string, at: string): Turn => ({ role: 'bot', text, at });
const flowOf = (o: Record<string, unknown> = {}) => ({ step: 'offer', started_at: '2026-11-26T01:00:00Z', updated_at: '2026-11-26T01:00:00Z', ...o }) as Thread['booking_flow'];
const stay = (o: Partial<Booking> = {}): Booking => ({
  id: BID, guest_id: GID, guest_name: 'Maria Santos', checkin_date: '2026-12-01', checkout_date: '2026-12-03', pax: 2,
  total_amount: 4000, deposit_amount: 4000, status: 'confirmed', channel: 'facebook', ...o,
});
const SETTINGS = [
  { key: 'wifi_ssid', value: 'CascadeNet' }, { key: 'wifi_password', value: 'hunter22' },
  { key: 'onground_name', value: 'Honey' }, { key: 'onground_phone', value: '+639918538269' },
];

type Calls = { thread: number; booking: string[]; id: number; settings: number };
function fake(o: { thread?: Thread | null; booking?: Booking | null; idOnFile?: boolean; auth?: Awaited<ReturnType<Deps['authenticate']>> } = {}) {
  const calls: Calls = { thread: 0, booking: [], id: 0, settings: 0 };
  const deps: Deps = {
    authenticate: () => Promise.resolve(o.auth ?? { ok: true }),
    loadThread: (psid) => { calls.thread++; return Promise.resolve(o.thread && o.thread.psid === psid ? o.thread : null); },
    loadBooking: (id) => { calls.booking.push(id); return Promise.resolve(o.booking && o.booking.id === id ? o.booking : null); },
    idOnFile: () => { calls.id++; return Promise.resolve(o.idOnFile ?? false); },
    settings: () => { calls.settings++; return Promise.resolve(SETTINGS); },
    rateCard: () => Promise.resolve(SEED_CARD),
    now: () => NOW,
  };
  return { deps, calls };
}
const post = (body: unknown, headers: Record<string, string> = { authorization: 'Bearer owner.jwt' }) =>
  new Request('https://example.test/staff-reply-context', { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) });
const thread = (history: Turn[], flow: Thread['booking_flow'] = null, name: string | null = 'Maria Reyes'): Thread => ({ psid: PSID, guest_name: name, history, booking_flow: flow });
// deno-lint-ignore no-explicit-any
const run = async (deps: Deps, body: Record<string, unknown> = { psid: PSID }): Promise<{ status: number; j: any; raw: string }> => {
  const res = await handleReplyContext(post(body), deps);
  const raw = await res.text();
  return { status: res.status, j: JSON.parse(raw), raw };
};

Deno.test('context: linked confirmed booking wins over chat dates', async () => {
  const t = thread([guest('Hi, is Dec 20 to 22 open for 4 guests?', '2026-11-27T10:00:00Z')], flowOf({ step: 'confirmed', booking_id: BID, checkin: '2026-12-10', checkout: '2026-12-12', pax: 3 }));
  const { deps } = fake({ thread: t, booking: stay() });
  const { status, j } = await run(deps);
  assertEquals(status, 200);
  assertEquals(j.link, 'flow');
  assertEquals(j.stage, 'booked');
  assertEquals(j.booking, { id: BID, ref: 'DIR-7F3A21C9', status: 'confirmed', channel: 'facebook' });
  assertEquals(j.values.checkin_date.v, '2026-12-01');
  assertEquals(j.values.checkout_date.v, '2026-12-03');
  assertEquals(j.values.checkin_date.src, 'booking');
  assertEquals(j.values.nights.v, 2);
  assertEquals(j.values.guests, { v: 2, src: 'booking', at: null });
  assertEquals(j.values.first_name, { v: 'Maria', src: 'booking', at: null });
  assertEquals(j.values.total.v, 4000);
  assertEquals(j.values.balance.v, 0);
  assertEquals(j.values.balance_line.v, 'Paid in full');
});

Deno.test('context: newest guest message beats an older flow', async () => {
  const t = thread([guest('actually can we do Dec 20 to 22 for 4 guests?', '2026-11-27T10:00:00Z')], flowOf({ checkin: '2026-12-10', checkout: '2026-12-12', pax: 2, updated_at: '2026-11-26T01:00:00Z' }));
  const { j } = await run(fake({ thread: t }).deps);
  assertEquals(j.link, 'none');
  assertEquals(j.stage, 'asking');
  assertEquals(j.values.checkin_date, { v: '2026-12-20', src: 'chat', at: '2026-11-27T10:00:00.000Z' });
  assertEquals(j.values.checkout_date.v, '2026-12-22');
  assertEquals(j.values.guests.v, 4);
  assertEquals(j.stale, true); // the flow is older than the newest guest message
  assertEquals(j.values.total.src, 'quote');
  // the same flow, NEWER than that message, wins instead
  const t2 = thread([guest('Dec 20 to 22 for 4 guests?', '2026-11-25T10:00:00Z')], flowOf({ checkin: '2026-12-10', checkout: '2026-12-12', pax: 2, updated_at: '2026-11-26T01:00:00Z' }));
  const r2 = await run(fake({ thread: t2 }).deps);
  assertEquals(r2.j.values.checkin_date.v, '2026-12-10');
  assertEquals(r2.j.values.guests.v, 2);
  assertEquals(r2.j.stale, false);
});

Deno.test('context: a past check-in is dropped', async () => {
  const t = thread([guest('hello', '2026-11-27T10:00:00Z')], flowOf({ checkin: '2026-11-10', checkout: '2026-11-12', pax: 2, updated_at: '2026-11-27T11:00:00Z' }));
  const { j } = await run(fake({ thread: t }).deps);
  assertEquals(j.values.checkin_date.v, null);
  assertEquals(j.values.checkout_date.v, null);
  assertEquals(j.values.nights.v, null);
  assertEquals(j.values.total.v, null);
});

Deno.test('context: gated is absent for an asking guest', async () => {
  const t = thread([guest('Dec 20 to 22 for 2?', '2026-11-27T10:00:00Z')]);
  const { deps, calls } = fake({ thread: t });
  const { j, raw } = await run(deps);
  assertEquals(j.stage, 'asking');
  assert(!('gated' in j));
  assertEquals(j.pin_allowed, false);
  assertEquals(calls.settings, 0, 'the Wi-Fi settings are not even read');
  assert(!raw.includes('hunter22') && !raw.includes('CascadeNet'));
});

Deno.test('context: gated is absent when link is none even if a name and dates match a stay', async () => {
  // a confirmed stay exists for "Maria Santos", Dec 1-3; the guest writes the same name and dates but the thread has no booking link
  const t = thread([guest('Hi it is Maria Santos, our stay Dec 1 to 3 for 2', '2026-11-27T10:00:00Z')], flowOf({ name: 'Maria Santos', checkin: '2026-12-01', checkout: '2026-12-03', pax: 2 }));
  const { deps, calls } = fake({ thread: t, booking: stay(), idOnFile: true });
  const { j, raw } = await run(deps);
  assertEquals(j.link, 'none');
  assertEquals(j.booking, null);
  assert(!('gated' in j));
  assertEquals(j.pin_allowed, false);
  assertEquals(calls.booking, [], 'no booking is looked up by name or dates');
  assertEquals(calls.settings, 0);
  assert(!raw.includes('hunter22'));
  assertEquals(j.values.first_name.v, 'Maria');
  assertEquals(j.values.first_name.src, 'chat');
});

Deno.test('context: gated appears for a flow-linked or picked confirmed stay; a past or pending one gets none', async () => {
  const t = thread([guest('hi', '2026-11-27T10:00:00Z')], flowOf({ step: 'confirmed', booking_id: BID }));
  const flowRun = await run(fake({ thread: t, booking: stay(), idOnFile: true }).deps);
  assertEquals(flowRun.j.link, 'flow');
  assertEquals(flowRun.j.gated.address, 'Blk 47 Lot 39, Bria Homes, Conel Road, Brgy. San Isidro, General Santos City');
  assertEquals(flowRun.j.gated.maps_link, 'https://maps.app.goo.gl/9vn8KyDwNrXPmJqT9');
  assertEquals(flowRun.j.gated.guide_link, 'https://tinyurl.com/WelcomeToCascade');
  assertEquals(flowRun.j.gated.wifi_name, 'CascadeNet');
  assertEquals(flowRun.j.gated.wifi_password, 'hunter22');
  assert(flowRun.j.gated.onground_contact.startsWith('Honey'));
  // picked from a list (no thread at all: an Airbnb paste)
  const pickRun = await run(fake({ booking: stay() }).deps, { text: 'what is the wifi?', platform: 'airbnb', booking_id: BID });
  assertEquals(pickRun.j.link, 'picked');
  assert('gated' in pickRun.j);
  assertEquals(pickRun.j.values.booking_link.v, null, 'Airbnb never gets the booking link');
  // picked but the stay is over: bound for values, nothing gated
  const past = stay({ checkin_date: '2026-11-20', checkout_date: '2026-11-22' });
  const pastRun = await run(fake({ booking: past, idOnFile: true }).deps, { text: 'thanks', booking_id: BID });
  assertEquals(pastRun.j.stage, 'checked_out');
  assert(!('gated' in pastRun.j));
  assertEquals(pastRun.j.pin_allowed, false);
  // picked but still pending: no gated
  const pend = await run(fake({ booking: stay({ status: 'pending', deposit_amount: 0 }) }).deps, { text: 'hi', booking_id: BID });
  assertEquals(pend.j.stage, 'awaiting_payment');
  assert(!('gated' in pend.j));
  // a picked booking that does not exist binds nothing
  const missing = await run(fake({}).deps, { text: 'hi', booking_id: OTHER });
  assertEquals(missing.j.link, 'none');
});

Deno.test('context: pin_allowed false without id_on_file', async () => {
  const t = thread([guest('hi', '2026-11-27T10:00:00Z')], flowOf({ step: 'confirmed', booking_id: BID }));
  const noId = await run(fake({ thread: t, booking: stay(), idOnFile: false }).deps);
  assertEquals(noId.j.pin_allowed, false);
  const withId = await run(fake({ thread: t, booking: stay(), idOnFile: true }).deps);
  assertEquals(withId.j.pin_allowed, true);
  // an unpaid balance blocks the PIN even with an ID on file
  const owing = await run(fake({ thread: t, booking: stay({ deposit_amount: 1000 }), idOnFile: true }).deps);
  assertEquals(owing.j.values.balance.v, 3000);
  assertEquals(owing.j.pin_allowed, false);
});

Deno.test('context: the PIN is never in the response', async () => {
  const t = thread([guest('hi, my door code please', '2026-11-27T10:00:00Z')], flowOf({ step: 'confirmed', booking_id: BID }));
  // a booking row that (wrongly) carries a PIN under several names: nothing outside the whitelisted columns is copied
  const dirty = { ...stay(), door_pin: '482913', pin: '482913', door_code: '482913' } as Booking;
  const { j, raw } = await run(fake({ thread: t, booking: dirty, idOnFile: true }).deps);
  assertEquals(j.pin_allowed, true);
  assert(!raw.includes('482913'));
  assert(!/"(door_pin|pin|door_code)"\s*:/.test(raw), 'no pin key in the body');
  assertEquals(j.needs_input, ['door_pin', 'outage_date', 'outage_times']);
  assert(!('door_pin' in j.values) && !('door_pin' in j.gated));
});

Deno.test('context: 403 for a cleaner session', async () => {
  const { deps, calls } = fake({ thread: thread([]), booking: stay(), auth: { ok: false, status: 403, error: 'staff_access_denied' } });
  const { status, j } = await run(deps);
  assertEquals(status, 403);
  assertEquals(j.error, 'staff_access_denied');
  assertEquals(calls.thread + calls.booking.length + calls.id + calls.settings, 0, 'no service-role read before the staff check passes');
  // no bearer token at all
  const res = await handleReplyContext(post({ psid: PSID }, {}), fake().deps);
  assertEquals(res.status, 401);
});

Deno.test('context: image_ok false after 24 h, open true until 7 days', async () => {
  const at = (hoursAgo: number) => new Date(NOW.getTime() - hoursAgo * 3_600_000).toISOString();
  const fresh = await run(fake({ thread: thread([guest('hi', at(2))]) }).deps);
  assertEquals(fresh.j.reply_window.open, true);
  assertEquals(fresh.j.reply_window.image_ok, true);
  const day2 = await run(fake({ thread: thread([guest('hi', at(30))]) }).deps);
  assertEquals(day2.j.reply_window.open, true);
  assertEquals(day2.j.reply_window.image_ok, false);
  assertEquals(day2.j.reply_window.closes_at, new Date(NOW.getTime() - 30 * 3_600_000 + 7 * 24 * 3_600_000).toISOString());
  const day8 = await run(fake({ thread: thread([guest('hi', at(8 * 24))]) }).deps);
  assertEquals(day8.j.reply_window.open, false);
  assertEquals(day8.j.reply_window.image_ok, false);
});

Deno.test('context: body validation and a missing thread', async () => {
  const { deps } = fake({ thread: thread([bot('hello', '2026-11-27T10:00:00Z')]) });
  assertEquals((await run(deps, {})).status, 400);
  assertEquals((await run(deps, { psid: PSID, booking_id: 'not-a-uuid' })).status, 400);
  assertEquals((await run(deps, { psid: 'nobody' })).status, 404);
  assertEquals((await handleReplyContext(new Request('https://example.test/x', { method: 'GET' }), deps)).status, 405);
});
