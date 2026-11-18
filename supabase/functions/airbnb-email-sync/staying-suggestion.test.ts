// deno test -A airbnb-email-sync/staying-suggestion.test.ts
// S119: the "who is staying" suggestion. Synthetic names and numbers only (public repo).
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { handleMessage, type MessageDeps } from './message.ts';
import { stayingSuggestion as s } from './staying-suggestion.ts';

const B = 'Jonas Example';

Deno.test('suggestion: the booker books for someone else', () => {
  assertEquals(s('Hi! I am booking for my mother Rosa Cruz.', B), 'Rosa Cruz (mother)');
  assertEquals(s('Hello, it is for my friend Ana and Ben.', B), 'Ana, Ben (friend)');
  assertEquals(s('I booked this for my parents', B), 'Parents of Jonas');
  assertEquals(s('This booking is for my parents and my sister.', B), 'Parents and sister of Jonas');
  assertEquals(s('Booking for Ana Cruz and Ben Cruz po', B), 'Ana Cruz, Ben Cruz');
  assertEquals(s('The reservation is for my family, thank you', null), 'Family');
});

Deno.test('suggestion: the guest says who will be staying', () => {
  assertEquals(s('Good day! My parents will be staying, they arrive at 3pm.', B), 'Parents of Jonas');
  assertEquals(s('my friends Ana and Ben are the ones staying', B), 'Ana, Ben (friends)');
  assertEquals(s('My mother Rosa will be staying with us', B), 'Rosa (mother)');
  assertEquals(s('Our colleagues will be checking in on Friday', B), 'Colleagues of Jonas');
});

Deno.test('suggestion: a group list, with the booker named for "me"', () => {
  assertEquals(s('We are 3: me, Ana, Ben', B), 'Jonas Example, Ana, Ben');
  assertEquals(s('We are 3: me, Ana, Ben', null), 'Ana, Ben');
  assertEquals(s('We are 4 (me, Ana Cruz, Ben Cruz and Carla)', B), 'Jonas Example, Ana Cruz, Ben Cruz, Carla');
  assertEquals(s('there are 2 of us: Ana and Ben', B), 'Ana, Ben');
});

Deno.test('suggestion: Filipino and Taglish phrasing', () => {
  assertEquals(s('Pa-book po para kay Rosa Cruz', B), 'Rosa Cruz');
  assertEquals(s('Pa-book po para sa nanay ko', B), 'Nanay of Jonas');
  assertEquals(s('Kasama ko si Ana at Ben', B), 'Jonas Example, Ana, Ben');
  assertEquals(s('Kasama namin sina Ana at Ben po', B), 'Jonas Example, Ana, Ben');
  assertEquals(s('Ang mga magulang ko ang mag-stay po', B), 'Magulang of Jonas');
});

Deno.test('suggestion: one clear reading only', () => {
  assertEquals(s('We are 3: me, Ana, Ben. Booking for my mother Rosa.', B), null, 'two different readings: say nothing');
  assertEquals(s('Booking for my parents. My parents will be staying.', B), 'Parents of Jonas', 'same reading twice is fine');
});

Deno.test('suggestion: phone numbers, e-mails, links and amounts never get in', () => {
  const r = s('Booking for my mother Rosa Cruz, her number is 0917 123 4567 or rosa@example.com. Total PHP 4,500', B);
  assertEquals(r, 'Rosa Cruz (mother)');
  assert(!/[\d@]/.test(r!));
  assertEquals(s('We are 3: me, 0917 123 4567, Ben', B), null);
  assertEquals(s('Booking for Ana Cruz 09171234567', B), null, 'a number glued to the name is not a clear reading');
  assertEquals(s('Booking for my parents, see https://example.com/x', B), 'Parents of Jonas');
});

