// Pins the meter-photo allowance. The rule it guards is Lloyd's: a cleaner may skip the meter photos
// once with a reason, never twice running. It shipped on the checklist on 2026-09-13 and the deployed
// function silently dropped the fields until 2026-09-18, so these assertions exist to make that
// impossible to repeat: if the codes or the consecutive check change, this fails.
import { assertEquals } from 'jsr:@std/assert@1';
import {
  meterReasons, parseMeterSkip,
  METER_BLOCKING_TYPES,
  meterBackwardsMessage, METER_WRONG_NUMBER_FLAGS,
} from './meter-skip.ts';

Deno.test('a skip counts only when declared AND carrying a reason', () => {
  assertEquals(parseMeterSkip(true, 'meter room locked').skipped, true);
  assertEquals(parseMeterSkip(true, '   ').skipped, false, 'blank note is not a reason');
  assertEquals(parseMeterSkip(true, 'ok').skipped, false, 'a two-character note is not a reason');
  assertEquals(parseMeterSkip(false, 'meter room locked').skipped, false, 'note without the flag');
  assertEquals(parseMeterSkip('true', 'meter room locked').skipped, false, 'the string "true" is not true');
  assertEquals(parseMeterSkip(true, undefined).skipped, false);
});

Deno.test('F4 a note of only punctuation is no reason', () => {
  assertEquals(parseMeterSkip(true, '....').skipped, false);
  assertEquals(parseMeterSkip(true, '!!! ???').skipped, false);
  assertEquals(parseMeterSkip(true, 'ab12').skipped, true);
  assertEquals(meterNoPhotoNotice('Honey', 'G', null, '...?').includes('Reason given: ...?.'), true, 'raw note when trimming empties it');
});

Deno.test('F5 a pending reading accepted out of order stores no deltas; otherwise they are kept', () => {
  assertEquals(keepDeltas('electric 4200 is lower', 'estimate_pending'), false);
  assertEquals(keepDeltas(null, 'estimate_pending'), true);
  assertEquals(keepDeltas('electric 4200 is lower', null), true);
  assertEquals(keepDeltas(null, null), true);
});

Deno.test('the note is trimmed and capped at 300 characters', () => {
  assertEquals(parseMeterSkip(true, '  locked  ').note, 'locked');
  assertEquals(parseMeterSkip(true, 'x'.repeat(400)).note.length, 300);
  assertEquals(parseMeterSkip(true, 42).note, '', 'a non-string note is no note');
});

Deno.test('two meter photos means no reason at all', () => {
  assertEquals(meterReasons(2, false, false), []);
  assertEquals(meterReasons(3, true, true), [], 'photos present beat any declaration');
});

Deno.test('a declared skip reads differently from photos simply missing', () => {
  assertEquals(meterReasons(0, false, false), ['meter_photos_0_of_2']);
  assertEquals(meterReasons(0, true, false), ['meter_photos_skipped_declared_0_of_2']);
  assertEquals(meterReasons(1, true, false), ['meter_photos_skipped_declared_1_of_2']);
});

Deno.test('never two in a row: the second consecutive declared skip is flagged', () => {
  assertEquals(meterReasons(0, true, true), [
    'meter_photos_skipped_declared_0_of_2',
    'meter_skip_consecutive_not_permitted',
  ]);
});

Deno.test('an undeclared shortfall after a skipped turnover is NOT a consecutive skip', () => {
  // Photos merely missing is not a claimed allowance, so it must not inherit the previous skip.
  assertEquals(meterReasons(0, false, true), ['meter_photos_0_of_2']);
});

Deno.test('a skip is always incomplete: it never returns an empty reason list', () => {
  for (const prev of [true, false]) {
    for (const count of [0, 1]) {
      const reasons = meterReasons(count, true, prev);
      assertEquals(reasons.length > 0, true, `count ${count}, previous ${prev}`);
    }
  }
});

// D-219 (Lloyd 2026-09-23): a backwards reading is refused, not nudged. The 2026-07-01 row re-typed the
// 2026-06-21 numbers (3003 -> 2931 kWh, 57.547 -> 56.598 m3) and nothing stopped it.
Deno.test('a reading below the last one is refused, naming the meter and the last number', () => {
  const m = meterBackwardsMessage(2931, 3003, 56.598, 57.547);
  assertEquals(typeof m, 'string');
  assertEquals(m!.includes('electric 2931 kWh is lower than the last reading (3003)'), true);
  assertEquals(m!.includes('water 56.598 m³ is lower than the last reading (57.547)'), true);
  assertEquals(m!.includes('message Lloyd'), true);
  assertEquals(meterBackwardsMessage(39.675, null, 39.675, 39.782)!.startsWith('The water 39.675'), true);
});

