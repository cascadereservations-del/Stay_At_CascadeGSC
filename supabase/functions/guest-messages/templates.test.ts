// deno test --no-check --allow-env guest-messages/
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { lintReply, toneRules } from '../messenger-concierge/voice.ts';
import { SUBJECT, atCheckinLine, channelFor, chunks, day, doorCodeCard, render, type Channel, type Fields, type Key } from './templates.ts';

// The word rules only: the chat-length rules (too_long, too_dense, two_asks) do not apply to a scheduled host message (design section 6).
const WORD = ['form_speak', 'robot_word', 'shouting', 'command_tone', 'exclaim', 'boilerplate'];
const words = (t: string) => lintReply(t).filter((v) => WORD.includes(v));

const ben: Fields = { guest_name: 'Ben Cruz', checkin_date: '2026-10-20', checkout_date: '2026-10-22', pax: 2, total_amount: 3560, deposit_amount: 1780 };
const full: Fields = { ...ben, deposit_amount: 3560 };
const long: Fields = { ...ben, guest_name: 'Maximiliano-Bartholomew Esperanza-Villanueva de los Santos', total_amount: 99999, deposit_amount: 12345, pax: 3,
  onground_name: 'Kristine Alexandra Montemayor', onground_phone: '0917 123 4567' };
const KEYS: Key[] = ['confirmation', 'pre_arrival', 'door_code', 'mid_stay', 'checkout_reminder', 'after_departure', 'declined'];
const CH: Channel[] = ['messenger', 'email', 'card_only'];

Deno.test('every message passes the word rules, whole and per paragraph, on every channel', () => {
  for (const k of KEYS) for (const c of CH) for (const f of [ben, full, long]) {
    const t = render(k, f, c);
    assertEquals(words(t), [], `${k}/${c}`);
    // Session 58, the persona gate: the concierge's tone rules too (no urgency, no "!", two "po" at most). The one-🌿-at-
    // the-close rule is a chat rule: these letters (section 7 verbatim) carry the leaf at the salutation and the sign-off.
    assertEquals(toneRules(t.replace('{{door_pin}}', '')).filter((v) => v !== 'leaf_not_at_close'), [], `${k}/${c} tone`);
    for (const p of t.split(/\n\s*\n/)) assertEquals(words(p), [], `${k}/${c}: ${p.slice(0, 60)}`);
  }
});

Deno.test('no placeholder is left', () => {
  // {{door_pin}} is the one slot left on purpose: the host types the PIN (message 3 only, exactly once).
  for (const k of KEYS) for (const c of CH) for (const f of [ben, long]) assert(!/\{\{|\}\}|undefined|NaN|null/.test(render(k, f, c).replace('{{door_pin}}', '')), `${k}/${c}`);
  for (const k of KEYS) assertEquals(render(k, ben, 'card_only').split('{{door_pin}}').length - 1, k === 'door_code' ? 1 : 0, k);
});

Deno.test('message 1 fits one Messenger message with a long name and 5-digit amounts', () => {
  for (const c of CH) { const n = render('confirmation', long, c).length; assert(n <= 2000, `${c}: ${n}`); }
});

Deno.test('message 2 is split at paragraphs when it passes 2,000 characters, and nothing is lost', () => {
  const t = render('pre_arrival', long, 'messenger');
  const parts = chunks(t);
  assert(parts.every((p) => p.length <= 2000));
  assertEquals(parts.join('\n\n'), t);
});

