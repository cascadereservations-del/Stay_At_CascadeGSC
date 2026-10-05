// deno test --no-check -A messenger-concierge/priority.test.ts
// Session 59 (Lloyd 2026-09-28): priority help for a guest staying now - menu button / guide link, the welcome guide's own
// check (check-in date + booking-name initial, stay on today), then the urgent host card; a stranger gets two tries, an
// ordinary card and the phone route, and no second verification for 24 h.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { DEFAULT_CONTACT } from '../_shared/cascade-core/contact.ts';
import { postbackText, priorityAnswer, priorityEntry, stayIsCurrent } from './priority.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { handle, probeEffects } = await import('./index.ts');

const now = new Date('2026-09-28T04:00:00Z'); // noon, Sept 28 in Manila
const ago = (h: number) => new Date(now.getTime() - h * 3_600_000).toISOString();

Deno.test('entry: the menu button, the ice breaker, and the guide link (open thread or brand-new thread)', () => {
  assertEquals(priorityEntry({ postback: { payload: 'PRIORITY' } }), { kind: 'start' });
  assertEquals(priorityEntry({ referral: { ref: 'priority' } }), { kind: 'start' });
  assertEquals(priorityEntry({ referral: { ref: 'priority:2026-09-27:A' } }), { kind: 'verify', date: '2026-09-27', initial: 'A' });
  assertEquals(priorityEntry({ postback: { payload: 'GET_STARTED', referral: { ref: 'priority:2026-09-27:a' } } }), { kind: 'verify', date: '2026-09-27', initial: 'a' });
  assertEquals(priorityEntry({ postback: { payload: 'GET_STARTED' } }), null);
  assertEquals(priorityEntry({ message: { text: 'priority' } }), null);
});

Deno.test('answer: a check-in the guest is living is this year, and the initial comes from the name', () => {
  assertEquals(priorityAnswer('Sept 27, Allyssa Estenzo', now), { date: '2026-09-27', initial: 'A' });
  assertEquals(priorityAnswer('27 sept po, A', now), { date: '2026-09-27', initial: 'A' });
  assertEquals(priorityAnswer('checked in yesterday, Ana', now), { date: '2026-09-27', initial: 'A' });
  assertEquals(priorityAnswer('today po, Ben', now), { date: '2026-09-28', initial: 'B' });
  assertEquals(priorityAnswer('Allyssa', now).date, null);
});

Deno.test('current stay: in-house or arriving today, the name matched', () => {
  const r = (checkin_date: string, checkout_date: string, match = true) => ({ found: true, match, checkin_date, checkout_date });
  assertEquals(stayIsCurrent(r('2026-09-27', '2026-09-29'), now), true);
  assertEquals(stayIsCurrent(r('2026-09-28', '2026-09-29'), now), true);
  assertEquals(stayIsCurrent(r('2026-09-26', '2026-09-28'), now), true); // departure day, before they leave
  assertEquals(stayIsCurrent(r('2026-09-25', '2026-09-27'), now), false);
  assertEquals(stayIsCurrent(r('2026-09-27', '2026-09-29', false), now), false);
  assertEquals(stayIsCurrent(null, now), false);
});

// deno-lint-ignore no-explicit-any
function fakeDb(row: any, verify: any) {
  const writes: Array<{ table: string; op: string; v: any }> = [], rpcs: any[] = [];
  const q = (table: string): any => new Proxy({}, { get(_t, k) {
    if (k === 'then') return (res: (x: unknown) => void) => res({ data: [], error: null });
    if (k === 'maybeSingle' || k === 'single') return () => Promise.resolve({ data: table === 'concierge_threads' ? row : null, error: null });
    if (k === 'upsert' || k === 'insert' || k === 'update') return (v: any) => { writes.push({ table, op: String(k), v }); return q(table); };
    return () => q(table);
  } });
  return { db: { from: q, rpc: (name: string, args: unknown) => { if (name !== 'verify_booking') return Promise.resolve({ data: null, error: { message: 'not in test' } }); rpcs.push({ name, args }); return Promise.resolve({ data: verify, error: null }); } }, writes, rpcs };
}
// deno-lint-ignore no-explicit-any
async function turn(ev: Record<string, any>, history: any[] = [], verify: any = null) {
  const row = { psid: 'probe:p1', guest_name: 'Allyssa', human_until: null, bot_turns: 1, last_risk: null, last_mid: null, booking_flow: null, history };
  const { db, writes, rpcs } = fakeDb(row, verify);
  const calls: Array<{ fx: string; text?: string; detail?: any }> = [];
  await handle(db as any, { sender: { id: 'probe:p1' }, recipient: { id: 'page' }, ...ev }, 'auto', probeEffects(calls as any, 'Allyssa', now), now);
  const saved = writes.find((w) => w.table === 'concierge_threads' && w.op === 'upsert')?.v;
  return { reply: calls.filter((c) => c.fx === 'send').map((c) => c.text).join('\n\n'), handoffs: calls.filter((c) => c.fx === 'handoff'), saved, rpcs };
}
const askedTurn = (tries: number | string, h = 0.1) => [{ role: 'guest', text: '[priority help]', at: ago(h) }, { role: 'bot', text: 'ask', at: ago(h), route: { priority: tries } }];
const stay = { found: true, expired: false, match: true, first_name: 'Allyssa', full_name: 'Allyssa Estenzo', checkin_date: '2026-09-27', checkout_date: '2026-09-29' };

