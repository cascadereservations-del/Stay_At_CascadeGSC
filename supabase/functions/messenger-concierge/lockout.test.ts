// deno test --no-check messenger-concierge/lockout.test.ts
// Session 58 (live 2026-09-28): a guest locked out without her phone wrote "nakalimutan ko po yung code ... I didn't bring
// a card" from a friend's account; the regex read it as routine and only Jev caught it. The door is a regex floor.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { classify } from './policy.ts';
import { handoffFollowUp } from './persona.ts';

Deno.test('a lockout is access in every register, and near misses stay routine', () => {
  const locked = [
    "Hello po ako po yong nag rerent nung airbnb now unfortunately I didn't bring a card and my phone po nakalimutan ko po yung code may i get it again",
    'I forgot the door code', 'forgot my keys inside', 'hindi po ako makapasok', 'dili mi kasulod sa unit', 'I locked myself out',
    "we can't get inside", 'naiwan ko po yung susi sa loob',
  ];
  for (const t of locked) assertEquals(classify(t), 'access', t);
  for (const t of ['is there parking?', 'may promo code po ba?', 'Allyssa Estenzo po yung name ko', 'I forgot to ask, is there wifi?', 'pinakaduol nga mall?']) {
    assertEquals(classify(t), 'routine', t);
  }
});

Deno.test('the follow-up line promises nothing the code does not do: no dates, no link, no booking close', () => {
  for (const l of ['en', 'tl', 'bis'] as const) {
    const m = handoffFollowUp(l);
    assertEquals(/dates|https?:|book|site/i.test(m), false, m);
  }
});

Deno.test('safety: "sparks" is a safety message (the regex once held a literal backspace instead of \b)', () => {
  assertEquals(classify('there are sparks coming from the socket'), 'safety');
  assertEquals(classify('may spark sa outlet'), 'safety');
});