Deno.test('suggestion: negatives - nothing to say', () => {
  for (const t of [
    '', 'Hello po, what time is check-in?', 'We will arrive at 3pm', 'Booking for Christmas', 'Booking for December 24 to 26', 'It is for my birthday',
    'It is for my friends birthday', 'Booking for my parents wedding anniversary', 'Is the booking for my parents ok?', 'Can my parents stay too?',
    'My parents will not be staying', 'My parents will be staying at their hotel', "My wife's parents will be staying", 'My parents live in Cebu',
    'I told my parents about your place', 'Our friends recommended Cascade', 'Booking for 3 nights', 'Booking for Friday',
    'We are 3 pax', 'We are 2 adults, 1 child', 'We are 3: me, my wife and kid', 'Hi Ana and Ben, thanks', "Thank you for the booking Ma'am Rosa",
    'booking for ana and ben', // lower case: not sure these are names
    'Companions: Ana Cruz, Ben Cruz', // the companion path owns this
    'Guests are arriving at 3pm',
    'My parents will be staying at the hotel nearby', 'My parents will be staying in the hotel across the street', 'My boss will be staying at the Marriott', 'My wife will stay in the car',
    'If my parents will be staying, I will pay extra', 'Maybe my parents will be staying', 'My friend said her parents will be staying at your place',
    'My parents will be staying for a week at the hotel nearby', 'Possibly my parents will be staying', 'Hopefully my parents will be staying',
    'Her parents will be staying', 'Booking for Mr. Smith', 'Booking for ANA', 'Booking for Grab',
  ]) assertEquals(s(t, B), null, t);
});

Deno.test('suggestion: still reads real places and names', () => {
  assertEquals(s('My parents will be staying at your place', B), 'Parents of Jonas');
  assertEquals(s('My parents will be staying in the unit', B), 'Parents of Jonas');
  assertEquals(s('Booking for Ana Cruz', B), 'Ana Cruz');
});

Deno.test('suggestion: a long input is capped, not scanned', () => {
  const t0 = performance.now();
  assertEquals(s('Booking for my parents. ' + 'x '.repeat(5000), B), 'Parents of Jonas');
  assert(performance.now() - t0 < 1000);
});

Deno.test('suggestion: at most 8 people and 300 characters', () => {
  assertEquals(s('We are 12: me, Ana, Ben, Carla, Dan, Eli, Fay, Gus, Hal, Ivy, Jon, Kim', B), 'Jonas Example, Ana, Ben, Carla, Dan, Eli, Fay, Gus');
  const r = s('Booking for ' + Array.from({ length: 3 }, () => 'Abcdefghij Abcdefghij Abcdefghij').join(', ') + ', ' + 'Zz'.repeat(150), B);
  assert(r === null || r.length <= 300);
});

// ---- the handler: one RPC call, ignore refusals, never break the card ----------------------------------------------------------------------
const GID = 'e2000000-0000-4000-8000-0000000000c1';
function fake(o: { rpc?: (a: any) => Promise<any>; ce?: any[] } = {}) {
  const calls: any[] = [], pending: any[] = [];
  const tables: Record<string, any[]> = {
    airbnb_reservations: [{ id: 'R1', guest_id: GID, guest_name: 'Jonas Example', confirmation_code: 'HMSYNTH001', checkin_date: '2026-10-10', checkout_date: '2026-10-13', status: 'confirmed', property_id: 'P' }],
    calendar_events: o.ce ?? [{ property_id: 'P', uid: 'UID-1', linked_reservation_id: 'R1', status: 'confirmed' }],
    guests: [{ id: GID, name: 'Jonas Example' }], guest_profile_details: [], guest_companions: [], telegram_pending: pending,
  };
  const from = (t: string) => {
    const f: Array<(r: any) => boolean> = []; let op = 'select', ins: any = null;
    const run = () => { if (op === 'insert') { const row = { id: 'pend-1', created_at: new Date().toISOString(), ...ins }; tables[t].push(row); return row; } return tables[t].filter((r) => f.every((x) => x(r))); };
    const api: any = {
      select: () => api, insert: (r: any) => { op = 'insert'; ins = r; return api; }, delete: () => api,
      eq: (c: string, v: unknown) => { f.push((r) => String(c.split(/->>|->/).reduce((x: any, k) => x?.[k], r)) === String(v)); return api; },
      gt: () => api, gte: () => api, lte: () => api, limit: () => api,
      maybeSingle: async () => ({ data: (run() as any[])[0] ?? null }), single: async () => ({ data: run() }),
      then: (res: any) => Promise.resolve({ data: run(), error: null }).then(res),
    };
    return api;
  };
  const rpc = async (name: string, args: any) => { calls.push({ name, args }); return o.rpc ? o.rpc(args) : { data: { ok: true, unchanged: false, version: 1 }, error: null }; };
  return { db: { from, rpc }, calls, pending };
}
const mk = (f: ReturnType<typeof fake>) => {
  const posts: string[] = [];
  const d: MessageDeps = { db: f.db, propertyId: 'P', opsChatId: -1003798341977, today: '2026-10-06', esc: (x) => x, post: async (_c, t) => { posts.push(t); return true; } };
  return { d, posts };
};
const ev = (text: string, over: Record<string, unknown> = {}) => ({ gmail_message_id: 'SYNTH-1', email_date: '2026-10-06T03:00:00Z', guest_first_name: 'Jonas', confirmation_code: 'HMSYNTH001', text, ...over });