Deno.test('a forward, equal, missing or first reading is never refused', () => {
  assertEquals(meterBackwardsMessage(3163, 2931, 59.474, 56.598), null);
  assertEquals(meterBackwardsMessage(3003, 3003, 57.547, 57.547), null);   // same number is a nudge, not a block
  assertEquals(meterBackwardsMessage(null, 3003, null, 57.547), null);
  assertEquals(meterBackwardsMessage(NaN, 3003, NaN, 57.547), null);
  assertEquals(meterBackwardsMessage(1636, null, 36.871, null), null);
});

Deno.test('only flags that mean wrong numbers are skipped as the previous reading', () => {
  assertEquals([...METER_WRONG_NUMBER_FLAGS].sort(), ['duplicate', 'misread', 're_entry']);
  assertEquals(METER_WRONG_NUMBER_FLAGS.includes('first_reading'), false);
});

// ── D-352 "No meter photo was taken" ──────────────────────────────────────────
import { keepDeltas, skipRefusedFromV2, meterFlagForSkip, meterNoPhotoNotice, backwardsRefusal, pendingBetween } from './meter-skip.ts';
import { meterNeighbours, meterOrderMessage, type MeterRow } from '../_shared/meter-order.ts';

Deno.test('v2 answer: allowed false means refused; allowed true means allowed; anything odd means fall back', () => {
  assertEquals(skipRefusedFromV2({ allowed: false, reason: 'neighbour_skipped', neighbour_checkout: '2026-10-19' }), true);
  assertEquals(skipRefusedFromV2({ allowed: true, reason: null, neighbour_checkout: null }), false);
  assertEquals(skipRefusedFromV2(null), null);
  assertEquals(skipRefusedFromV2([]), null);
  assertEquals(skipRefusedFromV2({}), null);
  assertEquals(skipRefusedFromV2({ allowed: 'false' }), null, 'a string is not a verdict');
});

Deno.test('only a declared skip on a turnover or deep clean is written estimate_pending', () => {
  assertEquals(meterFlagForSkip(true, 'turnover'), 'estimate_pending');
  assertEquals(meterFlagForSkip(true, 'deep_clean'), 'estimate_pending');
  assertEquals(meterFlagForSkip(true, 'mid_stay'), null);
  assertEquals(meterFlagForSkip(true, 'emergency'), null);
  assertEquals(meterFlagForSkip(false, 'turnover'), null);
});

Deno.test('the Finance line says who, which stay, why, and what happens; no key=value, no amounts', () => {
  const t = meterNoPhotoNotice('Honey', 'Ysabel Trajico', '2026-10-21', 'Phone malfunction');
  assertEquals(t.split('\n')[0], 'Honey reports that no meter photo was taken for the stay of Ysabel Trajico (checked out Oct 21).');
  assertEquals(t.includes('Reason given: Phone malfunction.'), true);
  assertEquals(t.includes('kept until the next verified reading'), true);
  assertEquals(/=|!|\d{3,}/.test(t.replace('Oct 21', '')), false, t);
});

Deno.test('the Finance line copes with a missing guest, cleaner or date', () => {
  const t = meterNoPhotoNotice('—', '—', null, 'Phone malfunction');
  assertEquals(t.split('\n')[0], 'The cleaner reports that no meter photo was taken for the latest stay.');
});

Deno.test('index.ts wiring guard (D-352): v2 rpc with the check-out date, pending flag, no repoint, notice rpc', async () => {
  const src = (await Deno.readTextFile(new URL('./index.ts', import.meta.url))).replace(/\r\n/g, '\n');
  assertEquals(src.includes("rpc('can_skip_meter_photos_v2',\n          { p_property_id: propertyId, p_checkout_date: checkOutDate }"), true);
  assertEquals(src.includes("rpc('meter_no_photo_notice_v1', { p_session_id: sessionId }"), true);
  assertEquals(src.includes('...(meterFlag ? { meter_flag: meterFlag } : {})'), true);
  assertEquals(src.includes('if (!meterFlag) for (const { id, patch } of repointNext('), true);
  assertEquals(src.includes('!isMidStay && !meterFlag && !thisGap && (kwhPerNight'), true);
  assertEquals(/\.rpc\([^)]*\)[^;]*\.(catch|finally)\(/.test(src), false, 'supabase builders are thenable only');
});

