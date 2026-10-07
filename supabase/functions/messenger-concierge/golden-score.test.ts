// deno test --no-check --allow-env messenger-concierge/golden-score.test.ts
// The rubric (protocol 10 section 7) must pass what the model is told to copy and fail what Lloyd rejected live.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { SITE_URL, VOICE } from '../_shared/cascade-core/facts.ts';
import { goldenCases, range } from './golden.ts';
import { dropNameAsk } from './voice.ts';
import { allowedPesos, type Ctx, failures, heldFrom, type Reg, scoreReply } from './golden-score.ts';

const base = (o: Partial<Ctx>): Ctx => ({ guest: 'is there wifi?', reply: '', prevReply: null, kind: 'model', lang: 'en', firstTurn: false, siteUrl: SITE_URL, name: 'Ben', ...o });
const rules = (o: Partial<Ctx>) => failures(scoreReply(base(o))).map((f) => f.split(':')[0]);

Deno.test('every example in VOICE passes the rubric: the model copies examples, so they are the standard', () => {
  const head = VOICE.lastIndexOf('\nREFERENCE REPLIES (');
  const chunks = VOICE.slice(0, VOICE.lastIndexOf('\nBEFORE YOU ANSWER')).split(/\nQ: /).slice(1);
  let seen = 0, offset = VOICE.indexOf('\nQ: ');
  for (const chunk of chunks) {
    const first = offset > head; offset = VOICE.indexOf('\nQ: ', offset + 1) < 0 ? VOICE.length : VOICE.indexOf('\nQ: ', offset + 1);
    const [q, ...rest] = chunk.split('\nA: ');
    const reply = rest.join('\nA: ').split(/\n\nREFERENCE REPLIES \(/)[0].trim();
    const note = /\(([^)]*)\)\s*$/.exec(q)?.[1] ?? '';
    const lang: Reg = /taglish/i.test(note) ? 'tl' : 'en'; // D-311.8: the Bisaya example is answered in English
    const guest = q.replace(/\s*\([^)]*\)\s*$/, '');
    const got = failures(scoreReply({ guest, reply, prevReply: null, kind: 'model', lang, firstTurn: first, siteUrl: SITE_URL, noInvite: /no invitation/i.test(note), guestUsedPo: /\bpo\b/i.test(guest), reference: true }));
    assertEquals(got, [], `example "${guest}" fails the rubric: ${got.join('; ')}`);
    seen++;
  }
  assertEquals(seen, 18); // six mid-conversation (D-311: how to book, the haggle) + twelve first-contact (the turnover-day pair included)
});

Deno.test('what Lloyd rejected live fails, rule by rule', () => {
  const blunt = 'Yes, Oct 27 to 29 is open. The home has fiber Wi-Fi with a dedicated workspace and a Smart TV with Netflix. The rate for 2 nights is PHP 1,691 per night, which is PHP 3,382 in total for the two nights of your stay.';
  assertEquals(rules({ reply: blunt }), ['R3']);
  assertEquals(rules({ reply: `Yes, Ben, there's fiber Wi-Fi, and we'll have it ready for you.\n\n👉 ${SITE_URL}` }), ['R4']); // bare link
  assertEquals(rules({ reply: `Yes, Ben, we'll have it ready. You may secure your dates directly on our site:` }), ['R4']); // dangling colon
  assertEquals(rules({ reply: `Yes, Ben, we'll have it ready.\n\nYou may secure your dates on our site:\n\n👉 ${SITE_URL}` }), ['R4']); // no chat route
  assertEquals(rules({ reply: `Yes, Ben, we'll have it ready.\n\nWe can arrange the booking here in the chat, or on our site:\n\n👉 ${SITE_URL}\n\nWhenever you feel ready, you may also secure your dates with us.` }), ['R4']); // two invitations
  assertEquals(rules({ reply: `Thank you, we'll look into it right away.\n\n👉 ${SITE_URL}`, kind: 'handoff', noInvite: true }), ['R4']);
  assertEquals(rules({ reply: `Yes, Ben, we'll have it ready for you. How many guests will be staying?`, held: heldFrom(['Oct 27 to 29, 2 guests'], 'Ben') }), ['R5']);
  assertEquals(rules({ reply: `Naa, Ben, naay Wi-Fi po, and we'll have it ready.`, lang: 'bis' }), ['R6']);
  assertEquals(rules({ reply: `Yes po, Ben, may Wi-Fi po, and ready po ang kitchen po, we'll take care of it.`, lang: 'tl' }), ['R6']);
  assertEquals(rules({ reply: `Yes, Ben, we will have the Wi-Fi ready for you.` }), ['R6']); // uncontracted
  assertEquals(rules({ reply: `Hi Ben! Yes, there's fiber Wi-Fi, and we'll have it ready.` }), ['R7']);
  assertEquals(rules({ reply: `Yes, there's a full kitchen. We'll have everything ready for you.`, prevReply: `Yes, fiber Wi-Fi. We'll have everything ready for you.` }), ['R8']);
  assertEquals(rules({ reply: `Yes, Ben, and for 3 nights it's PHP 4,900 in total; we'll have it ready.` }), ['R9']);
  assertEquals(rules({ reply: `Yes, Ben, we can accommodate 4 adults, and we'll have it ready.` }), ['R9']);
  assertEquals(rules({ reply: `Ben, I'm Cascade Hideaway's automated assistant, glad to help anytime.`, kind: 'code' }), ['R2']);
  assertEquals(rules({ reply: `Which dates are you looking at?`, guest: 'is it available?' }), ['R1']);
});

