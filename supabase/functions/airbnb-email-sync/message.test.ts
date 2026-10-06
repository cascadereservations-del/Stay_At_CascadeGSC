// deno test -A airbnb-email-sync/message.test.ts
// Airbnb guest-message e-mail parsing (session 72, SPEC-42 section 2). Synthetic names, numbers and e-mails only (public repo).
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { parseGuestTap } from '../telegram-expense/guest.ts';
import { buildPlan, cardText, extract, findNames, findPhone, gateMessages, handleMessage, logRow, matchStay, secretMatches, type MessageDeps, stripQuoted, type Stay } from './message.ts';

const GID = 'e2000000-0000-4000-8000-0000000000c1';
const cand = { guest_id: GID, name: 'Jonas Example', checkin: '2026-10-10', checkout: '2026-10-13', last_stay: null, id_on_file: false, has_contact: false, companions: [] as string[] };

// ---- extract ---------------------------------------------------------------------------------------------------------------------------------
Deno.test('extract: 09 and +63 forms give the same number; a number with no prefix is not a mobile', () => {
  assertEquals(findPhone('Hi po! My number is 0917 123 4567 thanks'), '09171234567');
  assertEquals(findPhone('contact +63 917-123-4567'), '09171234567');
  assertEquals(findPhone('call 639171234567 please'), '09171234567');
  assertEquals(findPhone('room 9171234567 maybe'), null);
  assertEquals(findPhone('no digits here'), null);
});

Deno.test('extract: two different numbers - only a cued one counts; two uncued is no phone', () => {
  assertEquals(findPhone('0917 123 4567 or 0918 765 4321'), null);
  assertEquals(findPhone('my number is 0917 123 4567, my wife 0918 765 4321'), '09171234567');
  assertEquals(findPhone('0917 123 4567 and again 09171234567'), '09171234567');
  assertEquals(findPhone('paid to gcash 0956 011 5744, my number is 0917 123 4567'), '09171234567', 'the payment number is not the guest');
  assertEquals(findPhone('0956 011 5744'), null);
});

Deno.test('extract: a host number inside a quoted reply is ignored', () => {
  const t = 'my number 0918 111 2222\n> Please call us on 0917 999 8888\n> Cascade Hideaway';
  assertEquals(extract(t).phone, '09181112222');
  assertEquals(extract('On Mon, 5 Oct 2026, 10:00 AM Cascade wrote:\n0917 999 8888\nthanks').phone, null);
});

Deno.test('extract: names need a cue - Taglish and English', () => {
  assertEquals(findNames('Kasama ko si Ana Cruz at Ben Cruz'), ['Ana Cruz', 'Ben Cruz']);
  assertEquals(findNames('Companions: Ana Cruz, Ben Cruz & Carla Dela Rosa'), ['Ana Cruz', 'Ben Cruz', 'Carla Dela Rosa']);
  assertEquals(findNames('Hello! The other guests are Mara Santos and Leo Santos. See you.'), ['Mara Santos', 'Leo Santos']);
  assertEquals(findNames('Names of guests:\n1. Ana Cruz\n2. Ben Cruz\nThank you'), ['Ana Cruz', 'Ben Cruz']);
  assertEquals(findNames('Companions:\nAna Cruz, Ben Cruz'), ['Ana Cruz', 'Ben Cruz']);
});

Deno.test('extract: no cue means no names, and non-name words never become names', () => {
  assertEquals(findNames('We arrive with Ana Cruz tomorrow afternoon'), []);
  assertEquals(findNames('Companions: my wife and kids'), []);
  assertEquals(findNames('1. Check-in at 3pm\n2. Late arrival please'), []);
  assertEquals(findNames('Guests are arriving at 3pm'), []);
  assertEquals(findNames('Companions: Ana'), [], 'one word is not enough to tell two people apart');
});

Deno.test('extract: two or more bullet lines that are all names count without a header', () => {
  assertEquals(findNames('Hi!\n- Ana Cruz\n- Ben Cruz\nThanks'), ['Ana Cruz', 'Ben Cruz']);
  assertEquals(findNames('- Ana Cruz\n- late arrival'), []);
});

