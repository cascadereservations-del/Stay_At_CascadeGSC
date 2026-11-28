// deno test supabase/functions/telegram-expense/block.test.ts - SPEC-41: the OPS blocked-date card's answers, refusals and follow-up prompts.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { blockNoted, blockRecorded, blockRefusal, STAFF_URL, BLOCK_BROWNOUT_PROMPT, BLOCK_OTHER_PROMPT, BLOCK_PROMPTS } from './block.ts';
import { refusal, routeText } from './reply.ts';

Deno.test('SPEC-41: after a tap the card ends "Recorded: <label>, by <name>."', () => {
  assertEquals(blockRecorded('brownout', 'Marifel'), 'Recorded: brownout, by Marifel.');
  assertEquals(blockRecorded('maint', 'Marifel'), 'Recorded: maintenance, by Marifel.');
  assertEquals(blockRecorded('owner', 'Marifel'), 'Recorded: owner use, by Marifel.');
  assertEquals(blockRecorded('other', 'Marifel'), 'Recorded: something else, by Marifel.');
  assertEquals(blockRecorded('direct', 'Lloyd', '2026-12-01'), `Recorded: Facebook / direct booking, by Lloyd. Log the guest: ${STAFF_URL}#calendar/2026-12-01?record=1`);
  assertEquals(blockRecorded('unblock', 'Lloyd'), 'Recorded: to be unblocked on Airbnb, by Lloyd.');
});

Deno.test('SPEC-41: the old refusal lines are kept; the buttons stay only for someone who may answer', () => {
  assertEquals(blockRefusal('not_pending', 'Ana'), { line: 'ℹ️ Already answered.', keep: false });
  assertEquals(blockRefusal('unmapped_telegram_user', 'Ana').keep, true);
  assertEquals(blockRefusal('unmapped_telegram_user', 'Ana').line.includes('ask Lloyd to map it'), true);
  assertEquals(blockRefusal('not_authorized', 'Ana').line, '⛔ Ana is not allowed to answer for the calendar.');
  assertEquals(blockRefusal('weird', 'Ana').line, '⚠️ weird');
});

Deno.test('SPEC-41: the follow-up prompts are the approved wording; only Brownout and Something else ask one', () => {
  assertEquals(BLOCK_BROWNOUT_PROMPT, '⚡ Which outage was it? Reply to this message with the day, start, hours and who announced it, like: 10-11 8am 8h NGCP. You may skip this; the date is already recorded as a brownout.');
  assertEquals(BLOCK_OTHER_PROMPT, '✏️ What is it? Reply to this message in a few words.');
  assertEquals(Object.keys(BLOCK_PROMPTS).sort(), ['brownout', 'other']);
  assertEquals(blockNoted('  Aircon repair  ', 'Ana'), 'Noted: Aircon repair. Thank you, Ana.');
  assert(!/!/.test(BLOCK_BROWNOUT_PROMPT + BLOCK_OTHER_PROMPT));
});

Deno.test('SPEC-41: block_brownout and block_other are flows: the person being asked is answered, and a misfit keeps the question open with its own wording', () => {
  for (const flow of ['block_brownout', 'block_other'] as const) {
    assertEquals(routeText({ awaiting: true, replyToCountCard: false, replyToBot: true, text: '10-11 8am 8h NGCP' }), { kind: 'flow' });
    assertEquals(refusal(flow).endsWith('Nothing saved yet.'), true, flow);
  }
  assertEquals(refusal('block_brownout').includes('10-11 8am 8h NGCP'), true);
  assertEquals(routeText({ awaiting: true, replyToCountCard: false, replyToBot: false, text: '/menu' }), { kind: 'passthrough' }, 'a command is never an answer');
});

Deno.test('blockRecorded direct carries the record deep link', () => {
  assertEquals(STAFF_URL, 'https://cascadereservations-del.github.io/Cascade-Staff/');
  assertEquals(blockRecorded('direct', 'Lloyd', '2026-12-01'), 'Recorded: Facebook / direct booking, by Lloyd. Log the guest: https://cascadereservations-del.github.io/Cascade-Staff/#calendar/2026-12-01?record=1');
  // no date known (the handler does not pass one yet): the link still opens the calendar's record form
  assertEquals(blockRecorded('direct', 'Lloyd'), 'Recorded: Facebook / direct booking, by Lloyd. Log the guest: https://cascadereservations-del.github.io/Cascade-Staff/#calendar?record=1');
  assertEquals(blockRecorded('direct', 'Lloyd', 'not-a-date').includes('#calendar?record=1'), true);
  // every other answer is unchanged and carries no link
  assertEquals(blockRecorded('maint', 'Ana', '2026-12-01'), 'Recorded: maintenance, by Ana.');
});

Deno.test('cleaner tapping direct keeps the buttons', () => {
  // the RPC refuses a cleaner with not_authorized; the card keeps its buttons and says so, and no record link is offered
  const x = blockRefusal('not_authorized', 'Marifel');
  assertEquals(x, { line: '⛔ Marifel is not allowed to answer for the calendar.', keep: true });
  assertEquals(x.line.includes('record=1'), false);
});

Deno.test('index.ts passes the matched block check-in date to blockRecorded (record deep link)', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(/blockRecorded\(answer,\s*who,\s*[^)\s][^)]*\)/.test(src), 'blockRecorded needs a third (check-in) argument');
  assert(/select\('uid,\s*checkin_date'\)/.test(src), 'the block lookup must read checkin_date');
});
