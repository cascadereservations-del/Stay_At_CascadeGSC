import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { agreedRead, decisionKey, usable } from './free-read.ts';
import { noticeFrom, type Ocr } from './poster.ts';

const URL_HIT = 'https://www.socoteco2.com/wp-content/uploads/2026/09/SPI-PMS-10082026-LEON-LLIDO-SS.jpg';
const URL_READ = 'https://www.socoteco2.com/wp-content/uploads/2023/03/SPI-09192026-PORTION-OF-KATANGAWAN.jpg';
const key = (url: string, hit: boolean) => (t: string) => usable<Ocr>(t, (o) => decisionKey(noticeFrom(o, hit, url)));
const PAID = '{"date":"2026-10-08","start":"06:00","hours":11}';
const paid = () => Promise.resolve(PAID);
const ok = (t: string) => () => Promise.resolve(t);

// The two replies the free models gave for the Oct 8 Leon Llido poster on 2026-10-03 (Mistral wraps its JSON in a fence).
const SCOUT = '{"date":"2026-10-08","start":"06:00","end":"17:00","hours":11,"substation":"LEON LLIDO SUBSTATION","feeders":["14-1","14-2","14-3","14-4"],"areas":null,"purpose":"TO CONDUCT SUBSTATION PREVENTIVE MAINTENANCE SERVICE (PMS).","kind":"SCHEDULED","status":"ACTIVE","original_date":null}';
const MISTRAL = '```json\n{ "date": "2026-10-08", "start": "06:00", "end": "17:00", "hours": 11, "substation": "LEON LLIDO SUBSTATION", "feeders": ["14-1", "14-2", "14-3", "14-4"], "areas": null, "purpose": "TO CONDUCT SUBSTATION PREVENTIVE MAINTENANCE SERVICE (PMS)", "kind": "SCHEDULED", "status": "ACTIVE", "original_date": null }\n```';

Deno.test('two free reads with the same decision are used, wording differences ignored', async () => {
  const r = await agreedRead([ok(SCOUT), ok(MISTRAL)], key(URL_HIT, true), paid);
  assertEquals(r.via, 'free');
  assertEquals(r.text, SCOUT);
});

Deno.test('a different start time goes to the paid reader', async () => {
  const r = await agreedRead([ok(SCOUT), ok(SCOUT.replace('"start":"06:00"', '"start":"08:00"'))], key(URL_HIT, true), paid);
  assertEquals([r.via, r.why, r.text], ['paid', 'free_disagree', PAID]);
});

Deno.test('a cancelled read against an active read goes to the paid reader', async () => {
  const r = await agreedRead([ok(SCOUT), ok(SCOUT.replace('"ACTIVE"', '"CANCELLED"'))], key(URL_HIT, true), paid);
  assertEquals(r.via, 'paid');
});

Deno.test('ours against not ours goes to the paid reader', async () => {
  const notOurs = '{"date":"2026-09-19","start":"08:00","hours":6,"substation":null,"feeders":["7-2"],"areas":["Prk. 9"]}';
  const ours = '{"date":"2026-09-19","start":"08:00","hours":6,"substation":null,"feeders":["7-2"],"areas":["Portion of Brgy. Katangawan, GSC"]}';
  const r = await agreedRead([ok(notOurs), ok(ours)], key(URL_READ, false), paid);
  assertEquals(r.via, 'paid');
});

Deno.test('two unreadable or dateless reads never agree on "not ours"', async () => {
  assertEquals((await agreedRead([ok('{}'), ok('{}')], key(URL_READ, false), paid)).why, 'free_unusable');
  assertEquals((await agreedRead([ok('sorry'), ok('')], key(URL_READ, false), paid)).why, 'free_unusable');
});

Deno.test('a failed free call goes to the paid reader', async () => {
  const r = await agreedRead([ok(SCOUT), () => Promise.reject(new Error('omniroute_vision_429'))], key(URL_HIT, true), paid);
  assertEquals([r.via, r.why], ['paid', 'free_unusable']);
});

Deno.test('fewer than two free readers (OmniRoute not configured) is the paid reader', async () => {
  assertEquals((await agreedRead([], key(URL_HIT, true), paid)).why, 'free_off');
  assertEquals((await agreedRead([ok(SCOUT)], key(URL_HIT, true), paid)).why, 'free_off');
});

Deno.test('two free reads that agree it is not ours are used', async () => {
  const other = '{"date":"2026-09-25","start":"13:00","hours":4,"substation":null,"feeders":["12-3"],"areas":["Santiago Village"]}';
  const r = await agreedRead([ok(other), ok('```json ' + other + ' ```')], key('https://x/SPI-09252026-PORTION-OF-F12-3-AREA.jpg', false), paid);
  assertEquals(r.via, 'free');
  assertEquals(noticeFrom(JSON.parse(other), false, 'x'), null);
});
