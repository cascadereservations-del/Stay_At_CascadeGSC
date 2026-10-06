// deno test --no-lock --node-modules-dir=auto --allow-env --allow-read messenger-concierge/s74.test.ts
// Session 74 lane G1: "<N> days from <date>" is a stay; a past stay + price ask is not priced or held; sendHostReply claims first.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { answer, bookingStart, start, stayFromPhrase, type Flow } from './booking.ts';
import { setProviderKey } from '../_shared/cascade-core/providers.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, priceAnchor, pricedStay, probeEffects, sendHostReply } = await import('./index.ts');

const now = new Date('2026-10-06T06:00:00Z');
const ago = (m: number) => new Date(now.getTime() - m * 60_000).toISOString();
// deno-lint-ignore no-explicit-any
type Any = any;
function fakeDb(row: Any) {
  const q = (table: string): Any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    return () => q(table);
  } });
  return { from: q };
}
/** The model's JSON for every draft this turn; `seen` keeps each prompt's last user message (the hints ride on it). */
function stubModel(answerText: string) {
  const seen: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    if (!String(url).includes('openrouter.ai')) return Promise.resolve(new Response('{}', { status: 500 }));
    seen.push(String(JSON.parse(String(init?.body ?? '{}')).messages?.at(-1)?.content ?? ''));
    return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify({ answer: answerText, ask: null, uncertain: false }) }, finish_reason: 'stop' }] }), { status: 200 }));
  }) as typeof fetch;
  setProviderKey('test');
  return { seen, restore: () => { globalThis.fetch = real; setProviderKey(null); } };
}
async function turn(text: string, bf: Flow | null = null) {
  const row = { psid: 'probe:s74', guest_name: 'Ben', human_until: null, bot_turns: 0, last_risk: null, last_mid: null, booking_flow: bf, history: [] };
  const calls: Array<{ fx: string; text?: string }> = [];
  await handle(fakeDb(row) as Any, { sender: { id: 'probe:s74' }, recipient: { id: 'page' }, message: { mid: 'm-' + Math.random(), text } }, 'auto', probeEffects(calls as Any, 'Ben', now), now);
  return { reply: calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n'), calls };
}

// ---- 1. "<N> days|nights from|starting <date>" ----
const PHRASES = [
  '5 days from December 25 po', '5 nights from Dec 25', '5 days starting December 25', 'five nights starting Dec 25 please',
  '5 araw simula December 25 po', 'limang gabi simula Dec 25', '5 araw mula Dec 25', '5 ka adlaw gikan Dec 25', 'lima ka gabii gikan sa December 25',
];
Deno.test('s74 G1.1: every "<N> days|nights from <date>" variant is Dec 25 to 30', () => {
  for (const t of PHRASES) {
    assertEquals(stayFromPhrase(t, now), { checkin: '2026-12-25', checkout: '2026-12-30' }, t);
    const f = start(`can I book ${t}`, now); // the flow starts with both dates and asks only the guests next
    assertEquals([f.checkin, f.checkout, f.step], ['2026-12-25', '2026-12-30', 'pax'], t);
    assertEquals(pricedStay([`how much, ${t}`], now), { checkin: '2026-12-25', checkout: '2026-12-30' }, t); // days count as nights, as stayNights does
  }
  // not a stay phrase: two dates are the range, no date is no stay, a past-this-year date rolls as parseDates does, over 60 is not one
  assertEquals(stayFromPhrase('3 days from Dec 20 to Dec 25', now), null);
  assertEquals(stayFromPhrase('5 days from now', now), null);
  assertEquals(stayFromPhrase('90 days from Dec 25', now), null);
});

Deno.test('s74 G1.1: at the nights ask, "5 days from Dec 25" answers it instead of a retry', () => {
  const f: Flow = { ...start('Can I book Dec 25', now), updated_at: now.toISOString() };
  assertEquals(f.step, 'checkout');
  const s = answer(f, '5 days from December 25 po', now);
  assertEquals([s.flow.checkin, s.flow.checkout, s.flow.step], ['2026-12-25', '2026-12-30', 'pax']);
  const d = answer({ ...f, step: 'dates', checkin: undefined }, '5 araw simula December 25', now);
  assertEquals([d.flow.checkin, d.flow.checkout, d.flow.step], ['2026-12-25', '2026-12-30', 'pax']);
});

Deno.test('s74 G1.1: through handle(), the model is told the whole stay, not one date', async () => {
  const m = stubModel('Yes po, we have space then.');
  try {
    await turn('is there parking? 5 days from December 25 po');
    assert(m.seen[0].includes('Dec 25 to 30'), m.seen[0].slice(0, 300));
  } finally { m.restore(); }
});

// ---- 2. a past stay told about + a price ask ----
const PAST = ['last time we stayed Sep 5 to 7, how much now?', 'dati po kaming nag-stay Sep 5 to 7, magkano po ngayon?', 'niadtong Sep 5 to 7 mi nag-stay, tagpila karon?',
  'we stayed before, Sep 5 to 7, what is the rate?'];
Deno.test('s74 G1.2: a past stay and a price ask is not priced, not started, and asks the new dates', async () => {
  for (const t of PAST) {
    assertEquals(pricedStay([t], now), null, t);
    assertEquals(priceAnchor([t], now).text, '', t);
    assertEquals(bookingStart(`can we book the same dates? ${t}`, [], '', now), null, t);
    const r = await turn(t); // no model stub: the reply is code's, so a model call would fail the turn
    assert(/\bdates\b/i.test(r.reply) && !/PHP|₱/.test(r.reply) && !/hold/i.test(r.reply), `${t} -> ${r.reply}`);
  }
});

Deno.test('s74 G1.2: the s73 R4-2 case still prices - a past-stay word with a date still ahead', () => {
  assertEquals(pricedStay(['same as last year po, Oct 19 to 21, how much?'], now), { checkin: '2026-10-19', checkout: '2026-10-21' });
  assertEquals(bookingStart('can I book Oct 19 to 21? we stayed before', [], '', now) !== null, true);
});

// ---- 3. sendHostReply claims the row before it sends ----
/** concierge_handoffs as a table: the claim is one atomic update on the shared rows, like the real conditional update. */
function handoffDb(rows: Any[]) {
  const from = (table: string) => {
    let op = 'select', patch: Any = null, sel = false; const filters: Array<[string, unknown]> = [];
    const hit = () => rows.filter((r) => filters.every(([k, v]) => r[k] === v));
    const b: Any = {
      select() { if (op === 'update') sel = true; return b; }, eq(k: string, v: unknown) { filters.push([k, v]); return b; },
      order() { return b; }, limit() { return b; }, update(v: unknown) { op = 'update'; patch = v; return b; },
      upsert: () => Promise.resolve({ data: null, error: null }),
      maybeSingle: () => Promise.resolve({ data: table === 'concierge_threads' ? { history: [] } : null, error: null }),
      then(res: (x: unknown) => void) {
        if (table !== 'concierge_handoffs') return res({ data: [], error: null });
        if (op === 'update') { const m = hit(); m.forEach((r) => Object.assign(r, patch)); return res({ data: sel ? m.map((r) => ({ id: r.id })) : null, error: null }); }
        return res({ data: hit(), error: null });
      },
    };
    return b;
  };
  return { from };
}
async function hostReply(rows: Any[], accept: boolean, twice: boolean) {
  let sends = 0;
  const real = globalThis.fetch;
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    if (String(url).includes('/messages?') && String(init?.body).includes('"message"')) { sends++; return Promise.resolve(new Response('{}', { status: accept ? 200 : 400 })); }
    return Promise.resolve(new Response('{}', { status: 200 }));
  }) as typeof fetch;
  try {
    const db = handoffDb(rows) as Any, from = { id: 1, first_name: 'Lloyd' };
    await Promise.all([sendHostReply(db, 'abcd1234', 'Yes, we can help.', from), ...(twice ? [sendHostReply(db, 'abcd1234', 'Yes, we can help.', from)] : [])]);
  } finally { globalThis.fetch = real; }
  return sends;
}
const handoff = (): Any[] => [{ id: 'abcd1234-0000-4000-8000-000000000000', psid: 'p1', status: 'open', guest_name: 'Ben', guest_text: 'hello', tg_message_id: null, sent_text: null }];

