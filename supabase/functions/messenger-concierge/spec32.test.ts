// deno test --no-check -A messenger-concierge/spec32.test.ts
// SPEC-32 s1, s3, s4, s5 (REVIEW-bot-2026-09-26 F9, F11, F12, F14; D-249, D-251, D-252).
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { FACTS, MAYA_FACT } from '../_shared/cascade-core/facts.ts';
import { isCold } from './voice.ts';

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
