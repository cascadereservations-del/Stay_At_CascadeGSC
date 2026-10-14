// deno test supabase/functions/telegram-expense/T_nearmatch.test.ts - s83 lane T: near-miss notices, edited notices, the routing log line.
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { T_claimMessage, T_decide, T_logLine, T_nearNotice } from './T_nearmatch.ts';
import { B_noticeRoute, B_noticeSignal } from '../_shared/B_notice-signal.ts';
import { B_findDate, B_findTimes } from '../telegram-cassy/B_notice.ts';

// Frozen clock: 2026-10-14 09:00 Manila (01:00Z). Tomorrow = Oct 15.
const NOW = Date.parse('2026-10-14T01:00:00Z');
const ALLOWED = -1003798341977; // numeric, as Telegram sends it
const allowed = (id: unknown) => id === ALLOWED;
const msg = (text: string, extra: Record<string, unknown> = {}) => ({ message_id: 77, date: NOW / 1000, chat: { id: ALLOWED }, from: { id: 1, is_bot: false }, text, ...extra });
const upd = (text: string, extra: Record<string, unknown> = {}) => ({ update_id: 5, message: msg(text, extra) });

Deno.test('T: forgiving forms are read, not refused (colon, case, dash or to, 8am, today / tomorrow)', () => {
  const cases: Array<[string, string]> = [
    ['water notice 8am-5pm tomorrow', 'water notice: 8am-5pm Oct 15'],
    ['Water Notice - Oct 16 8:00 AM to 5:00 PM', 'water notice: Oct 16 8:00 AM to 5:00 PM'],
    ['WATER NOTICE Oct 16 8am to 5pm', 'water notice: Oct 16 8am to 5pm'],
    ['waternotice: Oct 16 8:00 AM - 5:00 PM', 'water notice: Oct 16 8:00 AM - 5:00 PM'],
    ['notice water: today 9am-12pm', 'water notice: Oct 14 9am-12pm'],
    ['noticewater: today 9am-12pm', 'water notice: Oct 14 9am-12pm'],
    ['Notice - water Oct 16 8am-5pm', 'water notice: Oct 16 8am-5pm'],
    ['wtaer notice Oct 16 8am-5pm', 'water notice: Oct 16 8am-5pm'],
    ['water notise: 10/16 8am-5pm', 'water notice: Oct 16 8am-5pm'],
    ['power notice tomorrow 1pm to 4pm', 'brownout notice: Oct 15 1pm to 4pm'],
    ['brownout notice tomorrow 1:00 PM-4:00 PM', 'brownout notice: Oct 15 1:00 PM-4:00 PM'],
    ['water notice Oct 16', 'water notice: Oct 16'], // water with a date and no time is an all-day card, as Cassy already does for the exact form
  ];
  for (const [input, want] of cases) {
    const r = T_nearNotice(input, NOW);
    assertEquals(r?.kind, 'forward', input);
    assertEquals((r as { text: string }).text, want, input);
    // the cleaned copy IS the exact form, and Cassy reads its date from it
    assert(B_noticeSignal((r as { text: string }).text), input);
  }
  const fwd = T_nearNotice('water notice 8am-5pm tomorrow', NOW) as { text: string };
  assertEquals(B_findDate(fwd.text, '2026-10-14'), '2026-10-15');
  assertEquals(B_findTimes(fwd.text)?.start, '08:00:00');
});

Deno.test('T: a notice that cannot be read gets one plain hint: what was understood, what is missing, one example', () => {
  const noDate = T_nearNotice('water notice 8am-5pm', NOW) as { kind: string; text: string };
  assertEquals(noDate.kind, 'hint');
  assertStringIncludes(noDate.text, 'I could not read that water notice.');
  assertStringIncludes(noDate.text, 'I found the times, 8:00 AM to 5:00 PM, but not the date.');
  assertStringIncludes(noDate.text, 'Send it like this: water notice: Oct 15 8:00 AM to 5:00 PM');
  const noTime = T_nearNotice('brownout notice Oct 20', NOW) as { text: string };
  assertStringIncludes(noTime.text, 'I found the date, Oct 20, but not the times.');
  assertStringIncludes(noTime.text, 'brownout notice: Oct 20 8:00 AM to 5:00 PM');
  const nothing = T_nearNotice('water notice', NOW) as { text: string };
  assertStringIncludes(nothing.text, 'I did not find a date or times.');
  for (const r of [noDate, noTime, nothing]) { assertFalse(r.text.includes('!')); assertFalse(/[a-z_]+=/.test(r.text), 'no key=value dumps'); }
});

