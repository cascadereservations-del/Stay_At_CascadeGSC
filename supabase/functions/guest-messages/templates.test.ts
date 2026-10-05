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
const KEYS: Key[] = ['confirmation', 'pre_arrival', 'door_code', 'mid_stay', 'checkout_reminder', 'after_departure'];
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
  assertEquals(atCheckinLine(ben), '₱1,780 balance and the ₱1,000 refundable security deposit');
  assertEquals(atCheckinLine(full), 'the ₱1,000 refundable security deposit only');
  const m1 = render('confirmation', ben, 'messenger');
  assert(m1.includes('• Due a day before check-in: ₱1,780 balance and the ₱1,000 refundable security deposit'));
  assert(!m1.includes('At check-in:'));
  const m2 = render('pre_arrival', ben, 'email');
  assert(m2.includes('are due at least a day before check-in, by Mon, Oct 19.'));
  assert(m2.includes('share the receipt by replying to this e-mail.'));
  assert(render('pre_arrival', full, 'messenger').includes('The ₱1,000 refundable security deposit is due'));
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
    assert(card.includes('✅ ID on file') && card.includes('not recorded yet'));
    assert(card.endsWith(render('door_code', f, 'card_only')), 'the 📨 ⤵ block is the whole message, last');
    assertEquals(card.split('📨 ⤵').length - 1, 1);
    const scan = card.replace(f.onground_phone ?? '\u0000', '');
    assert(!/(?<![\d.,/])\d{4,6}(?![\d.,])/.test(scan), 'a 4-6 digit run: ' + (scan.match(/(?<![\d.,/])\d{4,6}(?![\d.,])/) ?? [])[0]);
  }
  assert(doorCodeCard('DIR-1', ben).includes('⚠️ Balance ₱1,780 + ₱1,000 deposit: not recorded yet.'));
  assert(doorCodeCard('DIR-1', full).includes('⚠️ ₱1,000 deposit: not recorded yet.'));
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
    assert(c.text.includes('₱1,000') && (key === 'confirmation' || c.text.includes('0956 011 5744')), `${key}: the guest text still holds the payment details`);
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