Deno.test('extract: capped at six names, deduped, and money in the message never reaches the result', () => {
  const t = 'Companions: Ana One, Ben Two, Cara Three, Dan Four, Eli Five, Fay Six, Gus Seven, Ana One. Total PHP 4,550 / ₱2,800 deposit. My number 0917 123 4567';
  const r = extract(t);
  assertEquals(r.names.length, 6);
  assertEquals(r.phone, '09171234567');
  assert(!JSON.stringify(r).match(/4,?550|2,?800|PHP|₱/));
});

Deno.test('extract: a payment account number is not the guest phone unless a contact cue is beside it', () => {
  assertEquals(findPhone('my gcash is 0917 123 4567'), null);
  assertEquals(findPhone('maya account: 0917 123 4567'), null);
  assertEquals(findPhone('gcash 0917 123 4567, call me on 0918 765 4321'), '09187654321');
  assertEquals(findPhone('my gcash number is 0917 123 4567'), '09171234567', 'a contact cue beside it keeps the number');
  assertEquals(findPhone('you can text me 0917 123 4567'), '09171234567');
});

Deno.test('extract: relation words are not names, parentheticals are dropped, and the booker is not their own companion', () => {
  assertEquals(findNames('Guests are Mara Santos and her sister'), ['Mara Santos']);
  assertEquals(findNames('Companions: Ana Cruz (wife), Ben Cruz'), ['Ana Cruz', 'Ben Cruz']);
  assertEquals(findNames('Companions: Ana Cruz (wife, 30), Kuya Ben'), ['Ana Cruz']);
  assertEquals(findNames('Companions: Lola Rosa, Tito Ben'), []);
  const p = buildPlan({ phone: null, names: ['jonas EXAMPLE', 'Ana Cruz'] }, cand, null);
  assert(p && p.kind === 'chat');
  assertEquals([p.newNames, p.knownNames], [['Ana Cruz'], []]);
});

Deno.test('logRow: the event log row has no text, no subject and exactly the documented keys; an event without text is skipped', () => {
  const ev = { gmail_message_id: 'SYNTH-msg-9', email_date: '2026-10-06T01:00:00Z', guest_first_name: 'Jonas', confirmation_code: 'HMSYNTH001', checkin_date: '2026-10-10', text: 'my number 0917 123 4567', subject: 'Jonas sent you a message' };
  const row = logRow(ev, 'P');
  assertEquals(row, { property_id: 'P', gmail_message_id: 'SYNTH-msg-9', email_type: 'message', email_date: '2026-10-06T01:00:00Z', subject: null,
    raw_payload: { guest_first_name: 'Jonas', confirmation_code: 'HMSYNTH001' } });
  assert(!JSON.stringify(row).includes('0917') && !JSON.stringify(row).includes('sent you'));
  assertEquals(Object.keys(row!.raw_payload).sort(), ['confirmation_code', 'guest_first_name']);
  assertEquals(logRow({ ...ev, text: undefined }, 'P'), null);
  assertEquals(logRow({ ...ev, guest_first_name: undefined, confirmation_code: undefined }, 'P')!.raw_payload, { guest_first_name: null, confirmation_code: null });
});

Deno.test('secret gate: message events need the exact secret; unset, missing or wrong drops them; the old types always pass', () => {
  assert(secretMatches('s3cret-synthetic', 's3cret-synthetic'));
  assert(!secretMatches('s3cret-synthetic', 's3cret-synthetiC'));
  assert(!secretMatches('s3cret', 's3cret-synthetic'), 'a prefix is not a match');
  assert(!secretMatches(null, 's3cret-synthetic'));
  assert(!secretMatches('anything', undefined), 'env var unset: refused');
  assert(!secretMatches('', ''), 'empty is never a secret');
  const evs = [{ email_type: 'booking' }, { email_type: 'message' }, { email_type: 'payout' }, { email_type: 'message' }];
  assertEquals(gateMessages(evs, 'wrong', 's3cret-synthetic'), { events: [evs[0], evs[2]], refused: 2 });
  assertEquals(gateMessages(evs, null, undefined), { events: [evs[0], evs[2]], refused: 2 });
  assertEquals(gateMessages(evs, 's3cret-synthetic', 's3cret-synthetic'), { events: evs, refused: 0 });
  assertEquals(gateMessages([{ email_type: 'message' }], 'wrong', 's3cret-synthetic').events.length, 0, 'only message events and refused: nothing left, the function answers 401');
});