Deno.test('T: real-looking OPS chatter stays silent (null, so the older paths decide)', () => {
  const quiet = [
    'sugar 20', 'restock 4 gallons of water', 'We need to refill the water tank tomorrow', 'good morning everyone', 'Thanks po!',
    'water 150', 'water bill 1,250 paid', 'no water in the shower of unit 2', 'did you see the notice on the gate?', 'brownout again yesterday around 3pm',
    'power bank charged', 'cleaning done 8am-12pm', '500 supplies', 'ok', '', 'wat', 'The water notice was posted by GSCWD',
    'cassy water notice tomorrow 8am-5pm', '/notices', '/brownout tomorrow 8am 4h SOCOTECO', 'Water interruption at San Isidro, see you later',
    // review F1 / F2: chatter that a loose fuzzy match turned into a card or a hint
    'Late notice po, hindi ako makakapunta bukas 8am', 'Nice water pressure today', 'Note later today 3pm-5pm meeting', 'Gate notice tomorrow 8am-5pm',
    'Noticed water leaking under the sink today', 'Notice water pressure low today', 'Water noticed today 8am-5pm', 'Notice power flickering tomorrow 8am-9am', 'Noticed brownout earlier 2pm-3pm', // re-audit R1
    'Meter notice from GSCWD tomorrow', 'Water note: tomorrow buy 2 gallons', 'Date notice', 'Paper notice', 'Voice water', 'Power nice', 'Nice water',
  ];
  for (const t of quiet) assertEquals(T_nearNotice(t, NOW), null, t);
  // the exact forms are the older route's and are not touched here
  for (const t of ['water notice: October 16, 8:00 AM to 5:00 PM', 'Brownout Notice: tomorrow', 'facebook.com/gscwaterdistrict/posts/1']) assertEquals(T_nearNotice(t, NOW), null, t);
});

Deno.test('F2: a hint needs something read (a date or times) or the literal command words', () => {
  for (const t of ['Power notice', 'Water Notice!', 'power notice thanks po']) assertEquals((T_nearNotice(t, NOW) as { kind: string }).kind, 'hint', t); // the literal command words get one hint
  for (const t of ['Date notice', 'Paper notice', 'Power nice', 'Nice water']) assertEquals(T_nearNotice(t, NOW), null, t);
  assertEquals((T_nearNotice('water notice', NOW) as { kind: string }).kind, 'hint');
  assertEquals((T_nearNotice('brownout notice please', NOW) as { kind: string }).kind, 'hint');
});

Deno.test('F7: the hint example date is tomorrow (Manila), not a fixed day', () => {
  assertStringIncludes((T_nearNotice('water notice 8am-5pm', NOW) as { text: string }).text, 'water notice: Oct 15 8:00 AM to 5:00 PM');
  const later = Date.parse('2026-12-31T08:00:00Z');
  assertStringIncludes((T_nearNotice('water notice 8am-5pm', later) as { text: string }).text, 'water notice: Jan 1 8:00 AM to 5:00 PM');
});

Deno.test('F8: today and tomorrow follow the Manila midnight', () => {
  const before = Date.parse('2026-10-14T15:59:00Z'), after = Date.parse('2026-10-14T16:01:00Z'); // 23:59 and 00:01 Manila
  assertEquals((T_nearNotice('water notice today 8am-5pm', before) as { text: string }).text, 'water notice: Oct 14 8am-5pm');
  assertEquals((T_nearNotice('water notice today 8am-5pm', after) as { text: string }).text, 'water notice: Oct 15 8am-5pm');
  assertEquals((T_nearNotice('water notice tomorrow 8am-5pm', before) as { text: string }).text, 'water notice: Oct 15 8am-5pm');
});

Deno.test('T: decisions over a table of updates; receipts, photos, commands and expense lines pass untouched', () => {
  const pass = [
    upd('sugar 20'), upd('good morning'), upd('/notices'), upd('/brownout tomorrow 8am 4h SOCOTECO'), upd('water notice: Oct 16 8am-5pm'),
    { update_id: 6, message: { ...msg(''), text: undefined, photo: [{ file_id: 'x' }], caption: 'water notice 8am-5pm tomorrow' } },
    { update_id: 7, callback_query: { id: 'c', data: 'llm_cancel:1', message: msg('x') } },
    upd('water notice 8am-5pm tomorrow', { reply_to_message: { from: { is_bot: true }, text: 'Amount?' } }),
    upd('water notice 8am-5pm tomorrow', { from: { id: 2, is_bot: true } }),
    { update_id: 8 },
  ];
  for (const u of pass) assertEquals(T_decide(u, allowed), { act: 'pass' }, JSON.stringify(Object.keys(u)));

  const hint = T_decide(upd('water notice 8am-5pm'), allowed);
  assertEquals(hint.act, 'reply');
  if (hint.act === 'reply') { assertEquals([hint.chatId, hint.replyTo], [ALLOWED, 77]); assertEquals(hint.log, { update_type: 'message', allowed: true, route: 'near_notice_hint', text_len: 20 }); }

  const fwd = T_decide(upd('water notice 8am-5pm tomorrow'), allowed);
  assertEquals(fwd.act, 'forward');
  if (fwd.act === 'forward') { assertEquals(fwd.update.message.text, 'water notice: 8am-5pm Oct 15'); assertEquals(fwd.update.update_id, 5); }

  const other = T_decide({ update_id: 9, message: { ...msg('water notice 8am-5pm'), chat: { id: 'other' } } }, allowed);
  assertEquals(other.act, 'ignore'); // a stranger's chat is never answered
});

