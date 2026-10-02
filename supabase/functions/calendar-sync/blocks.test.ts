// deno test supabase/functions/calendar-sync/blocks.test.ts - D-290: a brownout block explains the Airbnb block Marifel makes by hand.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { blocksOverdue, blocksToAsk, type CalRow } from './blocks.ts';

const row = (o: Partial<CalRow>): CalRow => ({
  uid: 'ab1', source: 'airbnb', status: 'blocked', checkin_date: '2026-10-14', checkout_date: '2026-10-16',
  recon_status: 'pending', recon_alerted_at: null, raw_description: null, ...o,
});
const brownout = (night: string, o: Partial<CalRow> = {}): CalRow => ({
  uid: `brownout:${night}`, source: 'manual', status: 'blocked', checkin_date: night,
  checkout_date: new Date(Date.parse(`${night}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10), recon_status: 'admin_block', recon_alerted_at: null, ...o,
});
const ask = (rows: CalRow[]) => blocksToAsk(rows, '2026-10-02', null).map((r) => r.uid);

Deno.test('D-290: an Airbnb block whose nights are all brownout nights is explained, no "what is this blocked date?" card', () => {
  assertEquals(ask([row({}), brownout('2026-10-14'), brownout('2026-10-15')]), [], 'Oct 14-16 over the two brownout nights');
  assertEquals(ask([row({ checkout_date: '2026-10-15' }), brownout('2026-10-14'), brownout('2026-10-15')]), [], 'one night of the two');
});
Deno.test('D-290: one night more than the outage, or a night we did not block, is still asked about', () => {
  assertEquals(ask([row({ checkout_date: '2026-10-17' }), brownout('2026-10-14'), brownout('2026-10-15')]), ['ab1'], 'Marifel blocked Oct 16 as well');
  assertEquals(ask([row({}), brownout('2026-10-14')]), ['ab1'], 'only one of two nights is a brownout night');
  assertEquals(ask([row({})]), ['ab1'], 'no brownout rows at all');
});
Deno.test('D-290: a cancelled brownout row, or a manual row that is not a brownout one, explains nothing', () => {
  assertEquals(ask([row({}), brownout('2026-10-14', { status: 'cancelled' }), brownout('2026-10-15')]), ['ab1']);
  assertEquals(ask([row({}), brownout('2026-10-14', { uid: 'manual:other' }), brownout('2026-10-15')]), ['ab1']);
  assertEquals(ask([row({}), brownout('2026-10-14', { source: 'airbnb' }), brownout('2026-10-15')]), ['ab1'], 'only manual rows count');
});
Deno.test('D-236 still holds beside it: a direct stay explains the block', () => {
  const stay = row({ uid: 'direct:x', source: 'direct', status: 'confirmed', checkin_date: '2026-10-15', checkout_date: '2026-10-17' });
  assertEquals(ask([row({}), stay]), []);
});
Deno.test('D-290: an explained block is not chased a week later either', () => {
  const asked = row({ recon_alerted_at: '2026-09-20T00:00:00Z' });
  assertEquals(blocksOverdue([asked], '2026-10-02', new Date('2026-10-02T00:00:00Z')).length, 1);
  assertEquals(blocksOverdue([asked, brownout('2026-10-14'), brownout('2026-10-15')], '2026-10-02', new Date('2026-10-02T00:00:00Z')).length, 0);
});