Deno.test('a guest whose name we hold is never asked for it', () => {
  assertEquals(dropNameAsk(`Good evening! Thank you for reaching out.\n\nWe'd be glad to help.\n\nMay we know your name po?`), `Good evening! Thank you for reaching out.\n\nWe'd be glad to help.`);
  assertEquals(dropNameAsk(`We'd be glad to help. May we know your name? We'll check the calendar right away.`), `We'd be glad to help. We'll check the calendar right away.`);
  assertEquals(dropNameAsk('May we know your name?'), 'May we know your name?'); // never empty
});

Deno.test('the rate card is the only source of peso figures', () => {
  const ok = allowedPesos();
  for (const v of [1780, 1691, 3382, 5073, 1000, 300, 89 * 3, 890]) assertEquals(ok.has(v), true, String(v));
  // A stay plus an early check-in is one honest figure (golden run 10: R9 called
  // PHP 3,582 invented, a PHP 3,382 two-night stay arriving at 10 AM).
  for (const v of [3582, 1880, 5373]) assertEquals(ok.has(v), true, String(v));
  assertEquals(ok.has(4900), false);
  assertEquals(ok.has(3382 + 700), false); // early check-in stops at 6 hours before noon
});

Deno.test('the golden set is complete, unique and does not rot', () => {
  const now = new Date('2026-12-30T00:00:00Z'), cases = goldenCases(now, 'Oct 3 to 5', 'Oct 5');
  assertEquals(cases.length >= 30, true);
  assertEquals(new Set(cases.map((c) => c.id)).size, cases.length);
  for (const g of ['first', 'followup', 'register', 'flow', 'handoff']) assertEquals(cases.some((c) => c.group === g), true, g);
  for (const l of ['en', 'tl']) assertEquals(cases.some((c) => c.turns.some((t) => t.lang === l)), true, l);
  // D-311.8 (Lloyd 2026-10-07): a Bisaya guest is answered in English, so no case expects a Bislish reply any more.
  assertEquals(cases.some((c) => c.turns.some((t) => t.lang === 'bis')), false);
  assertEquals(cases.some((c) => c.id === 'first-bisaya-gets-english') && !cases.some((c) => c.id === 'first-bisaya-gets-taglish'), true);
  assertEquals(range(new Date('2026-10-30T00:00:00Z'), 0, 2), 'Oct 30 to Nov 1');
  assertEquals(range(now, 40, 2), 'Feb 8 to 10'); // a year boundary
});

