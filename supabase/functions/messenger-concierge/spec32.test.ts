// deno test --no-check -A messenger-concierge/spec32.test.ts
// SPEC-32 s1, s3, s4, s5 (REVIEW-bot-2026-09-26 F9, F11, F12, F14; D-249, D-251, D-252).
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { FACTS, MAYA_FACT } from '../_shared/cascade-core/facts.ts';
import { isCold, withIntro } from './voice.ts';

(Deno as unknown as { serve: unknown }).serve = () => ({ finished: Promise.resolve(), shutdown: () => Promise.resolve() });
const { draftOrPlain } = await import('./index.ts');

Deno.test('SPEC-32 s1: FACTS follow the site - refresh from 5 nights, balance and deposit a day before, Maya scans the QR', () => {
  assertEquals(FACTS.includes('on or before check-in'), false);                                  // D-251
  assertEquals(FACTS.includes('Full payment and the PHP 1,000 deposit at least a day before check-in'), true);
  assertEquals(FACTS.includes('Stays of 5+ nights: complimentary mid-stay room refresh'), true);  // D-249
  assertEquals(/7\+ nights|from 7\)/.test(FACTS), false);
  assertEquals(FACTS.includes(MAYA_FACT), true);                                                  // D-252
  assertEquals(FACTS.includes('sent in this chat at the fee step'), true);                        // F14: "shared once confirmed" was wrong
});

Deno.test('SPEC-32 s3: the Cassy sentence is never placed after a link', () => {
  const url = 'https://tinyurl.com/Stay-at-Cascade';
  // Probe D-T1 (2026-09-26): the model wrote the intro itself, as its last paragraph under the link.
  const dt1 = `Hi Ben, thank you for reaching out to Cascade Hideaway. You may pay through GCash with the QR we send.\n\nOnce you have your dates in mind, we can arrange the booking right here in the chat, or on our site:\n\n👉 ${url}\n\nI'm Cassy, the home's digital concierge, here with Marifel and our team. We'll be glad to help you plan your visit. 🌿`;
  const out = withIntro(dt1, 'en');
  assertEquals(out.indexOf('Cassy') < out.indexOf(url), true);
  assertEquals((out.match(/Cassy/g) ?? []).length, 1);
  assertEquals(out.includes("We'll be glad to help you plan your visit."), true);
  // No sentence end in the first line, link in paragraph 2: the intro is paragraph 2, before the link.
  const bare = `Hi Ben\n\nFor rates and live dates, our site has everything:\n\n👉 ${url}`;
  const b = withIntro(bare, 'en');
  assertEquals(b.startsWith('Hi Ben\n\nI\'m Cassy'), true);
  assertEquals(b.indexOf('Cassy') < b.indexOf(url), true);
  // An intro above the link stands as it is.
  const fine = `Hi Ben. I'm Cassy, the home's digital concierge, here with Marifel and our team.\n\n👉 ${url}`;
  assertEquals(withIntro(fine, 'en'), fine);
});

Deno.test('SPEC-32 s4 (F11): a warm Taglish 3-night anchor reply is not cold', () => {
  // Shaped on the stayAnchor Taglish order that fired cold_reply_retry nearly every time on 25 Sep.
  const reply = 'Ben, para sa 3 nights po, bumababa ang direct rate namin sa PHP 1,691 per night mula sa standard PHP 1,780 - mga PHP 5,073 para sa buong stay imbes na PHP 5,340, kaya makakatipid kayo ng mga PHP 267.\n\nIhahanda namin ang home para sa inyo, at gladly naming iche-check ang dates ninyo.';
  assertEquals(isCold(reply), false);
});

Deno.test('SPEC-32 s5 (F12): two unreadable JSON replies end in one plain-text call, wrapped as the reply', async () => {
  const calls: boolean[] = [];
  const bad = () => { throw new SyntaxError('bad json'); };
  const out = await draftOrPlain((plain = false) => { calls.push(plain); return Promise.resolve(plain ? 'Yes po, may parking sa harap ng unit.' : '{reply: broken'); }, bad);
  assertEquals(calls, [false, false, true]);
  assertEquals(out, { reply: 'Yes po, may parking sa harap ng unit.', uncertain: false });
  // A good first reply never reaches the fallback.
  const ok = await draftOrPlain(() => Promise.resolve('{"reply":"Hi"}'), (raw) => ({ reply: JSON.parse(raw).reply, uncertain: false }));
  assertEquals(ok.reply, 'Hi');
});
