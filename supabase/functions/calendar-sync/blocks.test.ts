// deno test supabase/functions/calendar-sync/blocks.test.ts - D-290: a brownout block explains the Airbnb block Marifel makes by hand.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { blockCardText, blocksOverdue, blocksToAsk, blocksToTriage, explain, partialLine, type CalRow, type DirectEvidence, type Notice } from './blocks.ts';

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
  const asked = row({ recon_status: 'admin_block', block_reason: 'maintenance', block_reason_source: 'assumed', recon_alerted_at: '2026-09-20T00:00:00Z' });
  assertEquals(blocksOverdue([asked], '2026-10-02', new Date('2026-10-02T00:00:00Z')).length, 1);
  assertEquals(blocksOverdue([asked, brownout('2026-10-14'), brownout('2026-10-15')], '2026-10-02', new Date('2026-10-02T00:00:00Z')).length, 0);
});

// ---- SPEC-41: explain a block before asking anyone ------------------------------------------------------------------------
const TODAY = '2026-10-05';
const notice = (o: Partial<Notice> = {}): Notice => ({ id: 'n1', title: 'NGCP grid interruption', effective_date: '2026-10-11', effective_time: '08:00:00', duration_hours: 8, source: 'ngcp', ...o });
const oct = (a: number, b2: number, o: Partial<CalRow> = {}) => row({ uid: `ab${a}`, checkin_date: `2026-10-${a}`, checkout_date: `2026-10-${b2}`, ...o });
const askN = (rows: CalRow[], notices: Notice[] = [], direct: DirectEvidence[] = []) => blocksToAsk(rows, TODAY, null, notices, direct).map((r) => r.uid);

