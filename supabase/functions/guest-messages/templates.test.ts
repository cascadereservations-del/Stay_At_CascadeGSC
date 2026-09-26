// deno test --no-check --allow-env guest-messages/
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { lintReply } from '../messenger-concierge/voice.ts';
import { atCheckinLine, channelFor, chunks, day, render, type Channel, type Fields, type Key } from './templates.ts';

// The word rules only: the chat-length rules (too_long, too_dense, two_asks) do not apply to a scheduled host message (design section 6).
const WORD = ['form_speak', 'robot_word', 'shouting', 'command_tone', 'exclaim', 'boilerplate'];
const words = (t: string) => lintReply(t).filter((v) => WORD.includes(v));

const ben: Fields = { guest_name: 'Ben Cruz', checkin_date: '2026-10-20', checkout_date: '2026-10-22', pax: 2, total_amount: 3560, deposit_amount: 1780 };
const full: Fields = { ...ben, deposit_amount: 3560 };
const long: Fields = { ...ben, guest_name: 'Maximiliano-Bartholomew Esperanza-Villanueva de los Santos', total_amount: 99999, deposit_amount: 12345, pax: 3,
  onground_name: 'Kristine Alexandra Montemayor', onground_phone: '0917 123 4567' };
const KEYS: Key[] = ['confirmation', 'pre_arrival'];
const CH: Channel[] = ['messenger', 'email', 'card_only'];

Deno.test('every message passes the word rules, whole and per paragraph, on every channel', () => {
  for (const k of KEYS) for (const c of CH) for (const f of [ben, full, long]) {
    const t = render(k, f, c);
    assertEquals(words(t), [], `${k}/${c}`);
    for (const p of t.split(/\n\s*\n/)) assertEquals(words(p), [], `${k}/${c}: ${p.slice(0, 60)}`);
  }
});

Deno.test('no placeholder is left', () => {
  for (const k of KEYS) for (const c of CH) for (const f of [ben, long]) assert(!/\{\{|\}\}|undefined|NaN|null/.test(render(k, f, c)), `${k}/${c}`);
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
