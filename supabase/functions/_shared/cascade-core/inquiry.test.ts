// SPEC-38 (session 70): the pure parts of the Telegram inquiry decisions. Synthetic data only.
// deno test --no-check --allow-env _shared/cascade-core/inquiry.test.ts   (run from supabase/functions)
import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { lintReply, toneRules } from '../../messenger-concierge/voice.ts';
import { hasMoney } from '../ops-money.ts';
import {
  channelPlan, DECLINE_CODES, declineKeyboard, declineLine, declinePreviewKeyboard, draftKeyboard, financeCard, firstName, fmtClock, fmtUntil, guestTextSince,
  heldLine, holdPreviewKeyboard, inquiryKeyboard, IQ, joinMessage, lastGuestAt, opsCard, parseIqTap, pesoOrNull, siteNotes, staleReason, viaOf, type DeclineCode,
  type InquiryView, type Lang,
} from './inquiry.ts';

const ID = '00a49c5e-1111-4222-8333-444455556666';
const view = (o: Partial<InquiryView> = {}): InquiryView => ({
  id: ID, ref: '00A49C5E', guest_name: 'Ana Cruz', guest_email: 'ana@example.com', guest_phone: '0917 123 4567',
  checkin_date: '2026-11-30', checkout_date: '2026-12-04', nights: 4, pax: 2, total_amount: 12400, deposit_amount: 6200,
  notes: 'via Messenger (psid 123)', submitted_at: '2026-10-04T14:40:00Z', status: 'pending', has_receipt: false,
  hold_expires_at: null, held_by: null, held_at: null, conflict: false, ...o,
});
const LANGS: Lang[] = ['en', 'tl', 'bis'];
const UNTIL = '2026-10-06T14:40:00Z'; // Tue 6 Oct, 10:40 pm Manila

Deno.test('every held and decline line passes lintReply and toneRules in all three registers, names the dates, has no "!"', () => {
  for (const lang of LANGS) {
    const lines: Array<[string, string | null]> = [['held-fee', heldLine(view(), lang, UNTIL)], ['held-full', heldLine(view({ deposit_amount: 12400 }), lang, UNTIL)]];
    for (const c of DECLINE_CODES) lines.push([c, declineLine(c, view(), lang)]);
    for (const [k, line] of lines) {
      if (line === null) continue;
      assertEquals(lintReply(line), [], `${lang} ${k} lint`);
      assertEquals(toneRules(line, lang), [], `${lang} ${k} tone`);
      assertStringIncludes(line, 'Nov 30 to Dec 4', `${lang} ${k} dates`);
      assert(!line.includes('!'), `${lang} ${k} has "!"`);
      assert(line.startsWith('Ana, '), `${lang} ${k} starts with the first name`);
    }
  }
});

Deno.test('held: carries the stored due figure exactly once and no other peso figure; fee vs full wording', () => {
  for (const lang of LANGS) {
    const fee = heldLine(view(), lang, UNTIL);
    assertEquals(fee.match(/₱/g)?.length, 1, lang);
    assertStringIncludes(fee, '₱6,200 reservation fee');
    assert(!fee.includes('12,400'));
    const full = heldLine(view({ deposit_amount: 12400 }), lang, UNTIL);
    assertStringIncludes(full, '₱12,400 full payment');
    assertEquals(full.match(/₱/g)?.length, 1);
    assertStringIncludes(fee, 'Tue 6 Oct, 10:40 pm');
  }
  // unknown is null, never 0: no amount at all rather than a made-up one
  const none = heldLine(view({ deposit_amount: null }), 'en', UNTIL);
  assert(!none.includes('₱'));
  assertStringIncludes(none, 'The payment secures the stay');
});

Deno.test('declineLine: dup is no message, other is Cassy\'s; guests carries the capacity disclosure', () => {
  assertEquals(declineLine('dup', view(), 'en'), null);
  assertEquals(declineLine('other', view(), 'en'), null);
  assertStringIncludes(declineLine('guests', view({ pax: 5 }), 'en')!, 'most comfortable for up to 3 adults');
  assertStringIncludes(declineLine('guests', view({ pax: 5 }), 'en')!, 'party of 5');
  assert(!declineLine('guests', view({ pax: null }), 'en')!.includes('party of'));
  assert(!/\bpo\b/i.test(declineLine('taken', view(), 'bis')!));
});

