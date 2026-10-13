// deno test --allow-read supabase/functions/telegram-cassy/B_notice.test.ts - notice signals, routing, parsing, the card. Frozen clock, synthetic posts only.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { B_noticeRoute, B_noticeSignal } from '../_shared/B_notice-signal.ts';
import { B_askCard, B_findDate, B_findTimes, B_noticeCard, B_noticeFlow, B_readNotice } from './B_notice.ts';

const AT = Date.parse('2026-10-13T02:00:00Z'); // 10:00 Manila, 13 Oct 2026
const WATER = 'https://www.facebook.com/gscwaterdistrict/posts/pfbid0abc';
const POWER = 'https://www.facebook.com/socoteco2.EC/posts/123';

// ---- signals: only the explicit ones open the card ----
Deno.test('B signal: a GSCWD page link is a water signal, a SOCOTECO II page link is a brownout signal, the prefixes carry the pasted text', () => {
  assertEquals(B_noticeSignal(`Fwd ${WATER}`), { kind: 'water', via: 'link', body: 'Fwd' });
  assertEquals(B_noticeSignal('facebook.com/gscwaterdistrict'), { kind: 'water', via: 'link', body: '' });
  assertEquals(B_noticeSignal(`m.facebook.com/GSCWaterDistrict/posts/9 Oct 16 8am-5pm`)?.kind, 'water');
  assertEquals(B_noticeSignal(`${POWER} Oct 16 1pm to 4pm`)?.kind, 'brownout');
  assertEquals(B_noticeSignal('Water notice: October 16, 8:00 AM to 5:00 PM'), { kind: 'water', via: 'prefix', body: 'October 16, 8:00 AM to 5:00 PM' });
  assertEquals(B_noticeSignal('brownout notice:Oct 16 1-4pm'), { kind: 'brownout', via: 'prefix', body: 'Oct 16 1-4pm' });
});

Deno.test('B signal NEGATIVE: a guest about no water in the shower, a water bill, a receipt caption, a "cassy reply" draft and other Facebook links do not trigger', () => {
  for (const t of [
    'Hi, there is no water in the shower, please help',
    'Walang tubig sa shower namin',
    'GSCWD water bill for October, due Oct 20, amount 640',
    'water bill 640',
    'Water Service Interruption Oct 16 8:00 AM to 5:00 PM Brgy. San Isidro', // the post text alone, without a link or prefix, is not a signal
    'cassy reply: guest says the water is off and asks for a refund',
    '/draft the water pressure is low',
    'Joy Dishwashing 89',
    'see https://www.facebook.com/somebodyelse/posts/1 about the water',
    'https://www.facebook.com/gscwaterdistrictfans/posts/1',
    'please send a water notice: tomorrow', // does not START with the prefix
    '',
  ]) assertEquals(B_noticeSignal(t), null, t);
});

Deno.test('B routing: a human message or caption with a signal is routed to Cassy; a bot message, a receipt photo, a draft request and a callback are not', () => {
  const msg = (o: Record<string, unknown>) => ({ update_id: 1, message: { chat: { id: -1 }, from: { id: 5 }, ...o } });
  assert(B_noticeRoute(msg({ text: `${WATER}` })));
  assert(B_noticeRoute(msg({ caption: `${POWER}`, photo: [{ file_id: 'x' }] })), 'a photo caption with the page link is routed');
  assert(B_noticeRoute(msg({ text: 'water notice: Oct 16' })));
  assert(!B_noticeRoute(msg({ photo: [{ file_id: 'x' }] })), 'a receipt photo with no caption');
  assert(!B_noticeRoute(msg({ photo: [{ file_id: 'x' }], caption: 'Mercury Drug 540' })), 'a receipt photo with a caption');
  assert(!B_noticeRoute(msg({ text: 'cassy reply: no water in the shower' })));
  assert(!B_noticeRoute(msg({ text: WATER, from: { id: 9, is_bot: true } })), 'a bot message');
  assert(!B_noticeRoute({ update_id: 2, callback_query: { data: 'llm_confirm:1' } }), 'a button tap');
});

Deno.test('B routing: telegram-expense wires the route before the Cassy and photo paths, and the Save handler passes the source through', async () => {
  const src = await Deno.readTextFile(new URL('../telegram-expense/index.ts', import.meta.url));
  const route = src.indexOf('if(B_noticeRoute(update)){'), cassy = src.indexOf('Cassy (D-104, deploy 2'), photo = src.indexOf('handlePhotoMessage(msg,db)');
  assert(route > 0 && route < cassy && cassy < photo, 'order: notice route, then Cassy, then photo/receipt');
  assert(src.includes("telegram-cassy?any=1"), 'forwards to telegram-cassy');
  assert(src.includes('source:params.source??'), 'executeNoticeFromLLM stores params.source when given');
  const cassyIdx = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(cassyIdx.indexOf('B_noticeSignal(text)') > 0 && cassyIdx.indexOf('B_noticeSignal(text)') < cassyIdx.indexOf("searchParams.get('any')"), 'telegram-cassy checks the signal before the addressed-question path');
});

