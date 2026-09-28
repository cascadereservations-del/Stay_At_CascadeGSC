// deno test --no-check messenger-concierge/persona.test.ts
// D-268: the tone gate for persona.ts. Whatever the flow does, every move passes the persona lint in every register, the
// REQUIRED disclosures are always carried, and Bislish never carries a Tagalog "po". A flow change cannot break these;
// a wording change that does fails here before it reaches a guest.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { CAPACITY, LAST_MINUTE, choiceAck, detailsAsk, holdOffer, oneNight, partyAsk, partyWelcome } from './persona.ts';
import { lintReply } from './voice.ts';

const LANGS = ['en', 'tl', 'bis'] as const;
const moves = (lang: typeof LANGS[number]) => [
  oneNight('PHP 1,780', lang), holdOffer(true, lang), holdOffer(false, lang), choiceAck('Oct 2', lang), partyAsk(lang),
  partyWelcome('you', lang), partyWelcome('the two of you', lang), detailsAsk('Suzanne', lang), detailsAsk('', lang),
  `${oneNight('PHP 1,780', lang)} ${LAST_MINUTE}`,
];

Deno.test('every persona move passes the lint in all three registers', () => {
  for (const lang of LANGS) for (const m of moves(lang)) {
    assertEquals(lintReply(m), [], `${lang}: ${m}`);
    assert(!/[!]/.test(m), `no exclamation: ${m}`);
    if (lang === 'bis') assert(!/\b(po|opo)\b/i.test(m), `no po in Bislish: ${m}`);
    assert((m.match(/\bpo\b/gi) ?? []).length <= 2, `at most two po: ${m}`);
  }
});

Deno.test('the REQUIRED disclosures are carried whatever the wording', () => {
  for (const lang of LANGS) assert(partyAsk(lang).includes(CAPACITY[lang]), lang);
  assert(/3 adults, or 2 adults with 2 (children|kids)/.test(CAPACITY.en + CAPACITY.tl + CAPACITY.bis));
  assert(/five days/.test(LAST_MINUTE) && /full amount/.test(LAST_MINUTE));
});

Deno.test('the details are asked in one message, and the name is used once when known', () => {
  for (const lang of LANGS) {
    const d = detailsAsk('Suzanne', lang);
    assert(/name/i.test(d) && /mobile/i.test(d) && /email/i.test(d), `${lang}: ${d}`);
    assertEquals(d.split('Suzanne').length - 1, 1, lang);
  }
});