Deno.test('stripQuoted: quote lines, the "wrote:" tail and the signature are cut; the text is capped', () => {
  assertEquals(stripQuoted('Thanks!\n> old\nMy number 09171234567\nOn Tue, Oct 6, 2026 Cascade wrote:\nsecret'), 'Thanks!\nMy number 09171234567');
  assertEquals(stripQuoted('x'.repeat(5000)).length, 2000);
  assertEquals(stripQuoted(null), '');
});

// ---- matching --------------------------------------------------------------------------------------------------------------------------------
const stays: Stay[] = [
  { guest_id: 'g1', guest_name: 'María José Example', confirmation_code: 'HMSYNTH001', checkin_date: '2026-10-10', checkout_date: '2026-10-13' },
  { guest_id: 'g2', guest_name: 'Maria Other', confirmation_code: 'HMSYNTH002', checkin_date: '2026-10-20', checkout_date: '2026-10-22' },
  { guest_id: 'g3', guest_name: 'Juan Dela Cruz', confirmation_code: 'HMSYNTH003', checkin_date: '2026-11-01', checkout_date: '2026-11-04' },
  { guest_id: 'g4', guest_name: 'Juan Santos', confirmation_code: 'HMSYNTH004', checkin_date: '2026-11-01', checkout_date: '2026-11-04' },
];
Deno.test('match: confirmation code wins; the code is case-insensitive; an unknown code is no match', () => {
  assertEquals(matchStay(stays, { confirmation_code: 'hmsynth003' })?.guest_id, 'g3');
  assertEquals(matchStay(stays, { confirmation_code: 'HMNOPE' }), null);
  assertEquals(matchStay(stays, { confirmation_code: 'HMSYNTH003', guest_first_name: 'Someone Else' })?.guest_id, 'g3', 'the code decides, not the name');
});

Deno.test('match: first name folded for case and accents, and the e-mail dates narrow it', () => {
  assertEquals(matchStay(stays, { guest_first_name: 'maria' }), null, 'two Marias (María and Maria) are ambiguous');
  assertEquals(matchStay(stays, { guest_first_name: 'MARÍA', checkin_date: '2026-10-10', checkout_date: '2026-10-13' })?.guest_id, 'g1');
  assertEquals(matchStay(stays, { guest_first_name: 'Maria', checkin_date: '2026-10-20' })?.guest_id, 'g2');
});

Deno.test('match: ambiguous or nameless is no card', () => {
  assertEquals(matchStay(stays, { guest_first_name: 'Juan' }), null);
  assertEquals(matchStay(stays, { guest_first_name: 'Juan', checkin_date: '2026-11-01' }), null);
  assertEquals(matchStay(stays, {}), null);
  assertEquals(matchStay([{ ...stays[0], guest_id: null }], { confirmation_code: 'HMSYNTH001' }), null, 'a stay with no guest record cannot be saved to');
});

// ---- plan ------------------------------------------------------------------------------------------------------------------------------------
Deno.test('plan: the phone on file in any format is not offered again; a different one replaces; known names are left alone', () => {
  assertEquals(buildPlan({ phone: '09171234567', names: [] }, { ...cand, has_contact: true }, '+63 917 123 4567'), null, 'same number, nothing new');
  const p = buildPlan({ phone: '09171234567', names: ['Ana Cruz', 'Jonas Example'] }, { ...cand, has_contact: true }, '0918 000 0000');
  assert(p && p.kind === 'chat');
  assertEquals([p.phone, p.replacesPhone, p.newNames, p.knownNames, p.via], ['09171234567', true, ['Ana Cruz'], [], 'airbnb']);
  assertEquals(buildPlan({ phone: null, names: ['Jonas Example'] }, cand, null), null, 'only a name already on the record');
});