// ---- parsing ----
Deno.test('B notice: dates in ISO, Month D YYYY, D Month and year-less forms', () => {
  assertEquals(B_findDate('on 2026-10-16', '2026-10-13'), '2026-10-16');
  assertEquals(B_findDate('October 16, 2026', '2026-10-13'), '2026-10-16');
  assertEquals(B_findDate('16th of Oct', '2026-10-13'), '2026-10-16');
  assertEquals(B_findDate('Feb 31', '2026-10-13'), null);
  assertEquals(B_findDate('no date here', '2026-10-13'), null);
});

Deno.test('B notice L6: a December post about January saves next January; a recent past date stays this year', () => {
  assertEquals(B_findDate('Jan 5 8am to 5pm', '2026-12-20'), '2027-01-05');
  assertEquals(B_findDate('January 5, 2026', '2026-12-20'), '2026-01-05', 'an explicit year is kept');
  assertEquals(B_findDate('Oct 6', '2026-10-13'), '2026-10-06', 'last week stays this year');
  assertEquals(B_findDate('Dec 28', '2026-12-20'), '2026-12-28');
});

Deno.test('B notice: time ranges with and without minutes or a first meridiem', () => {
  assertEquals(B_findTimes('8:00 AM to 5:00 PM'), { start: '08:00:00', hours: 9, label: '8:00 am to 5:00 pm' });
  assertEquals(B_findTimes('1:00 - 4:00 PM'), { start: '13:00:00', hours: 3, label: '1:00 pm to 4:00 pm' });
  assertEquals(B_findTimes('8-5pm')?.start, '08:00:00');
  assertEquals(B_findTimes('9:30am until 11:45am')?.hours, 2.3);
  assertEquals(B_findTimes('call us'), null);
});

Deno.test('B notice M2: a year-less date before the time is not read as the start time', () => {
  assertEquals(B_findTimes('October 16 - 8:00 AM to 5:00 PM'), { start: '08:00:00', hours: 9, label: '8:00 am to 5:00 pm' });
  assertEquals(B_findTimes('October 6 - 8:00 AM to 5 PM'), { start: '08:00:00', hours: 9, label: '8:00 am to 5:00 pm' });
  assertEquals(B_findTimes('16 October - 8:00 AM to 5:00 PM')?.start, '08:00:00');
});

// ---- reading and the card ----
Deno.test('B notice: a water post is read into a built title with source gscwd; a phone number, e-mail or amount in the post cannot reach it', () => {
  const sig = B_noticeSignal(`${WATER} GSCWD Water Service Interruption Oct 16 8:00 AM to 5:00 PM Brgy. San Isidro. Call 0917 123 4567 or info@example.com, fee P500`)!;
  const r = B_readNotice(sig, AT);
  assertEquals(r.params, { notice_type: 'water', title: 'Water interruption 8:00 am to 5:00 pm in San Isidro', effective_date: '2026-10-16', effective_time: '08:00:00', duration_hours: 9, source: 'gscwd' });
  assert(!/0917|example\.com|P500/.test(JSON.stringify(r.params) + B_noticeCard(r)));
});

Deno.test('B notice: a SOCOTECO II post becomes a staff brownout (the existing /brownout row), time required', () => {
  const r = B_readNotice(B_noticeSignal(`${POWER} Oct 16 1:00 PM to 4:00 PM`)!, AT);
  assertEquals(r.params, { notice_type: 'brownout', title: 'Brownout 1:00 pm to 4:00 pm', effective_date: '2026-10-16', effective_time: '13:00:00', duration_hours: 3, source: 'staff' });
  const noTime = B_readNotice(B_noticeSignal(`${POWER} Oct 16`)!, AT);
  assertEquals([noTime.params, noTime.dateFound, noTime.timeFound], [null, true, false]);
  assert(B_askCard(noTime).includes('brownout notice: October 16'));
});