Deno.test('the menu button asks for the check-in date and booking name, and opens nothing yet', async () => {
  const r = await turn({ postback: { payload: 'PRIORITY', mid: 'pb1' } });
  assertEquals(/check-in date and the name on your booking/.test(r.reply), true);
  assertEquals(r.handoffs.length, 0);
  assertEquals(r.saved.history.at(-1).route, { priority: 1 });
});

Deno.test('verified and staying now: one priority card (urgent), the thanks by name and the on-ground number', async () => {
  const r = await turn({ message: { mid: 'm1', text: 'Sept 27, Allyssa Estenzo' } }, askedTurn(1), stay);
  assertEquals(r.rpcs, [{ name: 'verify_booking', args: { p_checkin_date: '2026-09-27', p_initial: 'A' } }]);
  assertEquals(r.handoffs.length, 1);
  assertEquals(r.handoffs[0].detail.risk, 'priority');
  assertEquals(/^Thank you, Allyssa\. Your host has been told/.test(r.reply), true);
  assertEquals(r.reply.includes(DEFAULT_CONTACT.phone), true);
});

Deno.test('the guide link carries the check, so a verified guest types nothing', async () => {
  const r = await turn({ referral: { ref: 'priority:2026-09-27:A' }, timestamp: now.getTime() }, [], stay);
  assertEquals(r.handoffs[0]?.detail.risk, 'priority');
});

Deno.test('a stay that ended, or a wrong name: one more try, then an ordinary card and the phone route', async () => {
  const wrong = { ...stay, match: false };
  const first = await turn({ message: { mid: 'm2', text: 'Sept 27, Ben' } }, askedTurn(1), wrong);
  assertEquals(/couldn't quite find today's stay/.test(first.reply), true);
  assertEquals(first.handoffs.length, 0);
  const second = await turn({ message: { mid: 'm3', text: 'Sept 26, Ben' } }, askedTurn(2), wrong);
  assertEquals(second.handoffs.map((h) => h.detail.risk), ['uncertain']);
  assertEquals(/Your message is with your host/.test(second.reply) && second.reply.includes(DEFAULT_CONTACT.phone), true);
  assertEquals(second.saved.history.at(-1).route, { priority: 'unmatched' });
});

Deno.test('after an unmatched try the next 24 h skip the check, so restarting from the menu cannot guess it', async () => {
  const r = await turn({ message: { mid: 'm4', text: 'Sept 27, Allyssa' } }, [...askedTurn('unmatched', 2), ...askedTurn(1)], stay);
  assertEquals(r.rpcs.length, 0);
  assertEquals(r.handoffs.map((h) => h.detail.risk), ['uncertain']);
});

Deno.test('after the ask, a message with no date is an ordinary turn (a complaint is never swallowed)', async () => {
  const r = await turn({ message: { mid: 'm5', text: 'the aircon is not working' } }, askedTurn(1), stay);
  assertEquals(r.rpcs.length, 0);
  assertEquals(r.saved?.history.at(-1).route?.priority, undefined);
});

Deno.test('any other menu tap is the guest asking in the button words', async () => {
  const r = await turn({ postback: { title: 'I forgot the door code', payload: 'DOOR', mid: 'pb2' } });
  assertEquals(r.handoffs.map((h) => h.detail.risk), ['access']);
  assertEquals(r.saved.history.find((h: any) => h.role === 'guest').text, 'I forgot the door code');
});

