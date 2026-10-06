import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { draftRequest } from './draft.ts';

Deno.test('draftRequest recognises the reply/draft/how-should-I-answer forms', () => {
  assertEquals(draftRequest('reply: Hi po, available ba Oct 3-4?'), { draft: true, text: 'Hi po, available ba Oct 3-4?' });
  assertEquals(draftRequest('draft'), { draft: true, text: '' });
  assertEquals(draftRequest('how should I answer this: pwede pets?'), { draft: true, text: 'pwede pets?' });
  assertEquals(draftRequest('what do we say: may discount?').draft, true);
  assertEquals(draftRequest('who is Queenie Gonzales?').draft, false);
  assertEquals(draftRequest('status').draft, false);
});

Deno.test('D-269: splitThread answers the guest lines after our last message; forHost drops the bot introduction', async () => {
  const { splitThread, forHost } = await import('./draft.ts');
  const s = splitThread([{ from: 'guest', text: 'Hi' }, { from: 'host', text: 'Hello Ana' }, { from: 'guest', text: 'Is party allowed?' }, { from: 'guest', text: 'for 5 friends' }]);
  assertEquals(s.latest, 'Is party allowed?\nfor 5 friends');
  assertEquals(s.before.length, 2);
  assertEquals(splitThread([{ from: 'guest', text: 'Hi po' }]).latest, 'Hi po');
  assertEquals(forHost("Hi Ana, thank you for reaching out. I'm Cassy, the home's digital concierge, here with Marifel and our team.\n\nThe night of Oct 3 is available."), "Hi Ana, thank you for reaching out.\n\nThe night of Oct 3 is available.");
});

Deno.test('D-270: forHost drops the bot-only "shared with our host" sentences (the host is the one sending)', async () => {
  const { forHost } = await import('./draft.ts');
  assertEquals(forHost("We're a quiet private retreat for registered guests. If you have a small occasion in mind, we've shared your message with our host, who will reply here personally."), "We're a quiet private retreat for registered guests.");
  assertEquals(forHost('For 30 nights it comes to PHP 40,050. Our host also looks at special requests personally, so we have shared your message with them.\n\nWhich dates suit you?'), 'For 30 nights it comes to PHP 40,050.\n\nWhich dates suit you?');
});