// ---- the handler, against an in-memory database ----------------------------------------------------------------------------------------------
function fakeDb(o: { stays?: any[]; contact?: string | null; companions?: string[]; pending?: any[] } = {}) {
  const pending: any[] = o.pending ?? [];
  const tables: Record<string, any[]> = {
    airbnb_reservations: (o.stays ?? [{ guest_id: GID, guest_name: 'Jonas Example', confirmation_code: 'HMSYNTH001', checkin_date: '2026-10-10', checkout_date: '2026-10-13', status: 'confirmed', property_id: 'P' }]),
    guests: [{ id: GID, name: 'Jonas Example' }],
    guest_profile_details: o.contact === undefined ? [] : [{ guest_id: GID, contact_number: o.contact }],
    guest_companions: (o.companions ?? []).map((name) => ({ guest_id: GID, name })),
    telegram_pending: pending,
  };
  const path = (row: any, col: string) => col.split(/->>|->/).reduce((x: any, k) => x?.[k], row);
  let n = 0;
  const from = (t: string) => {
    const f: Array<(r: any) => boolean> = []; let op = 'select', ins: any = null;
    const run = () => {
      if (op === 'insert') { const row = { id: `0b9f2c1e-7a4d-4e1b-9c3a-5d6e7f8a9b${(++n).toString(16).padStart(2, '0')}`, created_at: new Date().toISOString(), ...ins }; tables[t].push(row); return row; }
      const hit = tables[t].filter((r) => f.every((x) => x(r)));
      if (op === 'delete') for (const r of hit) tables[t].splice(tables[t].indexOf(r), 1);
      return hit;
    };
    const api: any = {
      select: () => api, insert: (r: any) => { op = 'insert'; ins = r; return api; }, delete: () => { op = 'delete'; return api; },
      eq: (c: string, v: unknown) => { f.push((r) => String(path(r, c)) === String(v)); return api; },
      gt: (c: string, v: string) => { f.push((r) => path(r, c) > v); return api; },
      gte: (c: string, v: string) => { f.push((r) => path(r, c) >= v); return api; },
      lte: (c: string, v: string) => { f.push((r) => path(r, c) <= v); return api; },
      limit: () => api,
      maybeSingle: async () => ({ data: (run() as any[])[0] ?? null }),
      single: async () => ({ data: run() }),
      then: (res: any) => Promise.resolve({ data: run(), error: null }).then(res),
    };
    return api;
  };
  return { db: { from }, tables, pending };
}
function deps(f: ReturnType<typeof fakeDb>, over: Partial<MessageDeps> = {}) {
  const posts: Array<{ chatId: number; text: string; rm: any }> = [];
  const d: MessageDeps = { db: f.db, propertyId: 'P', opsChatId: -1003798341977, today: '2026-10-06', esc: (s) => s,
    post: async (chatId, text, rm) => { posts.push({ chatId, text, rm }); return true; }, ...over };
  return { d, posts };
}
const ev = (text: string, over: Record<string, unknown> = {}) => ({ gmail_message_id: 'SYNTH-1', email_date: '2026-10-06T03:00:00Z', guest_first_name: 'Jonas', confirmation_code: 'HMSYNTH001', text, ...over });

