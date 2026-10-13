// deno test supabase/functions/telegram-cassy/B_notice.test.ts - forwarded water posts. Frozen clock, synthetic posts only.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { B_findDate, B_findTimes, B_isForward, B_looksLikeWater, B_readWaterPost, B_waterCard, B_waterForward } from './B_notice.ts';

const AT = Date.parse('2026-10-13T02:00:00Z'); // 10:00 Manila, 13 Oct 2026

Deno.test('B notice: a forward is a forward, a plain message is not', () => {
  assert(B_isForward({ forward_origin: { type: 'channel' } }) && B_isForward({ forward_date: 1 }));
  assert(!B_isForward({ text: 'hello' }));
});

Deno.test('B notice: water posts are told from other text', () => {
  assert(B_looksLikeWater('GSCWD Water Service Interruption: Brgy. San Isidro, October 16, 2026, 8:00 AM to 5:00 PM'));
  assert(B_looksLikeWater('Walang tubig sa Oct 16'));
  assert(!B_looksLikeWater('Brownout tomorrow 1pm to 4pm'));
});

Deno.test('B notice: dates in ISO, Month D YYYY, D Month and year-less forms', () => {
  assertEquals(B_findDate('on 2026-10-16', 2026), '2026-10-16');
  assertEquals(B_findDate('October 16, 2026', 2026), '2026-10-16');
  assertEquals(B_findDate('16th of Oct', 2026), '2026-10-16');
  assertEquals(B_findDate('Sept 3', 2027), '2027-09-03');
  assertEquals(B_findDate('Feb 31', 2026), null);
  assertEquals(B_findDate('no date here', 2026), null);
});

Deno.test('B notice: time ranges with and without minutes or a first meridiem', () => {
  assertEquals(B_findTimes('8:00 AM to 5:00 PM'), { start: '08:00:00', hours: 9, label: '8:00 am to 5:00 pm' });
  assertEquals(B_findTimes('1:00 - 4:00 PM'), { start: '13:00:00', hours: 3, label: '1:00 pm to 4:00 pm' });
  assertEquals(B_findTimes('8-5pm')?.start, '08:00:00');
  assertEquals(B_findTimes('9:30am until 11:45am')?.hours, 2.3);
  assertEquals(B_findTimes('call us'), null);
});

Deno.test('B notice: the title is built, never copied, so a phone number, e-mail or amount in the post cannot reach the notice', () => {
  const post = 'GSCWD Water Service Interruption Oct 16 8:00 AM to 5:00 PM Brgy. San Isidro. Call 0917 123 4567 or info@example.com, fee P500';
  const r = B_readWaterPost(post, AT);
  assertEquals(r.params, { notice_type: 'water', title: 'Water interruption 8:00 am to 5:00 pm in San Isidro', effective_date: '2026-10-16', effective_time: '08:00:00', duration_hours: 9 });
  assert(!/0917|example\.com|P500/.test(JSON.stringify(r.params) + B_waterCard(r)));
});

Deno.test('B notice: no date falls back to the forward day and the card says so; a post not naming us says so', () => {
  const r = B_readWaterPost('Water advisory: low pressure expected in Lagao', AT);
  assertEquals([r.params.effective_date, r.dateFound, r.namesUs, r.params.title], ['2026-10-13', false, false, 'Water interruption']);
  const card = B_waterCard(r);
  assert(card.includes('names no date') && card.includes('does not name Brgy. San Isidro'));
});

Deno.test('B notice: the forward stores one llm_notice pending row (exact table, kind, payload keys) and sends Save / Cancel; nothing touches ops_notices', async () => {
  const calls: Array<[string, string, unknown]> = [];
  const db = { from: (t: string) => ({ insert: (row: any) => { calls.push([t, 'insert', row]); return { select: () => ({ single: () => Promise.resolve({ data: { id: 'pend-1' }, error: null }) }) }; } }) };
  const sent: any[] = [];
  const msg = { chat: { id: -100 }, message_id: 7, date: AT / 1000, from: { id: 5, first_name: 'Marifel' } };
  await B_waterForward(db, msg, 'Water interruption October 16 8:00 AM to 5:00 PM San Isidro', (...a) => { sent.push(a); return Promise.resolve(true); });
  assertEquals(calls.length, 1);
  assertEquals([calls[0][0], calls[0][1]], ['telegram_pending', 'insert']);
  const row = calls[0][2] as any;
  assertEquals(Object.keys(row).sort(), ['chat_id', 'kind', 'payload']);
  assertEquals(row.kind, 'llm_notice');
  assertEquals(Object.keys(row.payload).sort(), ['from', 'params']);
  assertEquals(Object.keys(row.payload.params).sort(), ['duration_hours', 'effective_date', 'effective_time', 'notice_type', 'title']);
  assertEquals(sent[0][3][0].map((b: any) => b.callback_data), ['llm_confirm:pend-1', 'llm_cancel:pend-1']);
});

Deno.test('B notice: a failed pending insert says nothing was saved', async () => {
  const db = { from: () => ({ insert: () => ({ select: () => ({ single: () => Promise.resolve({ data: null, error: { message: 'boom' } }) }) }) }) };
  const sent: string[] = [];
  await B_waterForward(db, { chat: { id: 1 }, message_id: 1, date: AT / 1000 }, 'water interruption', (_c, t) => { sent.push(t); return Promise.resolve(true); });
  assert(sent[0].includes('Nothing was saved'));
});

Deno.test('B guard: lane B top-level names are unique across its files and carry the B_ prefix (RAIN_THRESHOLD keeps its name)', async () => {
  const names: string[] = [];
  for (const f of ['../_shared/B_weather.ts', './B_notice.ts']) {
    const src = await Deno.readTextFile(new URL(f, import.meta.url));
    for (const m of src.matchAll(/^(?:export )?(?:async )?(?:function|const|type) ([A-Za-z_][A-Za-z0-9_]*)/gm)) names.push(m[1]);
  }
  assertEquals(names.filter((n, i) => names.indexOf(n) !== i), [], 'duplicate top-level name');
  assertEquals(names.filter((n) => !n.startsWith('B_') && !['RAIN_THRESHOLD', 'MONTHS', 'MON', 'HOUR', 'round1', 'pct', 'nextHours', 'manilaYmd', 'pad', 'to24', 'merOf', 'Send'].includes(n)), []);
});