Deno.test('the payment lines follow D-251 / D-257', () => {
  // s138 (D-428..D-430): the stay is paid in full to confirm, so no balance line exists; only the P800 deposit is due.
  // (`ben` holds a 50% amount due: a booking made under the old rule, which rule 8 keeps; the new-rule case is `full`.)
  assertEquals(atCheckinLine(full), 'the ₱800 refundable security deposit only');
  const m1 = render('confirmation', full, 'messenger');
  assert(m1.includes('• Due a day before check-in: the ₱800 refundable security deposit only'));
  assert(!/balance|1,000/.test(m1));
  assert(!m1.includes('At check-in:'));
  const m2 = render('pre_arrival', full, 'email');
  assert(m2.includes('is due at least a day before check-in, by Mon, Oct 19.'));
  assert(m2.includes('share the receipt by replying to this e-mail.'));
  assert(render('pre_arrival', full, 'messenger').includes('The ₱800 refundable security deposit is due'));
  assert(m2.includes('Your check-in PIN follows once the deposit and your IDs are in.') && !/balance/i.test(m2));
  assertEquals(atCheckinLine(ben), 'the ₱1,780 balance of your stay and the ₱800 refundable security deposit'); // rule 8
});

Deno.test('dates, first name, reply channel, and the on-ground paragraph only when both parts are set', () => {
  assertEquals(day('2026-10-20'), 'Tue, Oct 20');
  assertEquals(day('2026-11-01', -1), 'Sat, Oct 31');
  const m1 = render('confirmation', ben, 'messenger');
  assert(m1.startsWith('Welcome home to Cascade Hideaway, Ben 🌿'));
  assert(m1.includes('• Check-in: Tue, Oct 20 from 2:00 PM') && m1.includes('• Check-out: Thu, Oct 22 by 12:00 noon'));
  assert(m1.includes('You may send these details here in the chat whenever convenient.'));
  assert(render('confirmation', ben, 'email').includes('You may send these details by replying to this e-mail whenever convenient.'));
  assert(!render('pre_arrival', ben, 'messenger').includes('on-ground'));
  assert(!render('pre_arrival', { ...ben, onground_name: 'Kris' }, 'messenger').includes('on-ground'));
  assert(render('pre_arrival', long, 'messenger').includes('on-ground support, Kristine Alexandra Montemayor 0917 123 4567, who'));
});

Deno.test('the channel rule: 23 h window, HUMAN_AGENT only for the tapped confirmation inside 7 days, else e-mail, else card', () => {
  const now = Date.parse('2026-10-01T00:00:00Z'), h = (n: number) => now - n * 3_600_000;
  assertEquals(channelFor('pre_arrival', h(22), true, true, false, now), { channel: 'messenger', humanAgent: false });
  assertEquals(channelFor('pre_arrival', h(24), true, true, false, now), { channel: 'email', humanAgent: false });
  assertEquals(channelFor('pre_arrival', h(24), true, true, true, now), { channel: 'email', humanAgent: false }); // never a tag on a scheduled message
  assertEquals(channelFor('confirmation', h(48), true, true, false, now), { channel: 'email', humanAgent: false }); // the hourly run is not a person
  assertEquals(channelFor('confirmation', h(48), true, true, true, now), { channel: 'messenger', humanAgent: true });
  assertEquals(channelFor('confirmation', h(170), true, true, true, now), { channel: 'email', humanAgent: false });
  assertEquals(channelFor('confirmation', h(1), false, false, true, now), { channel: 'card_only', humanAgent: false });
});

// Session 56: messages 3-6.
const reviews: Fields = { ...ben, review_facebook_url: 'https://facebook.com/x/reviews', review_google_url: 'https://g.page/r/x/review', review_airbnb_url: 'https://airbnb.com/h/cascadesgsc' };
Deno.test('message 5.2: a blank review link drops its bullet, and none left drops the list', () => {
  const all = render('after_departure', reviews, 'email');
  assertEquals((all.match(/^• /gm) ?? []).length, 3);
  const two = render('after_departure', { ...reviews, review_facebook_url: '' }, 'email');
  assert(!two.includes('Facebook:') && two.includes('• Google: https://g.page/r/x/review') && two.includes('Wherever is easiest for you:'));
  const none = render('after_departure', ben, 'email');
  assert(!none.includes('Wherever is easiest') && !none.includes('• '));
  assert(!/\n{3,}/.test(none) && !/\n{3,}/.test(all), 'no blank gap where the list was');
  assert(none.includes('We look forward to welcoming you back.'));
});