Deno.test('handler: one matched message with a phone and a companion posts ONE card to OPS with Save and Cancel; the log holds counts only', async () => {
  const f = fakeDb({ contact: null }); const { d, posts } = deps(f);
  const log = await handleMessage(d, ev('Hi po, my number is 0917 123 4567. Companions: Ana Cruz'));
  assertEquals(log, { guest_first_name: 'Jonas', confirmation_code: 'HMSYNTH001', matched: true, has_phone: true, names_count: 1, carded: true });
  assertEquals(posts.length, 1);
  assertEquals(posts[0].chatId, -1003798341977);
  assert(posts[0].text.includes('Phone 09171234567') && posts[0].text.includes('Add as companions: Ana Cruz'));
  assert(posts[0].text.includes('From the Airbnb message of 2026-10-06.') && posts[0].text.includes('Do: tap Save if this is right.'));
  // the stored card is what the existing /guest Save path accepts
  assertEquals(f.pending.length, 1);
  const row = f.pending[0];
  assertEquals([row.kind, row.chat_id, row.payload.from_id, row.payload.from_name, row.payload.file_id], ['guest_save', -1003798341977, null, 'Airbnb e-mail', '']);
  assertEquals([row.payload.plan.kind, row.payload.plan.guestId, row.payload.plan.phone, row.payload.plan.newNames, row.payload.plan.via], ['chat', GID, '09171234567', ['Ana Cruz'], 'airbnb']);
  const hours = (Date.parse(row.expires_at) - Date.now()) / 3_600_000;
  assert(hours > 71 && hours <= 72, `expires in ${hours} h`);
  const save = parseGuestTap(posts[0].rm.inline_keyboard[0][0].callback_data), cancel = parseGuestTap(posts[0].rm.inline_keyboard[0][1].callback_data);
  assertEquals([save?.act, save?.pid, cancel?.act, cancel?.pid], ['save', row.id, 'cancel', row.id]);
  assert(!JSON.stringify(log).includes('0917') && !JSON.stringify(row).includes('Hi po'), 'no message text anywhere');
});

Deno.test('handler: matched by name and dates when the e-mail carries no confirmation code', async () => {
  const f = fakeDb({ contact: null }); const { d, posts } = deps(f);
  const log = await handleMessage(d, ev('Companions: Ana Cruz', { confirmation_code: undefined, checkin_date: '2026-10-10', checkout_date: '2026-10-13' }));
  assertEquals([log.matched, log.carded, posts.length], [true, true, 1]);
});

Deno.test('handler: nothing new, no match, an ambiguous match, no ops chat or nothing parsed - no card, no pending row', async () => {
  const cases: Array<[string, ReturnType<typeof fakeDb>, Record<string, unknown>, Partial<MessageDeps>, boolean]> = [
    ['same phone already on file', fakeDb({ contact: '+63 917 123 4567' }), {}, {}, true],
    ['nothing parsed', fakeDb({ contact: null }), { text: 'See you on the 10th, thank you!' }, {}, false],
    ['unknown code', fakeDb({ contact: null }), { confirmation_code: 'HMNOPE' }, {}, false],
    ['no ops chat', fakeDb({ contact: null }), {}, { opsChatId: null }, true],
  ];
  for (const [why, f, over, dover, matched] of cases) {
    const { d, posts } = deps(f, dover);
    const log = await handleMessage(d, ev((over.text as string) ?? 'My number is 0917 123 4567', over));
    assertEquals([posts.length, f.pending.length, log.carded, log.matched], [0, 0, false, matched], why);
  }
  const twins = fakeDb({ contact: null, stays: [
    { guest_id: 'a', guest_name: 'Jonas One', confirmation_code: 'HMSYNTH101', checkin_date: '2026-10-10', checkout_date: '2026-10-12', status: 'confirmed', property_id: 'P' },
    { guest_id: 'b', guest_name: 'Jonas Two', confirmation_code: 'HMSYNTH102', checkin_date: '2026-10-11', checkout_date: '2026-10-13', status: 'confirmed', property_id: 'P' }] });
  const t = deps(twins);
  const log = await handleMessage(t.d, ev('My number is 0917 123 4567', { confirmation_code: undefined }));
  assertEquals([log.matched, t.posts.length, twins.pending.length], [false, 0, 0], 'two Jonases in the window is ambiguous');
});