Deno.test('R9: an early check-in fee that contradicts PHP 100 per hour before noon fails (golden run 4, K18)', () => {
  const reply = `Ben, early check-in before noon is PHP 100 per hour, so arriving at 10 AM would be PHP 400 total. We'll have the unit ready for you.`;
  assertEquals(rules({ guest: 'Can we check in at 10am on the first day?', reply }).includes('R9'), true);
  assertEquals(rules({ guest: 'Can we check in at 10am on the first day?', reply: reply.replace('400', '200') }).includes('R9'), false);
});

Deno.test('GOLDEN_OPEN_FROM pins the open-date cases to a known-open window (golden run 6)', () => {
  const avail = (cs: ReturnType<typeof goldenCases>) => cs.find((c) => c.id === 'first-avail-en')!.turns[0].say;
  assertEquals(avail(goldenCases(new Date('2026-09-17T00:00:00Z'), null, null, new Date('2026-11-02T00:00:00Z'))).includes('Nov 2 to 4'), true);
  assertEquals(avail(goldenCases(new Date('2026-09-17T00:00:00Z'))).includes('Oct 27 to 29'), true); // unchanged without it
});

Deno.test('SPEC-32 s7: rule E fails a turn whose effect is missing, however right the reply reads', () => {
  const base = { guest: 'cancel po', reply: 'Understood, Ben. We have let our host know.', prevReply: null, kind: 'code' as const, lang: 'en' as const, firstTurn: false, siteUrl: 'https://x' };
  assertEquals(scoreReply({ ...base, effects: [/"handoff"[^}]*cancellation/], effectsText: '[{"fx":"handoff","text":"cancel po","detail":{"risk":"cancellation","note":"Ref X"}}]' }).E, null);
  assertEquals(scoreReply({ ...base, effects: [/"handoff"[^}]*cancellation/], effectsText: '[]' }).E?.startsWith('effect missing'), true);
});
Deno.test('D-286 R1: a first greeting paragraph that names Cassy is skipped, however long; the answer is the next paragraph', () => {
  const greet = `Hi Ben, thank you for reaching out to Cascade Hideaway. I'm Cassy, the home's digital concierge, here with Marifel and our team.`;
  assertEquals(scoreReply(base({ guest: 'How much for a month-long stay?', firstTurn: true, reply: `${greet}\n\nFor 28 nights the direct rate is PHP 1,335 a night, PHP 37,380 for the stay.` })).R1, null);
  assertEquals(scoreReply(base({ guest: 'How much for a month-long stay?', firstTurn: true, reply: `${greet}\n\nWhich dates would you like?` })).R1 !== null, true);
});
Deno.test('D-286: the nine s63 cases (month, deposit, party x en/tl/bis) catch the 2026-09-30 frame faults', () => {
  const cs = goldenCases(new Date('2026-10-01T00:00:00Z')).filter((c) => c.id.startsWith('s63-'));
  assertEquals(cs.length, 9);
  const month = cs.find((c) => c.id === 's63-month-en')!.turns[0], dep = cs.find((c) => c.id === 's63-deposit-en')!.turns[1];
  const greet = `Hi Ben, thank you for reaching out to Cascade Hideaway. I'm Cassy, the home's digital concierge, here with Marifel and our team.`;
  const live = `${greet} For a month-long stay, Ben, the direct rate is PHP 1,335 per night, PHP 37,380 for 28 nights.`; // the live fault
  assertEquals(rules({ guest: month.say, firstTurn: true, reply: live, must: month.must, mustNot: month.mustNot }).includes('X'), true);
  assertEquals(rules({ guest: month.say, firstTurn: true, reply: `${greet}\n\nFor a month-long stay, the direct rate is PHP 1,335 per night, PHP 37,380 for 28 nights.\n\nCassy, Cascade Concierge`, must: month.must, mustNot: month.mustNot }).includes('X'), false);
  const twoCloses = `Ben, yes - the PHP 1,000 refundable deposit applies to every stay.\n\nWe're here if you have any other questions.\n\nJust let us know your preferred dates, and we'll gladly check our availability for you.`;
  assertEquals(rules({ guest: dep.say, reply: twoCloses, must: dep.must, mustNot: dep.mustNot }).includes('X'), true);
  assertEquals(rules({ guest: dep.say, reply: `Ben, yes - the PHP 1,000 refundable deposit applies to every stay. We'll have everything prepared before you arrive. 🌿`, must: dep.must, mustNot: dep.mustNot }).includes('X'), true);
});