Deno.test('s74 G1.3: two concurrent host replies on one handoff send once; a refused send puts it back to open', async () => {
  const rows = handoff();
  assertEquals(await hostReply(rows, true, true), 1);
  assertEquals([rows[0].status, rows[0].resolved_by], ['sent', 'Lloyd']);
  const refused = handoff();
  assertEquals(await hostReply(refused, false, false), 1);
  assertEquals([refused[0].status, refused[0].sent_text, refused[0].resolved_by], ['open', null, null]); // still open: Tap again works
});

// ---- Fable audit fixes ----
Deno.test('s74 G1 audit 1: a past stay and "book again" (no price word) starts no flow and asks the new dates', async () => {
  for (const t of ['previous booking Sep 5-7, can we book again same dates next month?', 'we booked before Sep 5-7, can we book again same dates?',
    'dati po kaming nag-book Sep 5 to 7, pwede po ba ulit mag-book?']) {
    assertEquals(bookingStart(t, [], '', now), null, t);
    const r = await turn(t);
    assert(/\bdates\b/i.test(r.reply) && !/PHP|₱|hold/i.test(r.reply), `${t} -> ${r.reply}`);
  }
  // not rolled: the date is still ahead, so a past-stay word beside it is an ordinary booking
  assertEquals(bookingStart('can I book Oct 19 to 21? we stayed before', [], '', now) !== null, true);
  assertEquals(bookingStart('we booked before, can I book Oct 19 to 21 again?', [], '', now) !== null, true);
});