Deno.test('handler: a cancelled stay or one outside the window is never matched', async () => {
  const f = fakeDb({ contact: null, stays: [
    { guest_id: GID, guest_name: 'Jonas Example', confirmation_code: 'HMSYNTH001', checkin_date: '2026-10-10', checkout_date: '2026-10-13', status: 'cancelled', property_id: 'P' },
    { guest_id: 'z', guest_name: 'Jonas Far', confirmation_code: 'HMSYNTH009', checkin_date: '2027-03-01', checkout_date: '2027-03-03', status: 'confirmed', property_id: 'P' }] });
  const { d, posts } = deps(f);
  const log = await handleMessage(d, ev('My number is 0917 123 4567', { confirmation_code: undefined }));
  assertEquals([log.matched, posts.length], [false, 0]);
});

Deno.test('handler: one open card per guest - a second message while the first is unanswered posts nothing', async () => {
  const f = fakeDb({ contact: null }); const { d, posts } = deps(f);
  await handleMessage(d, ev('My number is 0917 123 4567'));
  const again = await handleMessage(d, ev('Companions: Ana Cruz', { gmail_message_id: 'SYNTH-2' }));
  assertEquals([posts.length, f.pending.length, again.matched, again.carded], [1, 1, true, false]);
});

Deno.test('handler: when Telegram refuses the card the pending row is removed so the next message can try again', async () => {
  const f = fakeDb({ contact: null }); const { d } = deps(f, { post: async () => false });
  const log = await handleMessage(d, ev('My number is 0917 123 4567'));
  assertEquals([log.carded, f.pending.length], [false, 0]);
});

Deno.test('handler: the companion cap on the record and an existing companion are respected (known names are not re-added)', async () => {
  const f = fakeDb({ contact: '09170000000', companions: ['Ana Cruz'] }); const { d, posts } = deps(f);
  const log = await handleMessage(d, ev('Companions: Ana Cruz, Ben Cruz'));
  assertEquals(log.carded, true);
  assert(posts[0].text.includes('Add as companions: Ben Cruz') && posts[0].text.includes('Already on the record, left as they are: Ana Cruz'));
  assertEquals(f.pending[0].payload.plan.newNames, ['Ben Cruz']);
});

// ---- D-306: nothing money-shaped reaches OPS --------------------------------------------------------------------------------------------------
Deno.test('D-306: money in the guest message, the guest name or a companion name never appears in the OPS card, and the phone survives the masker', async () => {
  const text = 'Hi! Total PHP 4,550, deposit ₱2,800 balance P1,000 paid via GCash 0956 011 5744. My number 0917 123 4567. Companions: Ana Cruz, Ben Cruz';
  const f = fakeDb({ contact: null }); const { d, posts } = deps(f);
  const log = await handleMessage(d, ev(text));
  assertEquals(log.carded, true);
  const card = posts[0].text;
  for (const bad of ['4,550', '4550', '2,800', '2800', '1,000', 'PHP', '₱', '0956', '011 5744', 'GCash', 'deposit', 'balance']) assert(!card.includes(bad), `card must not contain ${bad}`);
  assert(card.includes('09171234567'), 'the guest phone is kept');
  // belt and braces: even a plan whose names carried a money-shaped string is masked line by line
  const dirty = cardText({ kind: 'chat', guestId: GID, guestName: 'Jonas ₱2,800 Example', phone: '09171234567', replacesPhone: false, newNames: ['Ana PHP 4,550 Cruz'], knownNames: [], via: 'airbnb' }, '2026-10-06T03:00:00Z', (s) => s);
  assert(!dirty.includes('2,800') && !dirty.includes('4,550') && dirty.includes('[amount hidden]'), dirty);
});

Deno.test('the log payload for a message never has a text field, even when the handler is given one', async () => {
  const f = fakeDb({ contact: null }); const { d } = deps(f);
  const log = await handleMessage(d, ev('My number is 0917 123 4567 and a secret sentence'));
  assertEquals(Object.keys(log).sort(), ['carded', 'confirmation_code', 'guest_first_name', 'has_phone', 'matched', 'names_count']);
});
