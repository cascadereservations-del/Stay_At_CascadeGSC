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