Deno.test('opsCard: no money, phone or e-mail; first body line starts with the first name and "asked for"; last line is the ref', () => {
  const t = opsCard(view(), { lastMessage: 'pwede po early check-in?' });
  assert(!t.includes('₱') && !/PHP/i.test(t), 'no money');
  assert(!t.includes('0917') && !t.includes('ana@example.com'), 'no phone or e-mail');
  assert(!hasMoney(t));
  const lines = t.split('\n').filter((l) => l.trim());
  assert(lines[1].startsWith('Ana asked for '), lines[1]);
  assert(!lines[1].includes('Cruz'), 'first name only');
  assertEquals(lines[lines.length - 1], '🔖 Ref 00A49C5E');
  assertStringIncludes(t, 'pwede po early check-in?');
  // a message that carries an amount is masked as a second guard
  assert(!opsCard(view(), { lastMessage: 'can we pay ₱5,000 now?' }).includes('5,000'));
});

Deno.test('financeCard: money, contact, timer and the no-timer line; the rate card line only when it moved', () => {
  const t = financeCard(view(), { lastMessage: 'is early check-in possible?', rateToday: 12800, context: ['🔁 Returning guest'] });
  assertStringIncludes(t, 'Request from Ana Cruz · not paid yet');
  assertStringIncludes(t, 'Mon 30 Nov to Fri 4 Dec (4 nights, 2 guests) through Messenger.');
  assertStringIncludes(t, '💰 Total ₱12,400 · reservation fee ₱6,200 due now');
  assertStringIncludes(t, 'no timer');
  assertStringIncludes(t, 'Rate card today ₱12,800. The guest keeps the ₱12,400 quoted.');
  assertStringIncludes(t, '0917 123 4567 · ana@example.com');
  assertStringIncludes(t, '🔁 Returning guest');
  assert(t.trimEnd().endsWith(ID));
  assert(!financeCard(view(), { rateToday: 12400 }).includes('Rate card today'), 'unchanged rate: no line');
  assert(!financeCard(view(), { rateToday: null }).includes('Rate card today'));
  assertStringIncludes(financeCard(view({ hold_expires_at: UNTIL })), '🗓️ Held until Tue 6 Oct, 10:40 pm; released if no receipt arrives');
  assertStringIncludes(financeCard(view({ deposit_amount: 12400 })), 'full payment ₱12,400 due now');
  assertStringIncludes(financeCard(view(), {}), 'Nothing from the guest to answer yet.');
  // unknown money is dropped, never printed as 0
  assert(!financeCard(view({ total_amount: null, deposit_amount: null })).includes('₱'));
});

Deno.test('keyboards: Finance has hold / dec / draft, OPS only draft, no message means no draft button; every callback ≤ 64 bytes', () => {
  const fin = inquiryKeyboard(view(), 'finance', { hasMessage: true }).flat().map((b) => b.callback_data!);
  assertEquals(fin, [IQ.hold(ID), IQ.dec(ID), IQ.draft(ID)]);
  const ops = inquiryKeyboard(view(), 'ops', { hasMessage: true }).flat().map((b) => b.callback_data!);
  assertEquals(ops, [IQ.draft(ID)]);
  assertEquals(inquiryKeyboard(view(), 'ops', { hasMessage: false }), []);
  assertEquals(inquiryKeyboard(view(), 'finance', { hasMessage: false }).flat().map((b) => b.callback_data!), [IQ.hold(ID), IQ.dec(ID)]);
  assertEquals(inquiryKeyboard(view(), 'finance', { hasMessage: true, state: 'held' }).flat().map((b) => b.callback_data!), [IQ.dec(ID), IQ.draft(ID)]);
  const all = [
    ...inquiryKeyboard(view(), 'finance', { hasMessage: true }), ...holdPreviewKeyboard(ID), ...declineKeyboard(ID),
    ...DECLINE_CODES.flatMap((c) => declinePreviewKeyboard(c, ID)),
    ...draftKeyboard({ purpose: 'reply', pid: ID, bookingId: ID, first: 'Ana', sendOk: true }), ...draftKeyboard({ purpose: 'decline', pid: ID, bookingId: ID, first: 'Ana', sendOk: true }),
    ...draftKeyboard({ purpose: 'reply', pid: ID, bookingId: ID, first: 'Ana', sendOk: false }), ...draftKeyboard({ purpose: 'decline', pid: ID, bookingId: ID, first: 'Ana', sendOk: false }),
  ].flat();
  for (const b of all) assert(new TextEncoder().encode(b.callback_data!).length <= 64, b.callback_data);
  // a failed voice check removes Send
  const off = draftKeyboard({ purpose: 'reply', pid: ID, bookingId: ID, first: 'Ana', sendOk: false }).flat().map((b) => b.callback_data!);
  assert(!off.some((d) => d.startsWith('iq:send:')));
  assertEquals(off, [IQ.draft(ID)]);
  assertEquals(declineKeyboard(ID).flat().length, 7);
});

