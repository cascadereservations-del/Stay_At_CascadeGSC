import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { confirmationCodeFrom, parseIcal } from './ical.ts';
import { blockCardText, blocksOverdue, blocksToAsk, type CalRow } from './blocks.ts';

// The real Airbnb shape: CRLF lines folded at 75 octets, continuation after one space.
const FOLDED = [
  'BEGIN:VCALENDAR',
  'BEGIN:VEVENT',
  'DTEND;VALUE=DATE:20260927',
  'DTSTART;VALUE=DATE:20260925',
  'UID:1418fb94e984-650157fb4b2f84bc7563583d14e1c07d@airbnb.com',
  'DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/de',
  ' tails/HM8F54BR45\\nPhone Number (Last 4 Digits): 1234',
  'SUMMARY:Reserved',
  'END:VEVENT',
  'BEGIN:VEVENT',
  'DTEND;VALUE=DATE:20261009',
  'DTSTART;VALUE=DATE:20261007',
  'UID:1418fb94e984-1c74dc593a3135bfdb8@airbnb.com',
  'SUMMARY:Airbnb (Not available)',
  'END:VEVENT',
  'END:VCALENDAR',
].join('\r\n');

Deno.test('SPEC-24: a folded DESCRIPTION unfolds to the full URL and its confirmation code', () => {
  const [stay, block] = parseIcal(FOLDED);
  assertEquals(stay.description, 'Reservation URL: https://www.airbnb.com/hosting/reservations/details/HM8F54BR45\\nPhone Number (Last 4 Digits): 1234');
  assertEquals(confirmationCodeFrom(stay.description), 'HM8F54BR45');
  assertEquals([stay.checkin, stay.checkout, stay.status], ['2026-09-25', '2026-09-27', 'confirmed']);
  assertEquals([block.status, block.description], ['blocked', undefined]);
});

Deno.test('SPEC-24: an already-unfolded feed (LF, no fold) parses the same', () => {
  const [stay] = parseIcal(FOLDED.replace('reservations/de\r\n tails/', 'reservations/details/').replace(/\r\n/g, '\n'));
  assertEquals(confirmationCodeFrom(stay.description), 'HM8F54BR45');
});

Deno.test('SPEC-24: only a real 10-character upper-case code counts', () => {
  assertEquals(confirmationCodeFrom(undefined), null);
  assertEquals(confirmationCodeFrom('Reservation URL: https://www.airbnb.com/hosting/reservations/de'), null);
  assertEquals(confirmationCodeFrom('.../reservations/details/hm8f54br45'), null);
  assertEquals(confirmationCodeFrom('.../reservations/details/HM8F54BR4'), null);
});

const row = (o: Partial<CalRow>): CalRow => ({
  uid: 'b1', source: 'airbnb', status: 'blocked', checkin_date: '2026-10-07', checkout_date: '2026-10-09',
  recon_status: 'pending', recon_alerted_at: null, raw_description: null, ...o,
});

Deno.test('D-236: an unexplained future block is asked about once', () => {
  assertEquals(blocksToAsk([row({})], '2026-09-25', '2027-09-22').map((r) => r.uid), ['b1']);
  assertEquals(blocksToAsk([row({ recon_alerted_at: '2026-09-25T00:00:00Z' })], '2026-09-25', null), [], 'already asked');
  assertEquals(blocksToAsk([row({ recon_status: 'admin_block' })], '2026-09-25', null), [], 'already answered');
  assertEquals(blocksToAsk([row({ checkout_date: '2026-09-25' })], '2026-09-25', null), [], 'no night ahead');
  assertEquals(blocksToAsk([row({ checkin_date: '2027-09-23', checkout_date: '2027-09-24' })], '2026-09-25', '2027-09-23'), [], 'horizon tail');
});

Deno.test('D-236: a block covered by a direct booking or an Airbnb stay is not asked', () => {
  const direct = row({ uid: 'direct:x', source: 'direct', status: 'blocked', checkin_date: '2026-10-08', checkout_date: '2026-10-10' });
  assertEquals(blocksToAsk([row({}), direct], '2026-09-25', null), []);
  const cancelled = { ...direct, status: 'cancelled' };
  assertEquals(blocksToAsk([row({}), cancelled], '2026-09-25', null).length, 1, 'a cancelled direct row explains nothing');
  const touching = row({ uid: 'a', status: 'confirmed', checkin_date: '2026-10-09', checkout_date: '2026-10-10' });
  assertEquals(blocksToAsk([row({}), touching], '2026-09-25', null).length, 1, 'a stay starting on the checkout day does not overlap');
});

Deno.test('D-236: at most five per run, oldest first', () => {
  const many = Array.from({ length: 7 }, (_, i) => row({ uid: `b${i}`, checkin_date: `2026-11-1${i}`, checkout_date: `2026-11-1${i + 1}` })).reverse();
  assertEquals(blocksToAsk(many, '2026-09-25', null).map((r) => r.uid), ['b0', 'b1', 'b2', 'b3', 'b4']);
});

Deno.test('D-236: a question unanswered for seven days becomes a task; a fresh one does not', () => {
  const now = new Date('2026-10-03T00:00:00Z');
  assertEquals(blocksOverdue([row({ recon_alerted_at: '2026-09-25T00:00:00Z' })], '2026-10-03', now).length, 1);
  assertEquals(blocksOverdue([row({ recon_alerted_at: '2026-09-30T00:00:00Z' })], '2026-10-03', now).length, 0);
  assertEquals(blocksOverdue([row({ recon_alerted_at: '2026-09-25T00:00:00Z', recon_status: 'skipped' })], '2026-10-03', now).length, 0);
});

Deno.test('D-236: the card names the dates in words and quotes a note when there is one', () => {
  const t = blockCardText(row({ checkin_date: '2026-09-30', checkout_date: '2026-10-02' }));
  assertEquals(t.includes('Sep 30 to Oct 2 is blocked on Airbnb and Cascade has no booking for it. What is it?'), true, t);
  assertEquals(t.includes("Airbnb's note"), false);
  assertEquals(blockCardText(row({ raw_description: 'Aircon repair' })).includes('Airbnb\'s note: "Aircon repair"'), true);
});
