// deno test supabase/functions/power-watch/poster.test.ts - filenames are the real ones from socoteco2.com, 2026-09-29.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { affectsUs, alertText, classifyFile, endOf, FEEDER_RE, isPowerPost, noticeFrom, OCR_PROMPT, posterUrls } from './poster.ts';

const U = 'https://www.socoteco2.com/wp-content/uploads/2026/09/';

Deno.test('the filename decides: our substation or feeder is a hit, another feeder or substation a miss, an area name is read', () => {
  assertEquals(classifyFile(U + 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg'), 'hit');     // Oct 8 2026: feeders 14-1..14-4
  assertEquals(classifyFile(U + 'SPI-09152026-PORTION-OF-F14-3.jpg'), 'hit');
  assertEquals(classifyFile(U + 'SPI-PMS-10032026-PENTAGON-SS.jpg'), 'miss');
  assertEquals(classifyFile(U + 'SPI-09252026-F13-3.jpg'), 'miss');
  assertEquals(classifyFile(U + 'SPI-09252026-PORTION-OF-F12-3.jpg'), 'miss');
  assertEquals(classifyFile(U + 'SPI-09152026-PORTION-OF-F14-1.jpg'), 'miss');     // a portion of 14-1 is not ours
  assertEquals(classifyFile(U + 'SPI-10022026-BATULAKI-GLAN.jpg'), 'read');
  assertEquals(classifyFile(U + 'SPI-PMS-10142026-MALAPATAN-SS.jpg'), 'miss');      // the date 1014 is not feeder 14
});

Deno.test('the feeder rule from the Apps Script still holds', () => {
  for (const [s, want] of [['PORTION OF F14-3', true], ['FEEDER 14 - 3', true], ['affected: 14-3, 14-4', true], ['F14-30 substation', false], ['114-3', false], ['F4-3', false]] as const)
    assertEquals(FEEDER_RE.test(s), want, s);
});

Deno.test('a post is an advisory by its title; posters are the full-size images, no logos', () => {
  assert(isPowerPost({ title: { rendered: 'NOTICE OF SCHEDULED POWER INTERRUPTIONS ON October 2, 2026' } }));
  assert(!isPowerPost({ title: { rendered: 'METER READING &#038; DISTRIBUTION OF BILLS' } }));
  const html = `<img src="${U}SPI-PMS-10082026-LEON-LLIDO-SS-300x300.jpg" srcset="${U}SPI-PMS-10082026-LEON-LLIDO-SS.jpg 1080w"><img src="${U}socoteco-logo.png">`;
  assertEquals(posterUrls(html), [U + 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg']);
});

Deno.test('Oct 8: a substation hit becomes an 11-hour notice from 06:00, and the alert leads with what happens', () => {
  const n = noticeFrom({ date: '2026-10-08', start: '06:00', end: '17:00', substation: 'Leon Llido Substation', feeders: ['14-1', '14-2', '14-3', '14-4'], purpose: 'Substation preventive maintenance service (PMS)', kind: 'SCHEDULED' }, true, U + 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg');
  assert(n);
  assertEquals([n!.date, n!.time, n!.hours], ['2026-10-08', '06:00:00', 11]);
  const a = alertText(n!);
  assertEquals(a.subject, 'Brownout at Cascade: Thu 8 Oct, 6:00 AM to 5:00 PM (11 h)');
  assert(a.body.startsWith('Power will be off at the residence on Thu 8 Oct, 6:00 AM to 5:00 PM (11 h).'));
  assert(!/!/.test(a.body));
});

Deno.test('an area poster is ours only when it names our feeder, substation or area; the date falls back to the filename', () => {
  assert(!affectsUs({ areas: ['Batulaki', 'Glan'] }, false));
  assert(affectsUs({ areas: ['Brgy. San Isidro', 'Lagao'] }, false));
  assert(affectsUs({ feeders: ['14-3'] }, false));
  assert(affectsUs({ areas: ['Portion of Katangawan'] }, false));
  assertEquals(noticeFrom({ areas: ['Batulaki'] }, false, U + 'SPI-10022026-BATULAKI-GLAN.jpg'), null);
  assertEquals(noticeFrom({ areas: ['All areas'] }, false, U + 'SPI-10022026-X.jpg')?.date, '2026-10-02');
});

Deno.test("D-290: a cancelled or moved poster is read as such; the prompt carries the rescheduled and cancelled wording", () => {
  const f = U + "SPI-PMS-10082026-LEON-LLIDO-SS.jpg";
  assertEquals(noticeFrom({ date: "2026-10-08", status: "CANCELLED", substation: "Leon Llido" }, true, f)?.status, "cancelled");
  assertEquals(noticeFrom({ date: "2026-10-08", status: "POSTPONED", substation: "Leon Llido" }, true, f)?.status, "cancelled");
  assertEquals(noticeFrom({ date: "2026-10-08", start: "06:00", end: "17:00", status: "ACTIVE" }, true, f)?.status, "active");
  assertEquals(noticeFrom({ date: "2026-10-08", start: "06:00", end: "17:00" }, true, f)?.status, "active", "a poster that says nothing is active");
  assertEquals(noticeFrom({ date: "2026-10-22", original_date: "2026-10-15", start: "06:00", end: "17:00" }, true, f)?.originalDate, "2026-10-15");
  assertEquals(noticeFrom({ date: "2026-10-22", original_date: "2026-10-22" }, true, f)?.originalDate, null);
  assertEquals(noticeFrom({ date: "2026-10-22", original_date: "soon" }, true, f)?.originalDate, null);
  assert(/Ignore any schedule marked RESCHEDULED, struck-through, or cancelled/.test(OCR_PROMPT));
  assert(/status/.test(OCR_PROMPT) && /original_date/.test(OCR_PROMPT));
});

Deno.test("endOf wraps past midnight and is null without a start or a length", () => {
  assertEquals(endOf("06:00:00", 11), "17:00");
  assertEquals(endOf("22:00:00", 4), "02:00");
  assertEquals(endOf(null, 4), null);
  assertEquals(endOf("06:00:00", null), null);
});

Deno.test("the e-mail tells that a guest in the house gets a draft, carries the nights line, and still starts with what happens", () => {
  const n = noticeFrom({ date: "2026-10-15", start: "06:00", end: "17:00", substation: "Leon Llido" }, true, U + "SPI-PMS-10152026-LEON-LLIDO-SS.jpg")!;
  const a = alertText(n, "Blocked on our booking site: nights of Oct 14 and Oct 15.");
  assert(a.body.startsWith("Power will be off at the residence on Thu 15 Oct, 6:00 AM to 5:00 PM (11 h)."));
  assert(a.body.includes("Blocked on our booking site: nights of Oct 14 and Oct 15."));
  assert(a.body.includes("A guest staying that night gets a heads-up draft in Telegram"));
  assert(!/!/.test(a.body));
});