Deno.test('parseIqTap round-trips every form; malformed or non-uuid input is null', () => {
  for (const kind of ['hold', 'holdok', 'dec', 'draft', 'back'] as const) assertEquals(parseIqTap(`iq:${kind}:${ID}`), { kind, id: ID });
  for (const kind of ['send', 'drop'] as const) assertEquals(parseIqTap(`iq:${kind}:${ID}`), { kind, id: ID });
  for (const code of DECLINE_CODES) {
    assertEquals(parseIqTap(IQ.dr(code as DeclineCode, ID)), { kind: 'dr', code, id: ID });
    assertEquals(parseIqTap(IQ.dx(code as DeclineCode, ID)), { kind: 'dx', code, id: ID });
  }
  for (const bad of ['', 'iq:', 'iq:hold', 'iq:hold:nope', 'iq:hold:' + ID + ':x', 'iq:zzz:' + ID, 'iq:dr:taken', 'iq:dr:nope:' + ID, 'inv:ok:' + ID, 'iq:hold:' + ID.slice(1)]) assertEquals(parseIqTap(bad), null, bad);
  assertEquals(parseIqTap(undefined), null);
});

Deno.test('channelPlan: 2 h messenger, 30 h human-agent, 8 d with e-mail, 8 d without, no thread', () => {
  const now = Date.parse('2026-10-05T12:00:00Z'), ago = (h: number) => new Date(now - h * 3_600_000).toISOString();
  assertEquals(channelPlan({ hasThread: true, lastGuestAt: ago(2), hasEmail: false, now }), { channel: 'messenger', humanAgent: false });
  assertEquals(channelPlan({ hasThread: true, lastGuestAt: ago(30), hasEmail: true, now }), { channel: 'messenger', humanAgent: true });
  assertEquals(channelPlan({ hasThread: true, lastGuestAt: ago(8 * 24), hasEmail: true, now }), { channel: 'email', humanAgent: false });
  assertEquals(channelPlan({ hasThread: true, lastGuestAt: ago(8 * 24), hasEmail: false, now }), { channel: 'card_only', humanAgent: false });
  assertEquals(channelPlan({ hasThread: false, lastGuestAt: null, hasEmail: true, now }), { channel: 'email', humanAgent: false });
  assertEquals(channelPlan({ hasThread: false, lastGuestAt: null, hasEmail: false, now }), { channel: 'card_only', humanAgent: false });
  assertEquals(channelPlan({ hasThread: true, lastGuestAt: null, hasEmail: true, now }), { channel: 'email', humanAgent: false });
});

Deno.test('guestTextSince keeps only guest turns after submitted_at, at most 3, each cut to 160; siteNotes drops the Messenger marker', () => {
  const h = [
    { role: 'guest', text: 'old question', at: '2026-10-04T10:00:00Z' },
    { role: 'guest', text: 'one', at: '2026-10-04T15:00:00Z' }, { role: 'bot', text: 'bot answer', at: '2026-10-04T15:01:00Z' },
    { role: 'guest', text: 'two', at: '2026-10-04T15:02:00Z' }, { role: 'guest', text: 'three', at: '2026-10-04T15:03:00Z' },
    { role: 'guest', text: 'x'.repeat(300), at: '2026-10-04T15:04:00Z' },
  ];
  const out = guestTextSince(h, '2026-10-04T14:40:00Z');
  assertEquals(out.length, 3);
  assertEquals(out.slice(0, 2), ['two', 'three']);
  assert(out[2].length <= 160 && out[2].endsWith('…'));
  assertEquals(guestTextSince([], '2026-10-04T14:40:00Z'), []);
  assertEquals(guestTextSince(null, null), []);
  assertEquals(joinMessage(['a', 'b']), 'a / b');
  assertEquals(joinMessage([]), null);
  assertEquals(lastGuestAt(h), '2026-10-04T15:04:00Z');
  assertEquals(siteNotes('via Messenger (psid 123456)'), null);
  assertEquals(siteNotes('Is early check-in possible? via Messenger (psid 99)'), 'Is early check-in possible?');
  assertEquals(siteNotes(null), null);
  assertEquals(viaOf('via Messenger (psid 1)'), 'Messenger');
  assertEquals(viaOf('hello'), 'the site');
});

