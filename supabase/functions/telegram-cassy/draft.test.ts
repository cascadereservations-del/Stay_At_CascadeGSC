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