Deno.test('message 3 is a Finance card: the PIN slot stays literal, no digit run could be a PIN, the text runs to the end', () => {
  for (const f of [ben, full, long]) {
    const card = doorCodeCard('DIR-4A19F743', f);
    assert(card.startsWith('🔑 DOOR CODE READY TO SEND · DIR-4A19F743'));
    assert(card.includes('✅ ID on file') && card.includes('confirm received before sending the PIN'));
    assert(card.endsWith(render('door_code', f, 'card_only')), 'the 📨 ⤵ block is the whole message, last');
    assertEquals(card.split('📨 ⤵').length - 1, 1);
    const scan = card.replace(f.onground_phone ?? '\u0000', '');
    assert(!/(?<![\d.,/])\d{4,6}(?![\d.,])/.test(scan), 'a 4-6 digit run: ' + (scan.match(/(?<![\d.,/])\d{4,6}(?![\d.,])/) ?? [])[0]);
  }
  // s138 decision E: no stored deposit receipt exists, so the card asks for a manual check and states the policy line.
  for (const f of [ben, full]) {
    const c = doorCodeCard('DIR-1', f);
    assert(c.includes('⚠️ ₱800 deposit: confirm received before sending the PIN. Policy: the PIN follows full payment, IDs and the ₱800 deposit.'));
    assert(!/1,000|unless you are collecting/i.test(c));
    assertEquals(/balance/i.test(c), f === ben); // rule 8: only the old-rule booking shows a balance
  }
  assert(!render('door_code', ben, 'card_only').includes('on-ground') && render('door_code', long, 'card_only').includes('📞 Kristine Alexandra Montemayor 0917 123 4567'));
  assertEquals(SUBJECT.door_code, ''); // never e-mailed
});

Deno.test('messages 4, 5.1, 5.2 open with the first name and carry the relay subjects', () => {
  assert(render('mid_stay', ben, 'messenger').startsWith('Good afternoon, Ben 🌿'));
  assert(render('mid_stay', ben, 'messenger').includes('a free mid-stay refresh tomorrow'));
  assert(render('checkout_reminder', ben, 'email').startsWith('Good morning, Ben 🌿') && render('checkout_reminder', ben, 'email').includes('12:00 noon') && render('checkout_reminder', ben, 'email').includes('leave the key card with the remotes'));
  assert(render('after_departure', ben, 'email').startsWith('Hi Ben,'));
  assertEquals([SUBJECT.mid_stay, SUBJECT.checkout_reminder, SUBJECT.after_departure], ["A mid-stay refresh, if you'd like one", 'Your check-out today', 'Thank you for staying with us']);
});
// The 5.2 hold rule lives in SQL (guest_message_hold_v1) and is pinned by pgTAP stay-site tests/database/guest_message_reads.sql.

// Lloyd 2026-10-02: OPS never shows guest money or the payment number; Finance and the guest keep the whole text.
import { messageCards } from './templates.ts';
const cardFor = (key: Key, f: Fields, status = 'sent', hold = false) => {
  const text = render(key, f, 'email');
  return { text, ...messageCards({ key, ref: 'DIR-AB12CD34', name: f.guest_name, checkin: f.checkin_date, checkout: f.checkout_date, outcome: '✅ sent', status, hold, phone: '0917 000 1111', email: 'g@x.com', psid: '99', text }) };
};
const MONEY_LEAK = /₱|\bPHP\b|0956|\bGCash to\b.*\d|\d[\d,]{3,}\b.*balance/i;