Deno.test('handler: a stated stayer calls the RPC once with the matched uid; no Telegram message, no card', async () => {
  const f = fake(); const { d, posts } = mk(f);
  const log = await handleMessage(d, ev('Hello! This booking is for my mother Rosa Cruz.'));
  assertEquals(f.calls, [{ name: 'set_stay_staying_suggestion_v1', args: { p_property: 'P', p_uid: 'UID-1', p_suggestion: 'Rosa Cruz (mother)' } }]);
  assertEquals(posts.length, 0);
  assertEquals(f.pending.length, 0);
  assertEquals(log, { guest_first_name: 'Jonas', confirmation_code: 'HMSYNTH001', matched: true, has_phone: false, names_count: 0, carded: false });
});

Deno.test('handler: the suggestion rides alongside the existing companion card, which is unchanged', async () => {
  const f = fake(); const { d, posts } = mk(f);
  const log = await handleMessage(d, ev('Booking for my friends. My number is 0917 123 4567. Companions: Ana Cruz'));
  assertEquals(f.calls.length, 1);
  assertEquals(f.calls[0].args.p_suggestion, 'Friends of Jonas');
  assertEquals([log.carded, posts.length, f.pending.length], [true, 1, 1]);
});

Deno.test('handler: {ok:false} answers and an RPC that throws or errors are ignored, the card still posts', async () => {
  for (const rpc of [async () => ({ data: { ok: false, error: 'names_set' }, error: null }), async () => ({ data: { ok: false, error: 'dismissed' }, error: null }),
    async () => ({ data: null, error: { message: 'boom' } }), async () => { throw new Error('network'); }]) {
    const f = fake({ rpc }); const { d, posts } = mk(f);
    const log = await handleMessage(d, ev('Booking for my parents. Companions: Ana Cruz'));
    assertEquals(f.calls.length, 1);
    assertEquals([log.matched, log.carded, posts.length], [true, true, 1]);
  }
});

Deno.test('handler: no calendar row, two rows, an unrelated message, or no attribution call nothing', async () => {
  let f = fake({ ce: [] }); await handleMessage(mk(f).d, ev('Booking for my parents')); assertEquals(f.calls.length, 0);
  f = fake({ ce: [{ property_id: 'P', uid: 'A', linked_reservation_id: 'R1', status: 'confirmed' }, { property_id: 'P', uid: 'B', linked_reservation_id: 'R1', status: 'confirmed' }] });
  await handleMessage(mk(f).d, ev('Booking for my parents')); assertEquals(f.calls.length, 0);
  f = fake(); await handleMessage(mk(f).d, ev('What time is check-in?')); assertEquals(f.calls.length, 0);
  f = fake(); await handleMessage(mk(f).d, ev('Booking for my parents', { confirmation_code: undefined })); assertEquals(f.calls.length, 0, 'no code and no dates: not attributable');
});

Deno.test('handler: an unlinked calendar row with the same dates is used; a different date is not', async () => {
  let f = fake({ ce: [{ property_id: 'P', uid: 'UID-D', linked_reservation_id: null, checkin_date: '2026-10-10', checkout_date: '2026-10-13', status: 'confirmed' }] });
  await handleMessage(mk(f).d, ev('Booking for my parents')); assertEquals(f.calls.map((c) => c.args.p_uid), ['UID-D']);
  f = fake({ ce: [{ property_id: 'P', uid: 'UID-X', linked_reservation_id: null, checkin_date: '2026-11-10', checkout_date: '2026-11-13', status: 'confirmed' }] });
  await handleMessage(mk(f).d, ev('Booking for my parents')); assertEquals(f.calls.length, 0);
});

Deno.test('handler: a db with no rpc at all does not break message handling', async () => {
  const f = fake(); (f.db as any).rpc = undefined; const { d, posts } = mk(f);
  const log = await handleMessage(d, ev('Booking for my parents. Companions: Ana Cruz'));
  assertEquals([log.carded, posts.length], [true, 1]);
});