Deno.test('formatters and stale reasons', () => {
  assertEquals(fmtUntil(UNTIL), 'Tue 6 Oct, 10:40 pm');
  assertEquals(fmtClock('2026-10-05T01:15:00Z'), '9:15 am');
  assertEquals(fmtUntil('nope'), '');
  assertEquals(firstName('  Ana Cruz '), 'Ana');
  assertEquals(pesoOrNull(0), '₱0');
  assertEquals(pesoOrNull(null), null);
  assertEquals(pesoOrNull(''), null);
  assertEquals(staleReason(view()), null);
  assertStringIncludes(staleReason(view({ status: 'cancelled' }))!, 'cancelled');
  assertStringIncludes(staleReason(view({ status: 'expired' }))!, 'expired');
  assertStringIncludes(staleReason(view({ has_receipt: true }))!, 'receipt card');
  assertStringIncludes(staleReason(null)!, 'no longer exists');
});

Deno.test('regression: the gate rejects an exclaiming reply that quotes an amount', () => {
  const bad = 'Wonderful, Ana! Send ₱890 now.';
  assert(lintReply(bad).length > 0);
  assert(toneRules(bad, 'en').length > 0);
  assert(hasMoney(bad));
});

import { quotesReason, replyContext } from './inquiry.ts';

Deno.test('replyContext: the trailing guest run since the request is "latest", the thread ahead of it is "before"', () => {
  const h = [
    { role: 'guest', text: 'old', at: '2026-10-04T10:00:00Z' }, { role: 'bot', text: 'hello', at: '2026-10-04T10:01:00Z' },
    { role: 'guest', text: 'book Nov 30', at: '2026-10-04T14:30:00Z' }, { role: 'bot', text: 'paid yet?', at: '2026-10-04T14:41:00Z' },
    { role: 'guest', text: 'pwede po early check-in?', at: '2026-10-04T15:00:00Z' }, { role: 'guest', text: 'and parking?', at: '2026-10-04T15:01:00Z' },
  ];
  const c = replyContext(h, '2026-10-04T14:40:00Z');
  assertEquals(c.latest, ['pwede po early check-in?', 'and parking?']);
  assertEquals(c.before.length, 4);
  // the host already answered: the newest guest words since the request are still shown, nothing is invented
  const answered = replyContext([...h, { role: 'bot', text: 'yes', at: '2026-10-04T15:05:00Z' }], '2026-10-04T14:40:00Z');
  assertEquals(answered.latest, ['pwede po early check-in?', 'and parking?']);
  assertEquals(replyContext([{ role: 'bot', text: 'hi', at: '2026-10-04T15:00:00Z' }], '2026-10-04T14:40:00Z').latest, []);
  assertEquals(replyContext(null, null), { before: [], latest: [] });
});

Deno.test('quotesReason: five words in a row (or the whole short reason) repeated is a quote; a paraphrase is not', () => {
  assertEquals(quotesReason('Sorry, the guest asked for a party so we cannot.', 'guest asked for a party'), true);
  assertEquals(quotesReason('Sorry, we cannot host a party at the home.', 'guest asked for a party'), false);
  assertEquals(quotesReason('We are unable to take pets.', 'no pets allowed here ever again'), false);
  assertEquals(quotesReason('Sorry: no pets allowed here ever again.', 'No pets allowed here, ever again!'), true);
  assertEquals(quotesReason('anything', 'ok'), false);
  assertEquals(quotesReason('anything at all', ''), false);
});