Deno.test('SPEC-41 1: an NGCP notice (Oct 11 08:00, 8 h) explains the Airbnb block Oct 10-12 with no brownout rows; the note names NGCP', () => {
  const b = oct(10, 12);
  assertEquals(askN([b], [notice()]), []);
  const e = explain(b, [b], [notice()], [])!;
  assertEquals(e.reason, 'brownout');
  assertEquals(e.note.includes('NGCP'), true, e.note);
  assertEquals(e.note, 'NGCP grid interruption Oct 11 08:00 for 8h');
});
Deno.test('SPEC-41 2: SOCOTECO Oct 15 06:00 for 11 h explains Oct 14-16 although power-watch held nothing (the live miss); a numeric-string duration works', () => {
  const b = oct(14, 16);
  const soc = notice({ title: 'SOCOTECO II scheduled interruption', effective_date: '2026-10-15', effective_time: '06:00:00', duration_hours: '11.0', source: 'socoteco' });
  assertEquals(explain(b, [b], [soc], [])?.reason, 'brownout');
  assertEquals(askN([b], [soc]), []);
});
Deno.test('SPEC-41 3: a notice covering only Oct 10 does not explain Oct 10-13; the card carries the partial line', () => {
  const b = oct(10, 13), n = notice({ effective_date: '2026-10-10', effective_time: '13:00:00', duration_hours: 2 }); // touches night Oct 10 only
  assertEquals(explain(b, [b], [n], []), null);
  assertEquals(askN([b], [n]), ['ab10']);
  const line = partialLine(b, [b], [n])!;
  assertEquals(line, 'The NGCP notice for Oct 10 covers the night of Oct 10. Nothing explains the nights of Oct 11 and Oct 12.');
  const card = blockCardText(b, line);
  assertEquals(card.includes(line), true);
  assertEquals(partialLine(oct(10, 11), [oct(10, 11)], [n]), null, 'fully covered, or not at all: no partial line');
});
Deno.test('SPEC-41 4: an inactive notice explains nothing (the caller reads active notices only); a notice on another day explains nothing', () => {
  const b = oct(10, 12);
  assertEquals(askN([b], []), ['ab10']);
  assertEquals(askN([b], [notice({ effective_date: '2026-10-20' })]), ['ab10']);
});
Deno.test('SPEC-41 5: an active hold or a live inquiry explains the block as direct; a released hold or a cancelled inquiry is not read in at all', () => {
  const b = oct(10, 12);
  const hold: DirectEvidence = { ref: 'A1B2C3D4', status: 'hold', checkin_date: '2026-10-11', checkout_date: '2026-10-13' };
  const inquiry: DirectEvidence = { ref: 'E5F6A7B8', status: 'pending', checkin_date: '2026-10-09', checkout_date: '2026-10-11' };
  assertEquals(explain(b, [b], [], [hold]), { reason: 'direct', note: 'DIR A1B2C3D4 hold' });
  assertEquals(explain(b, [b], [], [inquiry])?.note, 'DIR E5F6A7B8 pending');
  assertEquals(askN([b], [], [hold]), []);
  assertEquals(askN([b], [], []), ['ab10'], 'the caller drops released, expired, cancelled, declined rows before they get here');
  assertEquals(explain(b, [b], [], [{ ...hold, checkin_date: '2026-10-12', checkout_date: '2026-10-14' }]), null, 'a stay starting on the checkout day does not overlap');
  const stay = row({ uid: 'direct:abcdef123', source: 'direct', status: 'confirmed', checkin_date: '2026-10-11', checkout_date: '2026-10-13' });
  assertEquals(explain(b, [b, stay], [], [])?.reason, 'direct');
  assertEquals(explain(b, [b, { ...stay, status: 'cancelled' }], [], []), null);
  const airbnbStay = row({ uid: 'a', status: 'confirmed', checkin_date: '2026-10-11', checkout_date: '2026-10-13' });
  assertEquals(explain(b, [b, airbnbStay], [], []), null, 'an Airbnb stay is not a label...');
  assertEquals(askN([b, airbnbStay]), [], '...but it is still not asked (D-236)');
});
Deno.test('SPEC-41 6: nothing explains it -> asked; the card has no Finance, no PHP, names both nights, and says it is saved as maintenance', () => {
  const b = oct(10, 12);
  assertEquals(askN([b]), ['ab10']);
  const t = blockCardText(b);
  assertEquals(/Finance|PHP|₱/i.test(t), false, t);
  assertEquals(t.includes('the nights of Oct 10 and Oct 11'), true, t);
  assertEquals(t.includes('saved as maintenance for now'), true, t);
  assertEquals(t.includes('Whoever blocked it on Airbnb: please tap what it is. It is asked once.'), true, t);
  assertEquals(t.startsWith('🟡 ATTENTION · blocked date'), true, t);
});
Deno.test('SPEC-41 7: an auto row whose notice is gone is reset by the caller (it stays in the triage list); a staff row is never touched; an assumed row upgrades to auto', () => {
  const auto = oct(10, 12, { recon_status: 'admin_block', block_reason: 'brownout', block_reason_source: 'auto' });
  assertEquals(blocksToTriage([auto], TODAY, null).map((r) => r.uid), ['ab10'], 'auto rows are re-judged every run');
  assertEquals(explain(auto, [auto], [], []), null, 'evidence gone: the caller resets it to pending');
  const staff = oct(10, 12, { recon_status: 'admin_block', block_reason: 'owner_use', block_reason_source: 'staff' });
  assertEquals(blocksToTriage([staff], TODAY, null), []);
  assertEquals(askN([staff], [notice()]), []);
  const assumed = oct(10, 12, { recon_status: 'admin_block', block_reason: 'maintenance', block_reason_source: 'assumed' });
  assertEquals(blocksToTriage([assumed], TODAY, null).length, 1);
  assertEquals(explain(assumed, [assumed], [notice()], [])?.reason, 'brownout', 'a notice entered later upgrades assumed to auto');
  assertEquals(askN([assumed]), [], 'an assumed row is not asked again');
});
Deno.test('SPEC-41 8: an admin_block with no reason (answered the old way) is backfilled by a notice', () => {
  const old = oct(14, 16, { recon_status: 'admin_block' });
  assertEquals(blocksToTriage([old], TODAY, null).length, 1);
  const soc = notice({ title: 'SOCOTECO II scheduled interruption', effective_date: '2026-10-15', effective_time: '06:00:00', duration_hours: 11, source: 'socoteco' });
  assertEquals(explain(old, [old], [soc], [])?.reason, 'brownout');
  assertEquals(blocksToTriage([oct(14, 16, { recon_status: 'skipped' })], TODAY, null), [], 'skipped (direct or unblock, old way) is left alone');
  assertEquals(blocksToTriage([oct(14, 16, { checkout_date: '2027-10-17', checkin_date: '2027-10-16' })], TODAY, '2027-10-16'), [], 'the horizon tail is left alone');
});
Deno.test('SPEC-41 9: overdue = assumed and asked 8 days ago; staff, auto and fresh ones are not; a Finance-era pending row is asked once in OPS', () => {
  const now = new Date('2026-10-13T00:00:00Z'), old = '2026-10-05T00:00:00Z';
  const assumed = oct(20, 22, { recon_status: 'admin_block', block_reason: 'maintenance', block_reason_source: 'assumed', recon_alerted_at: old });
  assertEquals(blocksOverdue([assumed], '2026-10-13', now).map((r) => r.uid), ['ab20']);
  assertEquals(blocksOverdue([{ ...assumed, block_reason_source: 'staff' }], '2026-10-13', now), []);
  assertEquals(blocksOverdue([{ ...assumed, block_reason_source: 'auto' }], '2026-10-13', now), []);
  assertEquals(blocksOverdue([{ ...assumed, recon_alerted_at: '2026-10-10T00:00:00Z' }], '2026-10-13', now), []);
  assertEquals(blocksOverdue([assumed], '2026-10-13', now, [notice({ effective_date: '2026-10-21' })]), [], 'a notice that now explains it closes the chase');
  const financeEra = oct(20, 22, { recon_alerted_at: '2026-10-01T17:45:00Z' });
  assertEquals(askN([financeEra]), ['ab20'], 'asked in Finance, never answered: asked once in OPS');
});