Deno.test('OPS card for the money messages hides every amount and the GCash number; Finance carries the full text; the sent text is whole', () => {
  for (const key of ['confirmation', 'pre_arrival'] as Key[]) for (const f of [ben, full, long]) for (const status of ['sent', 'skipped', 'failed']) {
    const c = cardFor(key, f, status);
    // the text a guest is sent: the template output, untouched by the card builder
    assertEquals(c.text, render(key, f, 'email'));
    assert(c.text.includes('₱800') && (key === 'confirmation' || c.text.includes('0956 011 5744')), `${key}: the guest text still holds the payment details`);
    assert(c.finance !== null, `${key}/${status}: Finance copy`);
    assert(c.finance!.endsWith(`📨 ⤵\n${c.text}`), 'Finance card ends with the exact sent text');
    assert(!MONEY_LEAK.test(c.ops), `${key}/${status}: OPS leaked\n${c.ops}`);
    assert(!c.ops.includes('📨'), 'no Show as text button on a masked preview');
    assert(c.ops.includes('payment details hidden'));
    if (status !== 'sent') assert(c.ops.includes('Finance group'), 'a hand-send is pointed at Finance');
  }
});

Deno.test('messages with no money keep one unchanged OPS card and send nothing to Finance', () => {
  for (const key of ['mid_stay', 'checkout_reminder', 'after_departure'] as Key[]) {
    const c = cardFor(key, ben, 'skipped');
    assertEquals(c.finance, null);
    assert(c.ops.endsWith(`📨 ⤵\n${c.text}`));
    assert(c.ops.includes('Do: send it by hand (Show as text, then long-press to copy).'));
  }
});

// D-418 (confirm flow): the decline message, golden strings of PLAN-confirm-flow R1.6. The same fixture is copied into the Staff test.
import { declineReason } from './templates.ts';
import { SITE_URL } from '../_shared/cascade-core/facts.ts';
const dec: Fields = { guest_name: 'Ben Cruz', checkin_date: '2026-12-04', checkout_date: '2026-12-07', pax: 2, total_amount: 3560, deposit_amount: 1780 };
const WHEN = 'Fri, Dec 4 to Mon, Dec 7';
const OPEN = 'Hello Ben,\n\n', CLOSE = '\n\nWarm regards,\nCascade Hideaway\nHotel Comfort. Home Warmth. 🌿';
const refundLine = (here: string) => `If you already sent a payment, please reply ${here} with the GCash name and number it came from, and we will return it in full.`;
const againLine = (here: string) => `We would still love to host you. Please reply ${here} with other dates that suit you, or see what is open at ${SITE_URL}, and we will gladly check them for you.`;
const golden = (code: string, receipt: boolean, here: string): string => {
  const p: string[] = code === 'dates' ? [`Thank you for choosing Cascade Hideaway. We are sorry: ${WHEN} are no longer available, so we could not confirm this request.`, ...(receipt ? [refundLine(here)] : []), againLine(here)]
    : code === 'payment' && !receipt ? [`Thank you for choosing Cascade Hideaway. We held ${WHEN} for you, but the payment did not reach us in time, so the hold has ended and this request is closed.`,
        `Still planning to come? Please reply ${here} and, if the dates are still open, we will gladly hold them for you again. You can also check dates at ${SITE_URL}.`]
    : code === 'payment' ? [`Thank you for choosing Cascade Hideaway. We could not find the payment for ${WHEN} in our account, so we could not confirm this request.`,
        `If the payment did leave your account, please reply ${here} with the GCash name and number it came from. We will trace it and return it in full.`,
        'Once that is sorted, we would be glad to hold the dates for you again if they are still open.']
    : code === 'guest_cancel' ? [`As you asked, we have cancelled your request for ${WHEN}. Nothing more is needed from you.`, ...(receipt ? [refundLine(here)] : []), `You are welcome any time. When new dates come up, reply ${here} or visit ${SITE_URL}.`]
    : [`Thank you for choosing Cascade Hideaway. We are sorry, we could not confirm your request for ${WHEN}.`, ...(receipt ? [refundLine(here)] : []), againLine(here)];
  return OPEN + p.join('\n\n') + CLOSE;
};

Deno.test('declined: the golden strings, each reason, e-mail and Messenger, with and without a receipt', () => {
  for (const code of ['dates', 'payment', 'guest_cancel', 'other']) for (const receipt of [false, true]) {
    assertEquals(render('declined', { ...dec, reason_code: code, receipt_sent: receipt }, 'email'), golden(code, receipt, 'to this e-mail'), `${code}/email/${receipt}`);
    assertEquals(render('declined', { ...dec, reason_code: code, receipt_sent: receipt }, 'messenger'), golden(code, receipt, 'here in the chat'), `${code}/messenger/${receipt}`);
  }
  assertEquals(SUBJECT.declined, 'About your request at Cascade Hideaway');
});