const verified = (elec: number, co: string): MeterRow => ({
  id: 'v' + co, electric_curr: elec, water_curr: 100, recorded_at: co + 'T09:00:00+08:00',
  cleaning_sessions: { cleaning_type: 'turnover', checkout_date: co, nights_stayed: 1 },
});

Deno.test('W1 Ysabel: 4200 typed after a verified 4240 is refused with photos, accepted pending without', () => {
  const around = meterNeighbours([verified(4240, '2026-10-20')], '2026-10-27', true);
  const msg = meterOrderMessage(4200, null, around);
  assertEquals(typeof msg, 'string');
  assertEquals(backwardsRefusal(msg, null), msg, 'a photographed reading is still refused');
  assertEquals(backwardsRefusal(msg, meterFlagForSkip(true, 'turnover')), null, 'a declared skip is kept pending');
});

Deno.test('W2 the Finance line says Lloyd must decide when v2 refused the skip', () => {
  const t = meterNoPhotoNotice('Honey', 'Ysabel Trajico', '2026-10-21', 'Phone malfunction', true);
  assertEquals(t.includes('Nothing to do now'), false);
  assertEquals(t.includes('also has no meter photo'), true);
  assertEquals(t.includes('marked incomplete'), true);
  assertEquals(t.includes('Lloyd needs to decide'), true);
});

Deno.test('W5 the note loses trailing punctuation before the full stop', () => {
  assertEquals(meterNoPhotoNotice('Honey', 'G', null, 'Meter room locked!').includes('Reason given: Meter room locked.' + String.fromCharCode(10)), true);
  assertEquals(meterNoPhotoNotice('Honey', 'G', null, 'Locked...?').includes('Reason given: Locked.' + String.fromCharCode(10)), true);
});

Deno.test('W3 a pending row between the verified neighbour and this stay skips the anomaly alert', () => {
  const pending: MeterRow = { ...verified(4300, '2026-10-22'), id: 'p', meter_flag: 'estimate_pending' };
  const rows = [verified(4240, '2026-10-20'), pending];
  assertEquals(pendingBetween(rows, '2026-10-20', '2026-10-25'), true);
  assertEquals(pendingBetween(rows, '2026-10-22', '2026-10-25'), false, 'pending on the boundary is not between');
  assertEquals(pendingBetween(rows, '2026-10-23', '2026-10-25'), false, 'pending before the neighbour');
  assertEquals(pendingBetween(rows, null, '2026-10-25'), false);
  assertEquals(pendingBetween([verified(4240, '2026-10-20')], '2026-10-19', '2026-10-25'), false, 'verified rows never gap');
});

Deno.test('W4/W6/W8 wiring guard: notice gated on meterWritten, finance send not awaited, duplicate path re-asks', async () => {
  const src = (await Deno.readTextFile(new URL('./index.ts', import.meta.url))).replace(/\r\n/g, '\n');
  assertEquals(src.includes('if (meterPhotosSkipped && meterFlag && meterWritten) {'), true);
  assertEquals(/await tgPost\(TG_TOKEN, 'sendMessage', \{\s+chat_id: TG_FINANCE_ID, text: withHeader\('finance', 'no meter photo'/.test(src), false);
  assertEquals(src.includes('rt.waitUntil(sentP)'), true);
  assertEquals(src.includes('meter_backwards_accepted_pending'), true);
  assertEquals(src.includes('p_session_id: dupes[0].id'), true);
});

Deno.test('F2/F3/F5 wiring guard: Finance text from the reasons, dup path typed and checked, deltas nulled', async () => {
  const src = (await Deno.readTextFile(new URL('./index.ts', import.meta.url))).replace(/\r\n/g, '\n');
  assertEquals(src.includes("meterSkipNote, reasons.includes('meter_skip_consecutive_not_permitted'))"), true);
  assertEquals(src.includes("meter_photos_skipped, cleaning_type'"), true);
  assertEquals(src.includes('METER_BLOCKING_TYPES.has(String(dupes[0].cleaning_type))'), true);
  assertEquals(src.includes(".eq('session_id', dupes[0].id)"), true);
  assertEquals(src.includes('const { error: dupErr } = await supabase.rpc('), true);
  assertEquals(src.includes('electric_delta: kd ? deltaKwh : null'), true);
  assertEquals(src.includes('m3_per_night:   kd ? m3PerNight : null'), true);
});