Deno.test('Get Started is a hello; the priority button and the guide link are not questions', () => {
  assertEquals(postbackText({ postback: { title: 'Get Started', payload: 'GET_STARTED' } }), 'Hi');
  assertEquals(postbackText({ postback: { title: 'How much? Available?', payload: 'How much? Available?' } }), 'How much? Available?');
  assertEquals(postbackText({ postback: { title: 'Dates and price', payload: 'How much is it, and are my dates available?' } }), 'How much is it, and are my dates available?');
  assertEquals(postbackText({ postback: { title: 'Door help', payload: 'DOOR_HELP' } }), 'Door help');
  assertEquals(postbackText({ postback: { title: 'Staying now? Priority help', payload: 'PRIORITY' } }), '');
  assertEquals(postbackText({ postback: { payload: 'GET_STARTED', referral: { ref: 'priority' } } }), '');
  assertEquals(postbackText({ message: { text: 'hi' } }), '');
});

// D-281 (DESIGN-contact-host-button-2026-09-28): one "Reach my host" button, only when the guest seems to be staying now.
import { CONTACT_CHIP, contactHostChip, isStayingNow } from './priority.ts';
const base = { risk: 'routine', profileName: 'Sean', inHouse: ['Joseph Ewing'], flowActive: false, priorityOpen: false, history: [] as any[], now };
const fires = (t: string, o: Partial<typeof base> = {}) => contactHostChip(t, { ...base, ...o }) !== null;

Deno.test('the button fires on the live lockout message and on each trigger in three registers', () => {
  assertEquals(CONTACT_CHIP.title.length <= 20 && CONTACT_CHIP.payload === 'PRIORITY', true);
  const live = "Hello po ako po yong nag rerent nung airbnb now unfortunately I didn't bring a card and my phone po nakalimutan ko po yung code may i get it again naki chat lang po ako sa friend ko since i cant chat you my stay here is until Sunday po";
  assertEquals(fires(live, { risk: 'access' }), true);
  assertEquals(fires('ako po yong nag rerent nung airbnb now'), true); // the space in "nag rerent"
  for (const t of ["We're staying here right now, until Sunday", 'andito na po kami, wala pong tubig', 'Naa mi diri karon, hangtod Domingo']) assertEquals(fires(t), true, t);
  for (const t of ['Can I talk to the host?', 'Pwede po makausap ang may-ari?', 'Pwede ko ma-contact ang tag-iya?', "what is the host's number"]) assertEquals(fires(t), true, t);
  for (const t of ['My girlfriend booked, we are locked out', 'Friend ko ang nag-book, hindi kami makapasok', 'Uyab nako ang nag-book, walay tubig']) assertEquals(fires(t, { risk: 'access' }), true, t);
  assertEquals(fires('This is Joseph po', { profileName: null }), true); // named the in-house guest
  assertEquals(fires('is there parking?', { profileName: 'Joseph' }), true); // the in-house guest's own account
});

Deno.test('the button stays away from prospects, past guests, a booking in progress and a second time', () => {
  for (const t of ['Where do we stay near the mall?', 'I stayed here last year', 'Can I contact the host before booking?', 'We rented here last year, how much now?', 'My friend booked here last year, how much now?', 'is there parking?']) {
    assertEquals(fires(t), false, t);
  }
  assertEquals(fires('Can I talk to the host?', { flowActive: true }), false);
  assertEquals(fires('Can I talk to the host?', { priorityOpen: true }), false);
  assertEquals(fires('Can I talk to the host?', { history: [{ role: 'bot', at: ago(2), route: { chip: 'PRIORITY' } }] }), false);
  assertEquals(fires('Can I talk to the host?', { history: [{ role: 'bot', at: ago(13), route: { chip: 'PRIORITY' } }] }), true);
});

Deno.test('a tap on the button enters priority help in the guest register, not the English label', async () => {
  const r = await turn({ message: { mid: 'q1', text: 'Reach my host', quick_reply: { payload: 'PRIORITY' } } }, [{ role: 'guest', text: 'andito na po kami, wala pong tubig', at: ago(0.2) }, { role: 'bot', text: 'x', at: ago(0.2) }]);
  assertEquals(/^Sige po, nandito lang kami/.test(r.reply), true, r.reply);
  assertEquals(r.saved.history.at(-2).route, { src: 'chip' });
});

Deno.test('a guest at the residence now is staying (no booking pitch); a past or prospective guest is not', () => {
  for (const t of ["I'm staying here right now until Sunday, is there parking?", 'andito na po kami', 'ako po yong nag rerent nung airbnb now']) assertEquals(isStayingNow(t), true, t);
  for (const t of ['is there parking?', 'I stayed here last year', 'We rented here last year, how much now?', 'can we stay 3 nights?']) assertEquals(isStayingNow(t), false, t);
});