Deno.test('T: edited_message acts on notices only, as a new message, never as an expense', () => {
  const edit = (text: string, extra: Record<string, unknown> = {}) => ({ update_id: 10, edited_message: { ...msg(text), edit_date: NOW / 1000 + 60, ...extra } });
  const a = T_decide(edit('water notice: Oct 16 8am-5pm'), allowed);
  assertEquals(a.act, 'forward');
  if (a.act === 'forward') { assertEquals(a.update.message.text, 'water notice: Oct 16 8am-5pm'); assertEquals(a.log.route, 'edit_notice'); assert(B_noticeRoute(a.update)); }
  const b = T_decide(edit('water notice tomorrow 8am to 5pm'), allowed);
  assertEquals(b.act, 'forward');
  if (b.act === 'forward') assertEquals(b.update.message.text, 'water notice: Oct 15 8am to 5pm');
  for (const t of ['sugar 20', '500 supplies', 'water notice 8am-5pm', 'good morning', '/log', 'water notice: x']) {
    const d = T_decide(edit(t), allowed);
    if (t === 'water notice: x') assertEquals(d.act, 'forward'); // the exact form: Cassy asks for the missing date itself
    else { assertEquals(d.act, 'ignore', t); if (d.act === 'ignore') assertEquals(d.log.route, 'edit_not_a_notice'); }
  }
  assertEquals(T_decide(edit('water notice: Oct 16 8am-5pm', { chat: { id: 'other' } }), allowed).act, 'ignore');
  assertEquals(T_decide(edit('water notice: Oct 16 8am-5pm', { from: { is_bot: true } }), allowed).act, 'ignore');
});

Deno.test('T: one notice per message id, edits included (the claim)', async () => {
  const seen = new Set<number>();
  const calls: Array<{ table: string; row: any }> = [];
  const db = { from: (table: string) => ({ upsert: (row: any) => { calls.push({ table, row }); const fresh = !seen.has(row.update_id); seen.add(row.update_id); return { select: () => Promise.resolve({ data: fresh ? [{ update_id: row.update_id }] : [], error: null }) }; } }) };
  const m = msg('water notice: Oct 16 8am-5pm');
  assertFalse(await T_claimMessage(db, m), 'first sight: go ahead');
  assert(await T_claimMessage(db, { ...m, text: 'water notice: Oct 16 9am-5pm' }), 'the edit of the same message id: already handled');
  assertFalse(await T_claimMessage(db, { ...m, message_id: 78 }), 'another message is its own notice');
  assertEquals(calls[0].table, 'telegram_processed_updates');
  assert(calls[0].row.update_id < 0, 'synthetic keys are negative, real update ids are positive');
  const failing = { from: () => ({ upsert: () => ({ select: () => Promise.resolve({ data: null, error: { message: 'x' } }) }) }) };
  assertFalse(await T_claimMessage(failing, m), 'a database error never blocks a notice');
});

Deno.test('T: the log line carries fields only, never the text, a name, a phone or an amount', () => {
  const secret = 'water notice 8am-5pm tomorrow call 0917 123 4567 Juan PHP 1,500';
  const d = T_decide({ update_id: 1, message: msg(secret, { from: { id: 9, first_name: 'Juan', is_bot: false } }) }, allowed);
  assert(d.act !== 'pass');
  const line = T_logLine((d as { log: any }).log);
  assertEquals(JSON.parse(line), { evt: 'ops_update_routed', update_type: 'message', allowed: true, route: 'near_notice_forwarded', text_len: secret.length });
  for (const bad of ['Juan', '0917', '1,500', 'water', '8am']) assertFalse(line.includes(bad), bad);
});

Deno.test('T: webhook registration lists edited_message (a source check; the setup call itself is never made here)', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, "allowed_updates:['message','edited_message','callback_query']");
  assertStringIncludes(src, "from './T_nearmatch.ts'");
});