Deno.test('B notice: a bare link asks for the date and time; a water post with a date but no time is saved all-day and the card says so', () => {
  const bare = B_readNotice(B_noticeSignal(WATER)!, AT);
  assertEquals(bare.params, null);
  const ask = B_askCard(bare);
  assert(ask.includes('could not find the date') && ask.includes('water notice: October 16, 8:00 AM to 5:00 PM'));
  const dayOnly = B_readNotice(B_noticeSignal(`water notice: Oct 16 San Isidro`)!, AT);
  assertEquals([dayOnly.params?.effective_time, dayOnly.params?.duration_hours, dayOnly.params?.title], [null, null, 'Water interruption in San Isidro']);
  assert(B_noticeCard(dayOnly).includes('No time was found'));
  assert(B_noticeCard(B_readNotice(B_noticeSignal('water notice: Oct 16 8am-5pm')!, AT)).includes('does not name Brgy. San Isidro'));
});

// ---- the flow (live-mock) ----
Deno.test('B notice: the flow stores one llm_notice pending row (exact table, kind, payload keys incl. source) and sends Save / Cancel; nothing touches ops_notices', async () => {
  const calls: Array<[string, string, unknown]> = [];
  const db = { from: (t: string) => ({ insert: (row: any) => { calls.push([t, 'insert', row]); return { select: () => ({ single: () => Promise.resolve({ data: { id: 'pend-1' }, error: null }) }) }; } }) };
  const sent: any[] = [];
  const msg = { chat: { id: -100 }, message_id: 7, date: AT / 1000, from: { id: 5, first_name: 'Marifel' } };
  await B_noticeFlow(db, msg, B_noticeSignal('water notice: October 16, 8:00 AM to 5:00 PM San Isidro')!, (...a) => { sent.push(a); return Promise.resolve(true); });
  assertEquals(calls.length, 1);
  assertEquals([calls[0][0], calls[0][1]], ['telegram_pending', 'insert']);
  const row = calls[0][2] as any;
  assertEquals(Object.keys(row).sort(), ['chat_id', 'kind', 'payload']);
  assertEquals(row.kind, 'llm_notice');
  assertEquals(Object.keys(row.payload).sort(), ['from', 'params']);
  assertEquals(Object.keys(row.payload.params).sort(), ['duration_hours', 'effective_date', 'effective_time', 'notice_type', 'source', 'title']);
  assertEquals(row.payload.params.source, 'gscwd');
  assertEquals(sent[0][3][0].map((b: any) => b.callback_data), ['llm_confirm:pend-1', 'llm_cancel:pend-1']);
});

Deno.test('B notice: a bare link stores nothing and asks; a failed pending insert says nothing was saved', async () => {
  const none = { from: () => { throw new Error('must not touch the db'); } };
  const sent: string[] = [];
  await B_noticeFlow(none, { chat: { id: 1 }, message_id: 1, date: AT / 1000 }, B_noticeSignal(WATER)!, (_c, t, _r, kb) => { sent.push(t + '|' + kb.length); return Promise.resolve(true); });
  assert(sent[0].includes('could not find the date') && sent[0].endsWith('|0'));
  const bad = { from: () => ({ insert: () => ({ select: () => ({ single: () => Promise.resolve({ data: null, error: { message: 'boom' } }) }) }) }) };
  const sent2: string[] = [];
  await B_noticeFlow(bad, { chat: { id: 1 }, message_id: 1, date: AT / 1000 }, B_noticeSignal('water notice: Oct 16 8am-5pm')!, (_c, t) => { sent2.push(t); return Promise.resolve(true); });
  assert(sent2[0].includes('Nothing was saved'));
});

Deno.test('B guard: lane B top-level names are unique across its files and carry the B_ prefix (RAIN_THRESHOLD keeps its name)', async () => {
  const names: string[] = [];
  for (const f of ['../_shared/B_weather.ts', '../_shared/B_notice-signal.ts', './B_notice.ts']) {
    const src = await Deno.readTextFile(new URL(f, import.meta.url));
    for (const m of src.matchAll(/^(?:export )?(?:async )?(?:function|const|type) ([A-Za-z_][A-Za-z0-9_]*)/gm)) names.push(m[1]);
  }
  assertEquals(names.filter((n, i) => names.indexOf(n) !== i), [], 'duplicate top-level name');
  const allowed = ['RAIN_THRESHOLD', 'MONTHS', 'MON', 'HOUR', 'DAY_MS', 'round1', 'pct', 'nextHours', 'manilaYmd', 'pad', 'to24', 'merOf', 'RANGE', 'AFTER_MONTH', 'Send', 'FetchFn', 'WATER_LINK', 'POWER_LINK', 'PREFIX'];
  assertEquals(names.filter((n) => !n.startsWith('B_') && !allowed.includes(n)), []);
});