// ---- SPEC-39 (D-299.10, D-300.1): the first message carries no link and is signed; nothing after it is signed ----
Deno.test('SPEC-39 R4/X: a link on the first message fails R4; an unsigned first message and a signed follow-up fail X', () => {
  const signed = `Hi Ben, thank you for reaching out to Cascade Hideaway. Yes, there's free parking in front of the unit.\n\nWe'd be delighted to have you with us. Which dates are you looking at? Share your check-in and check-out here and we'll check the calendar for you right away.\n\nCassy, Cascade Concierge`;
  assertEquals(rules({ guest: 'is there parking?', firstTurn: true, reply: signed }), []);
  const linked = signed.replace('\n\nCassy', `\n\nWe can arrange it here in the chat, or on our site:\n👉 ${SITE_URL}\n\nCassy`);
  assertEquals(rules({ guest: 'is there parking?', firstTurn: true, reply: linked }).includes('R4'), true);
  assertEquals(scoreReply(base({ guest: 'is there parking?', firstTurn: true, reply: linked })).R4, 'a link on the first message (D-299.10)');
  assertEquals(scoreReply(base({ guest: 'is there parking?', firstTurn: true, reply: signed.replace(/\n\nCassy, Cascade Concierge$/, '') })).X, 'first message not signed');
  assertEquals(scoreReply(base({ guest: 'is there parking?', reply: `Yes, Ben, there's free parking.\n\nCassy, Cascade Concierge` })).X, 'signature on a follow-up');
  // a first-message handoff is never signed and never scored for it; a flow's first reply is
  assertEquals(scoreReply(base({ guest: 'the aircon is broken', firstTurn: true, kind: 'handoff', noInvite: true, reply: 'Thank you for letting us know right away. Our host has already been alerted.' })).X, null);
  assertEquals(scoreReply(base({ guest: 'Oct 20 to 22?', firstTurn: true, kind: 'flow', reply: 'Hi Ben, thank you. Oct 20 to 22 is available.' })).X, 'first message not signed');
});
Deno.test('SPEC-39 golden: the first-turn link cases flipped, the D-300.2 link cases added, the new cases present', () => {
  const cs = goldenCases(new Date('2026-10-04T00:00:00Z'), 'Oct 10 to 12');
  const byId = (id: string) => cs.find((c) => c.id === id)!;
  const link = /tinyurl\.com\/Stay-at-Cascade/;
  for (const id of ['first-greeting-en', 'first-greeting-tl', 'first-rate-en', 'first-rate-tl', 'first-location-en', 'first-howtobook-en', 'reg-english-po']) {
    const t = byId(id).turns[0];
    assertEquals((t.mustNot ?? []).some((r) => String(r) === String(link)), true, `${id} mustNot LINK`);
    assertEquals((t.must ?? []).some((r) => String(r) === String(link)), false, `${id} no longer must LINK`);
  }
  for (const id of ['first-two-months-en', 'first-two-months-tl', 'first-vague-en', 'first-until-en', 'flow-family-en', 'fu-thanks-bless-en', 'fu-chat-yes-en', 'fu-objection-dated-en', 'fu-mahal-tl', 'fu-second-link-en', 'fu-photos-tl', 'fu-howtobook-en', 'fu-reviews-en', 'pay-brisk-en', 'pay-gentle-en', 'first-avail-taken-en'])
    assertEquals(!!byId(id), true, id);
  assertEquals(byId('fu-photos-tl').turns[1].must!.some((r) => String(r) === String(link)), true);
  assertEquals(byId('fu-think-about-it-en').turns[1].must!.some((r) => String(r) === String(link)), true);
  // pay-near-en needs a really open stay inside five days (GOLDEN_SOON)
  assertEquals(cs.some((c) => c.id === 'pay-near-en'), false);
  assertEquals(goldenCases(new Date('2026-10-04T00:00:00Z'), null, null, null, 'Oct 6 to 7').some((c) => c.id === 'pay-near-en'), true);
});