Deno.test('s74 G1 audit 2: "this coming January" names the stay asked for, a past-stay word notwithstanding', () => {
  assertEquals(pricedStay(['we stayed last year Jan 2 to 4, same dates this coming January how much?'], now), { checkin: '2027-01-02', checkout: '2027-01-04' });
  assertEquals(pricedStay(['we stayed last year Jan 2 to 4, same dates next year how much?'], now), { checkin: '2027-01-02', checkout: '2027-01-04' });
  assertEquals(pricedStay(['we stayed last year Jan 2 to 4, same dates again how much?'], now), null); // "again" alone is not an exemption
});

Deno.test('s74 G1 audit 3: "within 5 days from Dec 25" is a policy question, not a stay', () => {
  assertEquals(stayFromPhrase('within 5 days from Dec 25 can I cancel?', now), null);
  assertEquals(stayFromPhrase('5 days from Dec 25 can I cancel?', now), { checkin: '2026-12-25', checkout: '2026-12-30' });
});

// ---- Fable re-verify: next-year bookings (Jan to early Oct 2027 are "rolled") are not past stays ----
Deno.test('s74 G1 re-verify: a real next-year booking or price ask mentioning a past visit, or "before", is handled normally', async () => {
  for (const t of ['can I book Jan 2 to 4? we stayed before', 'book Jan 2 to 4 please, we stayed before', 'is Jan 2 to 4 available? we stayed before'])
    assertEquals(bookingStart(t, [], '', now) !== null, true, t);
  assertEquals(pricedStay(['I booked Jan 2 to 4, how much is the balance?'], now), { checkin: '2027-01-02', checkout: '2027-01-04' });
  assertEquals(pricedStay(['nag-book po kami Jan 2 to 4, magkano pa ang babayaran?'], now), { checkin: '2027-01-02', checkout: '2027-01-04' });
  assertEquals(pricedStay(['I need to pay before Jan 2, how much?'], now)?.checkin, '2027-01-02');
  for (const t of ['I booked Jan 2 to 4, how much is the balance?', 'nag-book po kami Jan 2 to 4, magkano pa ang babayaran?', 'I need to pay before Jan 2, how much?']) {
    const m = stubModel('Noted po.');
    try { const r = await turn(t); assert(!/Which dates would you like this time|Aling dates po ang gusto/.test(r.reply), `${t} -> ${r.reply}`); } finally { m.restore(); }
  }
  for (const t of ['previous booking Sep 5-7, can we book again same dates next month?', 'we booked before Sep 5-7, can we book again same dates?', 'dati po kaming nag-book Sep 5 to 7, pwede po ba ulit mag-book?'])
    assertEquals(bookingStart(t, [], '', now), null, t);
});