Deno.test('declined: a null, unknown or duplicate code reads as other; the refund paragraph only with a receipt; no staff note, no money', () => {
  for (const code of [undefined, 'zzz', 'duplicate', '']) assertEquals(render('declined', { ...dec, reason_code: code }, 'email'), golden('other', false, 'to this e-mail'));
  assertEquals(declineReason('duplicate'), 'other');
  for (const code of ['dates', 'payment', 'guest_cancel', 'other']) {
    assert(!render('declined', { ...dec, reason_code: code, receipt_sent: false }, 'email').includes('GCash') || code === 'payment' && false);
    assert(render('declined', { ...dec, reason_code: code, receipt_sent: true }, 'email').includes('GCash name and number'));
  }
  const t = render('declined', { ...dec, reason_code: 'dates', receipt_sent: true, onground_name: 'Kris', onground_phone: '0917 123 4567' } as Fields, 'email');
  assert(!/₱|0956|\{|\}|undefined|null|NaN/.test(t), t);
  assert(t.includes(SITE_URL), 'the booking page link is the facts constant');
});

Deno.test('declined: passes the word rules and the tone rules, whole and per paragraph, on every channel', () => {
  for (const code of ['dates', 'payment', 'guest_cancel', 'other']) for (const receipt of [false, true]) for (const c of CH) {
    const t = render('declined', { ...dec, reason_code: code, receipt_sent: receipt }, c);
    assertEquals(words(t), [], `${code}/${c}/${receipt}`);
    assertEquals(toneRules(t).filter((v) => v !== 'leaf_not_at_close'), [], `${code}/${c}/${receipt} tone`);
    for (const p of t.split(/\n\s*\n/)) assertEquals(words(p), [], p.slice(0, 60));
    assert(t.length <= 2000 && chunks(t).length === 1, 'fits one Messenger message');
    assert(!t.includes('!'));
  }
});

Deno.test('declined: the channel rule treats a tapped decline like the tapped confirmation (HUMAN_AGENT inside 7 days), never a scheduled one', () => {
  const now = Date.parse('2026-12-01T00:00:00Z'), h = (n: number) => now - n * 3_600_000;
  assertEquals(channelFor('declined', h(48), true, true, true, now), { channel: 'messenger', humanAgent: true });
  assertEquals(channelFor('declined', h(48), true, true, false, now), { channel: 'email', humanAgent: false });
  assertEquals(channelFor('declined', h(170), true, true, true, now), { channel: 'email', humanAgent: false });
  assertEquals(channelFor('declined', h(2), true, true, true, now), { channel: 'messenger', humanAgent: false });
  assertEquals(channelFor('declined', h(2), false, false, true, now), { channel: 'card_only', humanAgent: false });
});

Deno.test('declined: the OPS card carries the text on a Show as text block and nothing goes to Finance', () => {
  const text = render('declined', { ...dec, reason_code: 'payment', receipt_sent: true }, 'email');
  const c = messageCards({ key: 'declined', ref: 'DIR-AB12CD34', name: 'Ben Cruz', checkin: dec.checkin_date, checkout: dec.checkout_date, outcome: '✅ e-mailed', status: 'sent', hold: false, text });
  assertEquals(c.finance, null);
  assert(c.ops.endsWith(`📨 ⤵\n${text}`) && c.ops.includes('Decline message for Ben Cruz'));
});