// ---- SPEC-38 (session 70): Cassy's reply and the Other decline. Synthetic data only. ----
import { assert, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { declineInstruction, gateInquiry, inquiryDraftCard, routeDraft } from './draft.ts';
import type { InquiryView } from '../_shared/cascade-core/inquiry.ts';

const IQ_ID = '00a49c5e-1111-4222-8333-444455556666';
const iqView = { id: IQ_ID, ref: '00A49C5E', guest_name: 'Ana Cruz', guest_email: 'ana@example.com', guest_phone: '0917', checkin_date: '2026-11-30', checkout_date: '2026-12-04', nights: 4, pax: 2,
  total_amount: 12400, deposit_amount: 6200, notes: null, submitted_at: '2026-10-04T14:40:00Z', status: 'pending', has_receipt: false, hold_expires_at: null, held_by: null, held_at: null, conflict: false } as InquiryView;
const GOOD = 'Ana, early check-in is welcome from 12 noon when no guest checks out that day, and our host will confirm it once your request is settled.';

Deno.test('inquiry draft card: a clean draft has Send, Draft again and Discard', () => {
  const c = inquiryDraftCard({ view: iqView, purpose: 'reply', pid: 'p1-0000-4000-8000-000000000001', d: { text: GOOD, gate: [], source: 'concierge', channel: 'Messenger', lastMessage: 'pwede po early check-in?' } });
  assertStringIncludes(c.text, '✍️ Reply for Ana · Messenger · calendar and rate card checked');
  assertStringIncludes(c.text, 'Guest wrote: "pwede po early check-in?"');
  assertStringIncludes(c.text, '📨 ⤵\n' + GOOD);
  assertEquals(c.keyboard.flat().map((b) => b.callback_data?.split(':').slice(0, 2).join(':')), ['iq:send', 'iq:draft', 'iq:drop']);
  const dec = inquiryDraftCard({ view: iqView, purpose: 'decline', pid: 'p1-0000-4000-8000-000000000001', d: { text: GOOD, gate: [], source: 'model', channel: 'e-mail', lastMessage: null } });
  assertStringIncludes(dec.text, "❌ Decline Ana's request with this message?");
  assertEquals(dec.keyboard.flat().map((b) => b.callback_data?.split(':').slice(0, 2).join(':')), ['iq:send', 'iq:drop']);
});

Deno.test('inquiry draft card: a gate failure after the rewrite gives a card with no iq:send: button', () => {
  for (const purpose of ['reply', 'decline'] as const) {
    const c = inquiryDraftCard({ view: iqView, purpose, pid: '', d: { text: 'Wonderful, Ana! Send ₱890 now.', gate: ['exclaim', 'command_tone'], source: 'model', channel: 'e-mail', lastMessage: null } });
    assertStringIncludes(c.text, '⚠️ Voice check: exclaim, command_tone. Send is off; tap 🔄 Draft again.');
    assert(!c.keyboard.flat().some((b) => String(b.callback_data).startsWith('iq:send:')), purpose);
    assertEquals(c.keyboard.flat().length, 1);
  }
});

Deno.test('routeDraft: OPS plus money is a Finance copy with ops_ok false; OPS without money is sendable; Finance always is', () => {
  assertEquals(routeDraft('ops', 'The early check-in is ₱100 per hour before noon.'), { ops_ok: false, toFinance: true });
  assertEquals(routeDraft('ops', GOOD), { ops_ok: true, toFinance: false });
  assertEquals(routeDraft('finance', 'The early check-in is ₱100 per hour before noon.'), { ops_ok: true, toFinance: false });
});

Deno.test('declineInstruction forbids quoting the reason, and a model that echoes it is caught by the gate', () => {
  const p = declineInstruction('Nov 30 to Dec 4', 'refined conversational English, no "po"', 'guest asked for a party');
  assertStringIncludes(p, 'never quote, reveal or hint at it');
  assertStringIncludes(p, 'Do not promise anything, do not mention money');
  assertStringIncludes(p, '"""guest asked for a party"""');
  const echo = 'Ana, thank you for asking. We are sorry, but the guest asked for a party and the home is quiet. Should other dates suit you, we would be glad to help.';
  assert(gateInquiry(echo, '', 'en', 'guest asked for a party').includes('quotes_private_reason'));
  const clean = 'Ana, thank you for your request for Nov 30 to Dec 4. We are unable to accept this stay, and we would be glad to hear from you again should your plans change.';
  assertEquals(gateInquiry(clean, '', 'en', 'guest asked for a party'), []);
});

Deno.test('D-306: the inquiry draft card posted in OPS masks the guest own amounts; Finance sees them whole', () => {
  const d = { text: GOOD, gate: [] as string[], source: 'concierge' as const, channel: 'Messenger' as const, lastMessage: 'ok po, I sent PHP 1,780 to 0956 011 5744 already' };
  const ops = inquiryDraftCard({ view: iqView, purpose: 'reply', pid: 'p1-0000-4000-8000-000000000001', forOps: true, d });
  assert(!/1,780|0956/.test(ops.text), ops.text);
  assertStringIncludes(ops.text, 'Guest wrote: "ok po, I sent [amount hidden] to [number hidden] already"');
  const fin = inquiryDraftCard({ view: iqView, purpose: 'reply', pid: 'p1-0000-4000-8000-000000000001', d });
  assertStringIncludes(fin.text, 'PHP 1,780');
});

// ---- SPEC-39 section 6 (BRIEF H, D-296.3): Marifel's Airbnb register, checked in code. Synthetic guests only. ----
import { airbnbTone, calmMoment, AIRBNB_HOST_REGISTER } from './draft.ts';
import { postDraft } from './policy.ts';
const SIGN = 'Marifel & The Cascade Team\nHotel Comfort. Home Warmth.';
const WARM = `Hi Dale! 🌿 Thank you for your interest in Cascade Hideaway po.\n\nOct 20 to 22 is open, and we'd be delighted to host the two of you. The unit has fiber Wi-Fi, a full kitchen and free parking inside our gated village.\n\nKapag ready na po kayo, just send a booking request on the listing and we'll confirm right away.\n${SIGN}`;
const CALM = `Hi Joseph. Yes, you don't need to check out today. The reminder was sent automatically by mistake, and we're sorry for the confusion. Your check-out remains 12:00 NN on Oct 5. Thank you for your understanding.\n${SIGN}`;

Deno.test('SPEC-39 airbnbTone: the playbook examples pass; each rule fails by construction', () => {
  assertEquals(airbnbTone(WARM, false), []);
  assertEquals(airbnbTone(CALM, true), []);
  const fails = (m: string, calm = false) => airbnbTone(m, calm);
  assert(fails(WARM.replace('fiber Wi-Fi', 'wonderful fiber Wi-Fi')).includes('exclaim'));
  assert(fails(WARM.replace('Thank you for', 'Rest assured, thank you for')).includes('boilerplate'));
  assert(fails(WARM.replace('just send', 'book now, only 2 nights left - just send')).includes('urgency'));
  for (const off of ['https://tinyurl.com/x', 'GCash 0956 011 5744', 'scan the QR', 'call 0917 123 4567', 'mail me at a@example.com'])
    assert(fails(WARM.replace('just send', `${off} or just send`)).includes('off_platform'), off);
  assert(fails(WARM.replace('just send', 'we can offer a discount, just send')).includes('promise'));
  assert(fails(CALM.replace('Your check-out', 'Late check-out is fine. Your check-out'), true).includes('promise'));
  assert(fails(WARM.replace(`\n${SIGN}`, '')).includes('no_sign_off'));
  assert(fails(WARM.replace('Cascade Hideaway po.', 'Cascade Hideaway po, salamat po, ingat po.')).includes('po_over_two'));
  assert(fails(WARM.replace('Thank you for', "I'm Cassy. Thank you for")).includes('not_marifel'));
  assert(fails(WARM.replace('we\'ll confirm', 'our host will confirm')).includes('not_marifel'));
  assert(fails(WARM.replace('right away.', 'right away!')).includes('exclamation_after_greeting'));
  assertEquals(fails(CALM.replace('Hi Joseph.', 'Hi Joseph!'), true), ['exclamation_in_calm']);
  assertEquals(fails(CALM.replace('understanding.', 'understanding. 💚'), true), ['emoji_in_calm']);
});

Deno.test('SPEC-39 calmMoment: the calm list (complaint, safety, access, refund, cancellation, payment, our mistake)', () => {
  for (const r of ['complaint', 'safety', 'access', 'refund', 'cancellation', 'payment']) assertEquals(calmMoment('hello', r), true, r);
  assertEquals(calmMoment("I don't have to check out today do I", 'routine'), true);
  assertEquals(calmMoment('The aircon stopped working, it is so hot', 'routine'), true);
  assertEquals(calmMoment('Available po ba Oct 20-22? 2 kami', 'routine'), false);
  assertEquals(calmMoment('Can you give a discount for 5 nights?', 'policy_exception'), false);
});

Deno.test('SPEC-39 (D-300.1): forHost drops the initial-message signature - the host signs as herself', async () => {
  const { forHost } = await import('./draft.ts');
  assertEquals(forHost(`Hi Ana, thank you for reaching out.\n\nWhich dates are you looking at?\n\nCassy, Cascade Concierge`), 'Hi Ana, thank you for reaching out.\n\nWhich dates are you looking at?');
  assert(AIRBNB_HOST_REGISTER.includes('Marifel & The Cascade Team') && /never Cassy/.test(AIRBNB_HOST_REGISTER));
});

Deno.test('D-306 (SPEC-39 change): a money-shaped Airbnb or concierge draft asked in OPS goes to Finance; OPS gets no amount', async () => {
  const sent: Array<{ chat: string; text: string }> = [];
  const send = (chat: string, text: string) => { sent.push({ chat, text }); return Promise.resolve(true); };
  const draft = `Hi Dale! Oct 20 to 22 comes to ₱3,382, and the ₱1,691 reservation fee holds the dates (GCash 0956 011 5744).\n${SIGN}`;
  const head = '✍️ Guest reply · Dale · Airbnb\n⚠️ Airbnb voice check: off_platform. Read it before sending.';
  const r = await postDraft(send, { surface: 'ops', chatId: 'ops-chat', financeChat: 'fin-chat', refused: 'Posted in Finance.', parts: [head, draft] });
  assertEquals(r.toFinance, true);
  const ops = sent.filter((s) => s.chat === 'ops-chat').map((s) => s.text).join('\n');
  assert(!/3,382|1,691|0956/.test(ops), ops);
  assert(sent.some((s) => s.chat === 'fin-chat' && s.text.includes('₱3,382')));
});
Deno.test('SPEC-39 airbnb golden: the playbook examples meet their own cases (a case nothing can pass proves nothing)', async () => {
  const { CASES } = await import('./airbnb-draft.golden.ts');
  const ok = (id: string, m: string) => { const c = CASES.find((x) => x.id === id)!; return c.must.every((re) => re.test(m)) && !c.mustNot.some((re) => re.test(m)); };
  assertEquals(CASES.length, 6);
  assertEquals(ok('inquiry-tl', WARM), true);
  assertEquals(ok('our-mistake-calm', CALM), true);
  assertEquals(ok('inquiry-en', WARM), false); // "po" for an English guest fails
});

// ---- s73 (golden 8/18 on 2026-10-06): the drafts below are the live model's own, from that run. ----
import { airbnbFallback, airbnbFinish, airbnbGuard, airbnbLeaks, draftSystem } from './draft.ts';
import { SEED_CARD } from '../_shared/cascade-core/pricing.ts';
import { SITE_URL } from '../_shared/cascade-core/facts.ts';
const LEAK_1 = `Hi Ana! Our direct rates already include a discount for longer stays. For 5 nights, the nightly rate comes down to PHP 1,602 from our standard PHP 1,780, and includes a complimentary mid-stay room refresh.\n\nIf you have dates in mind, you may send them here, and I'll gladly check the availability for you.\n\n${SIGN}`;
const LEAK_2 = `Hi Ana!\n\nYes, our direct booking rates already include a discount for longer stays. For 5 nights, the rate is PHP 1,602 per night, which is 10% off our standard rate of PHP 1,780.\n\nWe can arrange the booking in this chat, or you may secure your dates on our site:\n👉 ${SITE_URL}\n\n${SIGN}`;
const golden = async (id: string) => (await import('./airbnb-draft.golden.ts')).CASES.find((x) => x.id === id)!;
const meets = (c: { must: RegExp[]; mustNot: RegExp[] }, m: string) => c.must.every((re) => re.test(m)) && !c.mustNot.some((re) => re.test(m));

Deno.test('s73 D1: the Airbnb draft prompt carries no direct rate, link, GCash, e-mail or direct-booking talk; Messenger keeps them', () => {
  const p = draftSystem(SEED_CARD, true, false).split('You are drafting for the HOST')[0]; // what follows is the register's own "never ..." list
  for (const re of [/tinyurl|https?:\/\//i, /\bPHP\b|₱/, /\d,\d{3}/, /\bgcash\b/i, /\bdirect\b/i, /\bour site\b/i, /@/, /whats ?app/i, /\bdeposit\b/i]) assert(!re.test(p), String(re));
  assertStringIncludes(draftSystem(SEED_CARD, true, false), 'AIRBNB REGISTER');
  assertStringIncludes(p, 'Check-in 2:00 PM'); // the house facts stay
  assertStringIncludes(draftSystem(SEED_CARD, false), SITE_URL);
});

Deno.test('s73 D1: airbnbTone flags direct-booking talk and figures, not only links', () => {
  assertEquals(airbnbLeaks(LEAK_1), ['direct_booking', 'price']); // passed airbnbTone on b506365
  assertEquals(airbnbLeaks(LEAK_2), ['off_platform', 'direct_booking', 'price']);
  for (const s of ['book directly with us', 'our site has it', 'message us on Messenger', 'WhatsApp me', 'it is ₱1,602', '1,602 pesos', '10% off'])
    assert(airbnbLeaks(WARM.replace('just send', `${s}, just send`)).length, s);
  assertEquals(airbnbLeaks(WARM), []);
});

Deno.test('s73 D1: a leaking draft is regenerated once with the strict rule, then replaced by the code-written fallback', async () => {
  const finish = (m: string) => airbnbFinish(m, 'en', false);
  const calls: boolean[] = [];
  const once = await airbnbGuard((strict) => { calls.push(strict); return Promise.resolve(strict ? "Hi Ana! I'll check this and confirm here on the listing." : LEAK_1); }, finish, airbnbFallback('Ana', false));
  assertEquals(calls, [false, true]);
  assertEquals(once, `Hi Ana! I'll check this and confirm here on the listing.\n\n${SIGN}`);
  calls.length = 0;
  const fb = await airbnbGuard((strict) => { calls.push(strict); return Promise.resolve(LEAK_2); }, finish, airbnbFallback('Ana Cruz', false));
  assertEquals(calls, [false, true]);
  assert(!fb.includes('PHP') && !fb.includes('http'), fb);
  assertEquals(airbnbTone(fb, false), []);
  assert(meets(await golden('discount-ask'), fb), fb);
  const calmFb = airbnbFinish(airbnbFallback(null, true), 'en', true);
  assertEquals(airbnbTone(calmFb, true), []);
  assert(calmFb.startsWith('Hi there.'), calmFb);
});

Deno.test('s73 D2: the sign-off is appended when missing and written exactly once', () => {
  const bare = "Hi Emma! Thank you for your message. I'll check the availability for October 20-22 for two guests and confirm with you shortly.";
  const signed = airbnbFinish(bare, 'en', false);
  assertEquals(signed, `${bare}\n\n${SIGN}`);
  assertEquals(airbnbFinish(signed, 'en', false), signed);
  assertEquals(airbnbFinish(`${bare}\nMarifel & The Cascade Team`, 'en', false), signed); // a half sign-off is not doubled
  assertEquals(airbnbTone(signed, false), []);
});

Deno.test('s73 D3: a Taglish guest draft carries one or two "po", never more; English and Bisaya get none added', async () => {
  const run2 = "Hi Dale! I'll gladly check the availability for October 20-22 for two guests and confirm with you shortly.";
  const tl = airbnbFinish(run2, 'tl', false);
  assertStringIncludes(tl, 'confirm with you shortly po.');
  assert(meets(await golden('inquiry-tl'), tl), tl);
  assertStringIncludes(airbnbFinish('Hi Dale! Yes, we have parking.', 'tl', false), 'Yes po, we have parking.');
  assertEquals((airbnbFinish('Hi Dale! Yes po, may parking po, may Wi-Fi po, at may kitchen po.', 'tl', false).match(/\bpo\b/g) ?? []).length, 2);
  assert(!/\bpo\b/.test(airbnbFinish(run2, 'en', false)));
  assert(!/\bpo\b/.test(airbnbFinish('Hi Dale! Naa po, free parking.', 'bis', false)));
});

Deno.test('s73 D4: a calm draft thanks the guest for their understanding; the case accepts "don\'t have to"', async () => {
  const c = await golden('our-mistake-calm');
  const live = ["Hi Joseph.\n\nNo, you don't have to check out today. Your booking is until tomorrow, so check-out is at 12:00 noon tomorrow, October 20.", 'Hi Joseph.\n\nNo, you do not have to check out today. Your booking is set until tomorrow, October 18, at 12:00 noon.'];
  for (const d of live) {
    const m = airbnbFinish(d, 'en', true);
    assert(meets(c, m), m);
    assertEquals(airbnbTone(m, true), []);
  }
  const owned = 'Hi Joseph. The reminder went out by mistake. Thank you for your understanding.';
  assertEquals(airbnbFinish(owned, 'en', true), `${owned}\n\n${SIGN}`); // never a second thank-you
  assert(!airbnbFinish('Hi Emma! Yes, there is parking.', 'en', false).includes('understanding')); // warm drafts untouched
});

// ---- s73 round 2 (Fable review of 158d1c5) ----
Deno.test('s73 R2-1: bare domains, spaced phones, Maya, bank transfer, socials, outside-Airbnb and bare figures all leak', () => {
  for (const s of ['Visit cascadehideaway.com', 'see tinyurl.com/Stay-at-Cascade', 'm.me/cascade', 'fb.me/cascade', 'call +63 917 123 4567', 'call 0917.123.4567',
    'pay via Maya', 'a bank transfer works', 'Message us on Facebook', 'on Instagram', 'on Telegram', 'Check our page', 'book outside Airbnb',
    'it is 1,602 per night', 'it is 1602 per night', 'it is P1,602', 'that is 10 percent off'])
    assert(airbnbLeaks(WARM.replace('just send', `${s}, just send`)).length, s);
  for (const s of ['check-in is at 2:00 PM', 'check-out is 12 noon', 'Oct 20-22 for 2 guests', 'we are at Block 47 Lot 39'])
    assertEquals(airbnbLeaks(WARM.replace('just send', `${s}, just send`)), [], s);
});

Deno.test('s73 R2-3: "100% ready" and "the booking page on Airbnb" are not leaks (they used to force the fallback)', () => {
  assertEquals(airbnbLeaks(WARM.replace('just send', 'we are 100% ready for you, just send')), []);
  assertEquals(airbnbLeaks(WARM.replace('just send', 'the booking page on Airbnb shows the total, just send')), []);
  assertEquals(airbnbLeaks(WARM.replace('just send', 'it is 10% off, just send')), ['price']);
});

Deno.test('s73 R2-2: the courtesy "po" goes at a sentence end, never inside "Oct.", "P.M." or "e.g."', () => {
  assertEquals(airbnbFinish("Hi Dale! I will check Oct. 20-22 for you. We'd be glad to host you.", 'tl', false).split('\n')[0], "Hi Dale! I will check Oct. 20-22 for you po. We'd be glad to host you.");
  assertEquals(airbnbFinish('Hi Dale! Check-in is 2:00 P.M. and check-out is noon.', 'tl', false).split('\n')[0], 'Hi Dale! Check-in is 2:00 P.M. and check-out is noon po.');
  assertEquals(airbnbFinish('Hi Dale! Bring snacks, e.g. chips, for the trip.', 'tl', false).split('\n')[0], 'Hi Dale! Bring snacks, e.g. chips, for the trip po.');
});

Deno.test('s73 R2-4: a sign-off in another case, dashed, or on one line is replaced, never doubled', () => {
  const body = 'Hi Emma! Thank you for your message.';
  for (const tail of ['Marifel & the Cascade Team\nHotel comfort, home warmth.', '- Marifel', 'Marifel & The Cascade Team Hotel Comfort. Home Warmth.', '— Marifel & The Cascade Team\nHotel Comfort. Home Warmth'])
    assertEquals(airbnbFinish(`${body}\n\n${tail}`, 'en', false), `${body}\n\n${SIGN}`, tail);
});

Deno.test('s73 R2-5: "wrong" alone is not a calm moment; our mistake and the aircon still are', () => {
  assertEquals(calmMoment('Is there anything wrong with arriving at 3?', 'routine'), false);
  assertEquals(calmMoment('We took a wrong turn, we are lost', 'routine'), false);
  assertEquals(calmMoment('I think there was a mistake with the reminder', 'routine'), true);
  assertEquals(calmMoment('Something went wrong with the door', 'routine'), true);
  assertEquals(calmMoment("The aircon stopped working, it's so hot", 'routine'), true);
});

Deno.test('s73 R2-6: the Airbnb prompt says Airbnb, not Messenger, and keeps no example question without its answer', () => {
  const p = draftSystem(SEED_CARD, true, false).split('You are drafting for the HOST')[0];
  assert(!/facebook|on messenger/i.test(p)); // "Messenger or Airbnb chat" in the native-language tests may stay
  assertStringIncludes(p, 'replying on Airbnb to guests');
  assert(!p.includes('Hm po per night?') && !p.includes('magkano po kung 3 nights?') && !p.includes('What if we need to cancel?'));
  assert(!/\bfee\b/i.test(p));
  const ls = p.split('\n');
  ls.forEach((l, i) => { if (/^Q:/.test(l)) assert(/^A:/.test(ls.slice(i + 1).find((x) => x.trim()) ?? ''), l); });
  assertStringIncludes(p, 'Q: Late check out 3pm?'); // a whole, clean example stays
});

Deno.test('s73 R3: an example that would lose ANY sentence goes whole - "How do I book?" is Messenger-only', () => {
  const air = draftSystem(SEED_CARD, true, false), msg = draftSystem(SEED_CARD, false);
  assert(!air.includes('Q: How do I book?') && !air.includes('A: Hi Mara.'));
  assertStringIncludes(msg, 'Q: How do I book?');
  assert(!air.includes('Q: Is there a parking?') && msg.includes('Q: Is there a parking?')); // its answer ends on the site link
  assertStringIncludes(air, 'Q: naa bay parking?');
});

// ---- s73 round 4 (Opus review of 034a509) ----
import { draftPlatform } from './draft.ts';

Deno.test('s73 R4-F1: only a positively Messenger source gets the Messenger brain; everything else is the Airbnb register', () => {
  assertEquals(draftPlatform('Can you give a discount for 5 nights?'), { platform: 'airbnb', text: 'Can you give a discount for 5 nights?', guessed: true });
  assertEquals(draftPlatform('Can you give a discount?', 'other').platform, 'airbnb');
  assertEquals(draftPlatform('Can you give a discount?', 'messenger'), { platform: 'messenger', text: 'Can you give a discount?', guessed: false });
  assertEquals(draftPlatform('messenger: Hi po, available ba Oct 3?'), { platform: 'messenger', text: 'Hi po, available ba Oct 3?', guessed: false });
  assertEquals(draftPlatform('airbnb: Hi po', 'messenger'), { platform: 'airbnb', text: 'Hi po', guessed: false });
  assertEquals(draftPlatform('messenger\nHi po, available?', 'other').platform, 'messenger'); // a photo caption marker
  assertEquals(draftPlatform('Airbnb says my booking is pending', 'messenger').platform, 'airbnb');
  assertEquals(draftRequest('reply messenger: Hi po').text, 'messenger: Hi po');
});

Deno.test('s73 R4-F2: bare percentages, nightly figures, k-amounts and unprefixed phones leak; "100% ready" does not', () => {
  for (const s of ['We give 10% for stays of 5 nights', 'it is 1600 nightly', 'about 1.6k a night', 'text 917 123 4567', 'text 639171234567'])
    assert(airbnbLeaks(WARM.replace('just send', `${s}, just send`)).includes('price') || airbnbLeaks(WARM.replace('just send', `${s}, just send`)).includes('off_platform'), s);
  for (const s of ['we are 100% ready', 'we are 100% sure', 'it is 100% safe', 'kept 100% clean'])
    assertEquals(airbnbLeaks(WARM.replace('just send', `${s}, just send`)), [], s);
  const p = draftSystem(SEED_CARD, true, false).split('You are drafting for the HOST')[0];
  for (const re of [/Quote one tier/, /standard figure/, /ONLY fares/, /full payment/]) assert(!re.test(p), String(re));
});

Deno.test('s73 R4-F3: no "po" inside St., Mr., P.M., and never "Thank you po so much"', () => {
  const first = (m: string) => airbnbFinish(m, 'tl', false).split('\n')[0];
  assertEquals(first('Hi Dale! St. Elizabeth Hospital is 10 minutes away. We hope you feel better.'), 'Hi Dale! St. Elizabeth Hospital is 10 minutes away po. We hope you feel better.');
  assertEquals(first('Hi Dale! Mr. Santos will meet you at the gate. See you soon.'), 'Hi Dale! Mr. Santos will meet you at the gate po. See you soon.');
  assertEquals(first('Hi Dale! Check-in is 2:00 P.M. Salamat for choosing us.'), 'Hi Dale! Check-in is 2:00 P.M. Salamat for choosing us po.');
  assertEquals(first('Hi Dale! Thank you so much for your message. We will check.'), 'Hi Dale! Thank you so much for your message po. We will check.');
  assertEquals(first('Hi Dale! Yes, there is parking.'), 'Hi Dale! Yes po, there is parking.');
});

Deno.test('s73 R4-F4: an English guest draft carries no "po", even when the model wrote some', () => {
  assert(!/\bpo\b/.test(airbnbFinish('Hi Emma! Yes po, there is parking po.', 'en', false)));
});

Deno.test('s73 R4-F5: Airbnb-internal wording passes; direct-deal, deposit and Google steering leak', () => {
  for (const s of ['message us in Airbnb messenger', 'see our page on Airbnb', 'book directly through the Airbnb app'])
    assertEquals(airbnbLeaks(WARM.replace('just send', `${s}, just send`)), [], s);
  for (const s of ['Contact us directly for a better deal', 'Reserve with us directly', 'Pay a deposit', 'Search Cascade Hideaway on Google'])
    assert(airbnbLeaks(WARM.replace('just send', `${s}, just send`)).length, s);
});

Deno.test('s73 R4-F6: valedictions and decorated sign-off lines above the real sign-off are removed', () => {
  const body = 'Hi Emma! Thank you for your message.';
  for (const tail of ['Warm regards,\nMarifel & The Cascade Team\nHotel Comfort. Home Warmth.', 'Marifel 🌿', 'Marifel & The Cascade Team 💚\nHotel Comfort. Home Warmth.', 'Best regards,\nMarifel'])
    assertEquals(airbnbFinish(`${body}\n\n${tail}`, 'en', false), `${body}\n\n${SIGN}`, tail);
});

// ---- s73 round 5 (Opus re-check of 0c783f5) ----
import { draftGuestReply } from './draft.ts';
const leakWith = (s: string) => airbnbLeaks(WARM.replace('just send', `${s}, just send`));

Deno.test('s73 R5-1: "deposit" leaks only next to pay/send/transfer/settle or a figure', () => {
  for (const s of ['you may deposit your luggage at the porch', 'Airbnb holds any security deposit']) assertEquals(leakWith(s), [], s);
  for (const s of ['Pay a deposit', 'send the deposit', 'a deposit of 1,000']) assert(leakWith(s).length, s);
});

Deno.test('s73 R5-2: "100%" and "% of guests/reviews" are not prices; a discount percentage still is', () => {
  for (const s of ['the unit is 100% sanitized', 'the EcoFlow is charged to 100%', '98% of guests rate it five stars', '95% of reviews mention the quiet']) assertEquals(leakWith(s), [], s);
  for (const s of ['10% off', 'We give 10% for 5 nights']) assert(leakWith(s).includes('price'), s);
});

Deno.test('s73 R5-3: a bare "messenger" marker with no guest text asks for the message and never calls a model', async () => {
  const db = new Proxy({}, { get: () => { throw new Error('db used'); } });
  for (const t of ['messenger', 'messenger:', '  airbnb:  ']) {
    const out = await draftGuestReply(db, t, null);
    assertEquals(out.length, 1, t);
    assertStringIncludes(out[0], 'paste the guest');
  }
});

Deno.test('s73 R5-4: direct offers, a bare rate figure and "directly ... text us" leak', () => {
  for (const s of ['Message me directly and I can lower it', 'Our rate drops to 1600', 'Book directly on Airbnb or text us', 'the price is 1500']) assert(leakWith(s).length, s);
  for (const s of ['book directly through the Airbnb app', 'see you in 2026', 'for 2 guests']) assertEquals(leakWith(s), [], s);
});