// R1.6: one golden fixture shared with Cascade-Staff (tests/fixtures/guest-decline-golden.json); both repos assert the same strings.
import goldenFixture from './guest-decline-golden.json' with { type: 'json' };
Deno.test('declined: matches the shared golden fixture (Staff copy) word for word', () => {
  assertEquals(SUBJECT.declined, goldenFixture.subject);
  assertEquals(SITE_URL, goldenFixture.site);
  for (const c of goldenFixture.cases) {
    const f: Fields = { guest_name: goldenFixture.guest_name, checkin_date: goldenFixture.checkin_date, checkout_date: goldenFixture.checkout_date, pax: 2, total_amount: 3560, deposit_amount: 1780, reason_code: c.reason_code, receipt_sent: c.receipt_sent };
    assertEquals(render('declined', f, c.channel as Channel), c.text, `${c.reason_code}/${c.channel}/${c.receipt_sent}`);
  }
});

// D-418 follow-up: a declined request ends the Messenger flow (index.ts has no fake-db harness, so this pins the wiring by source).
Deno.test('index.ts: a declined message ends the flow via setFlowStep(cancelled), after the log update', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  const logAt = src.indexOf("update({ channel, status"), flowAt = src.indexOf("key === 'declined' && t) await setFlowStep(db, t, d.booking_id, 'cancelled')");
  assert(logAt > 0 && flowAt > logAt, 'decline flow step must be written after the send and log update');
});

// ML-71: every flow write in index.ts is bound to the booking being messaged, and a duplicate decline also ends the flow.
Deno.test('index.ts: flow writes go through setFlowStep with the booking id; no raw concierge_threads update remains', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(src.includes("await setFlowStep(db, t, d.booking_id, 'confirmed')"), 'confirmation write must be booking-bound');
  assert(!src.includes("from('concierge_threads').update"), 'no unguarded thread update');
  const dupAt = src.indexOf("body.reason_code === 'duplicate'"), endAt = src.indexOf("no_message_for_duplicate");
  const blk = src.slice(dupAt, endAt);
  assert(dupAt > 0 && blk.includes("setFlowStep(db, dt, d.booking_id, 'cancelled')") && blk.includes('!dry'), 'duplicate decline ends the flow for that booking, not on dry runs');
});

// ---- s138 fix round 2 (rule 8, R2-1): a booking made under the old rule still owes its balance ----
import { doorCodeCard as doorCard2 } from './templates.ts';
const legacy50: Fields = { guest_name: 'Ben Cruz', checkin_date: '2026-12-10', checkout_date: '2026-12-12', pax: 2, total_amount: 3382, deposit_amount: 1691 };
const newRule: Fields = { ...legacy50, deposit_amount: 3382 };
const longRow: Fields = { ...legacy50, checkout_date: '2027-01-09', total_amount: 40050, deposit_amount: 37380 }; // 30 nights, first 28 due

Deno.test('R2-1: a legacy 50% booking states the balance and its due time in message 1, message 2 and the door-code card', () => {
  const m1 = render('confirmation', legacy50, 'messenger'), m2 = render('pre_arrival', legacy50, 'email'), card = doorCard2('DIR-1', legacy50);
  assert(m1.includes('₱1,691 balance of your stay'), m1);
  assert(m2.includes('₱1,691 balance') && m2.includes('₱2,491 in all') && m2.includes('by Wed, Dec 9'), m2);
  assert(card.includes('Balance ₱1,691 not recorded yet'), card);
  for (const t of [m1, m2]) { assertEquals(words(t), []); assert(!t.includes('covers the whole stay')); }
});

Deno.test('R2-1: a new-rule booking renders as before: no balance in message 1, message 2 or the door-code card', () => {
  for (const t of [render('confirmation', newRule, 'messenger'), render('pre_arrival', newRule, 'messenger'), doorCard2('DIR-1', newRule)]) assert(!/balance/i.test(t), t);
  assert(render('confirmation', newRule, 'messenger').includes('Due a day before check-in: the ₱800 refundable security deposit only'));
});

Deno.test('R2-3: a 28+ night row (first 28 nights due, total larger) is not read as a legacy booking', () => {
  for (const t of [render('confirmation', longRow, 'messenger'), render('pre_arrival', longRow, 'messenger'), doorCard2('DIR-1', longRow)]) assert(!/balance/i.test(t), t);
});
