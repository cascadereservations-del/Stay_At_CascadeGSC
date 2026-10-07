// deno test daily-digest/digest.test.ts  (run from supabase/functions)
import { assertEquals, assert } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { renderReport } from '../_shared/cascade-core/format.ts';
import { decisionsLine, financeReport, opsReport, weatherLine, weeklyFinanceReport, weeklyOpsReport } from './report.ts';
import { withHeader } from '../_shared/cascade-core/format.ts';

const base = { today: '2026-09-14', tomorrow: '2026-09-15', arrivals: [], departures: [], tmrArrivals: [], tmrDepartures: [], notices: [], stock: [], weather: null, resRows: [] };

Deno.test('ops: quiet day is null; same-day turnover names both guests and asks for the cleaning window', () => {
  assertEquals(opsReport(base), null);
  const r = opsReport({ ...base,
    arrivals: [{ guest_name: 'Queenie Gonzales', nights: 2, checkin_time: '14:00' }],
    departures: [{ guest_name: null, raw_summary: 'Reserved', checkout_time: '11:00' }],
    resRows: [{ guest_name: 'James Rebaya', checkin_date: '2026-09-12', checkout_date: '2026-09-14' }],
  })!;
  assertEquals(r.decision, 'Mon 14 Sep: 1 arrival, 1 departure, same-day turnover.');
  assertEquals(r.lines, ['📥 Arriving: Queenie Gonzales (2 nights, from 2:00 PM)', '📤 Departing: James Rebaya (by 11:00 AM)']);
  assertEquals(r.action, 'Coordinate the cleaning window between James Rebaya (by 11:00 AM) and Queenie Gonzales (2 nights, from 2:00 PM).');
});

Deno.test('ops: brownout owns the action; low-but-not-out stock and weather stay out of a day with no movement', () => {
  const r = opsReport({ ...base,
    notices: [{ notice_type: 'brownout', title: 'Scheduled brownout', effective_date: '2026-09-14', effective_time: '08:00', duration_hours: 4, feeder: 'Feeder 3' }],
    stock: [{ name: 'Bottled water', qty_on_hand: 5, unit: 'pc', runway: 0.5 }, { name: 'Coffee', qty_on_hand: 15, unit: 'pc', runway: 3 }],
    weather: { temp: 31, apparent: 36, rainProb: 10, uvIndex: 8, description: 'Partly cloudy', thunderProb: 45, rainWindow: { startHour: 13, endHour: 16, peakProb: 70 }, tomorrow: { description: 'Showers', high: 30, low: 25, rainProb: 60, thunderProb: 10 } },
    tmrArrivals: [{ guest_name: 'Ana' }],
  })!;
  assertEquals(r.kind, 'attention');
  assertEquals(r.action, 'Prepare for the Scheduled brownout at 8:00 AM for 4h (Feeder 3).');
  assertEquals(r.lines[0], '⚡ Scheduled brownout at 8:00 AM for 4h (Feeder 3)');
  assertEquals(r.lines[1], ''); // group break (session 28)
  assertEquals(r.lines[2], '📆 Tomorrow: arriving Ana; Showers 25–30°C, 60% rain');
  const text = renderReport(r);
  assertEquals(text.split('\n').filter((l) => l.startsWith('• ')).length, 2);
  assert(text.endsWith('Do: Prepare for the Scheduled brownout at 8:00 AM for 4h (Feeder 3).'));
  assertEquals(weatherLine(null), '');
});

Deno.test('ops: an item at zero fires ATTENTION on a quiet day; a second-morning mid-stay fires DAILY; low stock alone stays silent', () => {
  const out = opsReport({ ...base, stock: [{ name: 'Liquid Hand Soap', qty_on_hand: 0, unit: 'pc', runway: 0 }] })!;
  assertEquals(out.kind, 'attention');
  assertEquals(out.lines, ['📦 Out of stock: Liquid Hand Soap']);
  assertEquals(out.action, 'Restock Liquid Hand Soap today — out of stock.');
  assertEquals(opsReport({ ...base, stock: [{ name: 'Coffee', qty_on_hand: 15, unit: 'pc', runway: 3 }] }), null);
  const mid = opsReport({ ...base, midStay: [{ guest: 'Ben', night: 2, nights: 5 }] })!;
  assertEquals(mid.kind, 'daily');
  assertEquals(mid.lines, ['🛎 Mid-stay: Ben, night 2 of 5 — towels and water topped up? everything okay?']);
  assert(mid.action.startsWith('send Ben this (Show as text to long-press it, or Revise with Cassy):\n📨 Hi Ben,'));
  assert(withHeader(mid.kind, 'Mon 14 Sep', renderReport(mid)).startsWith('🟢 DAILY · Mon 14 Sep\n\n'));
});

Deno.test('weekly: ops roll-up leads with the waiting guest; finance roll-up leads with the overdue payout', () => {
  const ops = weeklyOpsReport({ today: '2026-09-21', lowStock: [{ name: 'Tea', qty_on_hand: 3, unit: 'pc', runway: 0 }], workOrders: [{ title: 'Aircon leak', priority: 'high' }], handoffs: [{ guest: 'Ben', risk: 'payment', hours: 72 }], arrivals: [{ guest: 'Ana', date: '2026-09-23', nights: 2 }] });
  assertEquals(ops.decision, 'Week of Mon 21 Sep: 1 arrival, 1 low-stock item, 1 open work order, 1 unanswered guest.');
  assertEquals(ops.lines.filter(Boolean).length, 4);
  assertEquals(ops.lines.filter((l) => l === '').length, 3); // one break between each group
  assertEquals(ops.action, 'Reply to Ben first.');
  const fin = weeklyFinanceReport({ today: '2026-09-21', pending: [{ transaction_date: '2026-09-18', payee_name: 'P', category: 'supplies', gross_amount: 250, source: 'ocr' }], overdueLines: ['Airbnb HMX Ana: checked in 18 Sep, ₱3,000 payout not received (3 days)'], warns: [{ label: 'Duplicate ledger rows', n: 2, status: 'warn' }], consoleUrl: 'u' });
  assertEquals(fin.lines[0], '🧾 1 receipt awaiting review, ₱250 in total');
  assertEquals(fin.action, 'Chase the overdue payout first.');
});

Deno.test('finance: nothing pending mid-month is null; seven receipts show four plus a count; first of month leads with the CSV', () => {
  assertEquals(financeReport({ pending: [], firstOfMonth: false, consoleUrl: 'u' }), null);
  const pending = Array.from({ length: 7 }, (_, k) => ({ transaction_date: `2026-09-0${k + 1}`, payee_name: `P${k}`, category: 'supplies', gross_amount: 100, source: 'ocr' }));
  const r = financeReport({ pending, firstOfMonth: false, consoleUrl: 'https://console' })!;
  assertEquals(r.decision, '7 receipts awaiting review, ₱700 in total.');
  assertEquals(r.lines.length, 5);
  assertEquals(r.lines[0], '09-01 · P0 · ₱100 · receipt, supplies');
  assertEquals(r.lines[4], '…and 3 more');
  assertEquals(r.action, 'Confirm them in the admin console: https://console');
  const first = financeReport({ pending: [], firstOfMonth: true, lastExport: '2026-08-31', consoleUrl: 'u' })!;
  assertEquals(first.decision, 'Books are clean: no receipts awaiting review.');
  assert(first.lines[0].startsWith('Monthly CSV:'));
  assert(first.lines[0].endsWith('(last export covered 2026-08-31).'));
  assertEquals(renderReport(first).includes('— '), false);
});

// SPEC-10 control 11: the Monday roll-up names who decided what.
Deno.test('decisions: nobody decided anything means no line at all (D-160, post on movement)', () => {
  assertEquals(decisionsLine([]), '');
  assertEquals(decisionsLine(undefined), '');
  assertEquals(decisionsLine([{ reviewer: 'Lloyd', approved: 0, rejected: 0 }]), '');
});

Deno.test('decisions: confirmations are attributed by name, declines are counted', () => {
  assertEquals(
    decisionsLine([{ reviewer: 'Lloyd', approved: 3, rejected: 1 }, { reviewer: 'Marifel', approved: 1, rejected: 0 }]),
    '🧑‍⚖️ Bookings decided this week: 4 confirmed (Lloyd 3, Marifel 1) · 1 declined',
  );
  // Someone who only declined counts in the total but is not listed as having confirmed anything.
  assertEquals(
    decisionsLine([{ reviewer: 'Lloyd', approved: 0, rejected: 2 }]),
    '🧑‍⚖️ Bookings decided this week: 0 confirmed · 2 declined',
  );
});

Deno.test('the decisions line is its own group, so it cannot push the receipt line out of the card', () => {
  const fin = weeklyFinanceReport({
    today: '2026-09-21',
    pending: [{ transaction_date: '2026-09-18', payee_name: 'P', category: 'supplies', gross_amount: 250, source: 'ocr' }],
    overdueLines: ['Airbnb HMX Ana: checked in 18 Sep, ₱3,000 payout not received (3 days)'],
    warns: [{ label: 'Duplicate ledger rows', n: 2, status: 'warn' }],
    consoleUrl: 'u',
    decisions: [{ reviewer: 'Lloyd', approved: 2, rejected: 0 }],
  });
  const rendered = renderReport(fin);
  assert(rendered.includes('Bookings decided this week: 2 confirmed (Lloyd 2)'), 'the decisions line is rendered');
  assert(rendered.includes('receipt awaiting review'), 'and the receipt line survives beside it');
  assert(rendered.includes('payout not received'), 'and so does the overdue line');
  // Unchanged when the RPC returns nothing — which is also what a failed read looks like.
  const none = weeklyFinanceReport({ today: '2026-09-21', pending: [], overdueLines: [], warns: [], consoleUrl: 'u', decisions: [] });
  assertEquals(none.lines.some((l) => l.includes('Bookings decided')), false);
});

Deno.test('SPEC-18: a failing health check is printed as its problem, never as its pass-phrased label', () => {
  const fin = weeklyFinanceReport({ today: '2026-09-21', pending: [], overdueLines: [], consoleUrl: 'u', decisions: [], warns: [
    { check: 'inventory_ledger_consistent', label: 'Inventory quantities agree with movements', n: 1, status: 'fail', d: { d: [{ item: 'Soap', onHand: 1, lastMovement: 0 }] } },
    { check: 'payout_totals_agree', label: 'Reservation payouts equal payout e-mails plus adjustments', n: 0, status: 'warn', d: { d: { difference: 2590.78 } } },
  ] });
  const text = fin.lines.join('\n');
  assert(text.includes('🔴 1 inventory item disagrees with its own last stock movement.'), text);
  assert(text.includes('disagree by ₱2,590.78'), text);
  assert(!/agree with movements|payouts equal/.test(text), text);
  assert(!/₱0\.00/.test(text), text);
});

Deno.test('ops (SPEC-05 D): an arrival within 3 days without an ID gets one line under stock and wakes a quiet day', () => {
  const r = opsReport({ ...base, idMissing: [{ guest: 'Ben', checkin: '2026-09-16' }, { guest: 'Ana', checkin: '2026-09-17' }] })!;
  assertEquals(r.kind, 'daily');
  assertEquals(r.lines, ['🪪 ID still missing: Ben, arriving Wed 16 Sep; Ana, arriving Thu 17 Sep']);
  assertEquals(r.action, "Ask Ben for the guests' IDs, so the door-code card can go out.");
  const busy = opsReport({ ...base, stock: [{ name: 'Liquid Hand Soap', qty_on_hand: 0, unit: 'pc', runway: 0 }],
    arrivals: [{ guest_name: 'Queenie Gonzales', nights: 2, checkin_time: '14:00' }], idMissing: [{ guest: 'Ben', checkin: '2026-09-16' }] })!;
  const iStock = busy.lines.findIndex((l) => l.startsWith('📦')), iId = busy.lines.findIndex((l) => l.startsWith('🪪'));
  assert(iStock >= 0 && iId === iStock + 2, 'the ID line sits just under stock, after a group break');
  assert(busy.action.startsWith('Restock'), 'it never takes the action from stock or a move');
  assertEquals(opsReport({ ...base, idMissing: [] }), null);
});

// D-285 (DESIGN-weekly-quality-line-2026-09-29): two Cassy lines on the Monday Finance card, one better handoff line on OPS.
const quiet = { today: '2026-10-05', pending: [], overdueLines: [], warns: [], consoleUrl: 'u', decisions: [] };
const zero = { turns: 41, linted: 0, rules: [], misses: 0, teach: [] };

Deno.test('D-285 1: no lint and no misses - no Cassy lines, the card is what it was without them (D-160)', () => {
  assertEquals(weeklyFinanceReport({ ...quiet, cassy: zero }), weeklyFinanceReport(quiet));
  const busy = { ...quiet, pending: [{ transaction_date: '2026-10-01', payee_name: 'P', category: 'supplies', gross_amount: 250, source: 'ocr' }] };
  assertEquals(weeklyFinanceReport({ ...busy, cassy: zero }), weeklyFinanceReport(busy));
  assertEquals(weeklyFinanceReport({ ...quiet, cassy: null }), weeklyFinanceReport(quiet)); // a failed read
});

Deno.test('D-285 2: the voice line names the count and the top two rules', () => {
  const r = weeklyFinanceReport({ ...quiet, cassy: { ...zero, linted: 3, rules: [{ rule: 'too_long', n: 2 }, { rule: 'two_asks', n: 1 }] } });
  assertEquals(r.lines, ['🗣 Cassy: 3 of 41 guest messages got a reply that broke a voice rule (too long 2, two questions 1)']);
  assertEquals(r.action, '');
});

Deno.test('D-285 3: the teach line; a receipt action wins; on an otherwise empty card the Teach action appears', () => {
  const cassy = { ...zero, misses: 4, teach: [{ words: 'parking gate', n: 2 }, { words: 'laundry', n: 1 }, { words: 'iron', n: 1 }] };
  const r = weeklyFinanceReport({ ...quiet, cassy });
  assertEquals(r.lines, ['📚 Cassy had no house answer 4 times. Asked about: parking gate (2), laundry, iron. Teach with: cassy teach: ...']);
  assertEquals(r.action, 'Teach Cassy about parking gate with cassy teach: ...');
  const withReceipt = weeklyFinanceReport({ ...quiet, cassy, pending: [{ transaction_date: '2026-10-01', payee_name: 'P', category: 'supplies', gross_amount: 250, source: 'ocr' }] });
  assert(withReceipt.action.startsWith('Confirm the receipts'), withReceipt.action);
  const i = withReceipt.lines.findIndex((l) => l.startsWith('📚'));
  assertEquals(withReceipt.lines[i - 1], '', 'the Cassy group is its own group');
  assertEquals(weeklyFinanceReport({ ...quiet, cassy: { ...zero, misses: 1, teach: [] } }).lines, ['📚 Cassy had no house answer 1 time. Teach with: cassy teach: ...']);
});

Deno.test('D-285 4: an unknown rule prints its name with spaces; the Cassy group sits after the decisions line', () => {
  const r = weeklyFinanceReport({ ...quiet, decisions: [{ reviewer: 'Lloyd', approved: 1, rejected: 0 }], cassy: { ...zero, linted: 1, rules: [{ rule: 'foo_bar', n: 1 }] } });
  assertEquals(r.lines, ['🧑‍⚖️ Bookings decided this week: 1 confirmed (Lloyd 1) · 0 declined', '', '🗣 Cassy: 1 of 41 guest messages got a reply that broke a voice rule (foo bar 1)']);
});

Deno.test('D-285 5: OPS lists a waiting guest once, over 24 h only, and counts the week by risk, most first', () => {
  const base5 = { today: '2026-10-05', lowStock: [], workOrders: [], arrivals: [] };
  const suz = (h: number) => ({ guest: 'Suzanne', key: 'psid:070054', risk: 'policy_exception', hours: h });
  const r = weeklyOpsReport({ ...base5,
    handoffs: [suz(35), suz(35), suz(34), { guest: 'Ben', key: 'psid:1', risk: 'payment', hours: 3 }],
    weekRisks: ['access', 'payment', 'access', 'policy_exception', 'access', null],
  });
  assertEquals(r.lines.filter((l) => l.startsWith('💬')), ['💬 Handed to you this week: 3 access, 1 payment, 1 policy exception, 1 question. Still waiting over a day: Suzanne (policy exception, 1 day)']);
  assertEquals(r.decision, 'Week of Mon 5 Oct: 0 arrivals, 0 low-stock items, 0 open work orders, 1 unanswered guest.');
  assertEquals(r.action, 'Reply to Suzanne first.');
  const none = weeklyOpsReport({ ...base5, handoffs: [], weekRisks: [] });
  assertEquals(none.lines.some((l) => l.startsWith('💬')), false);
  const fresh = weeklyOpsReport({ ...base5, handoffs: [{ guest: 'Ben', risk: 'payment', hours: 3 }], weekRisks: ['payment'] });
  assertEquals(fresh.lines.filter((l) => l.startsWith('💬')), ['💬 Handed to you this week: 1 payment']);
  assertEquals(fresh.action, '');
  const old = weeklyOpsReport({ ...base5, handoffs: [{ guest: 'Ana', risk: null, hours: 80 }, { guest: 'Ben', risk: 'payment', hours: 30 }] });
  assertEquals(old.lines.filter((l) => l.startsWith('💬')), ['💬 Still waiting over a day: Ana (question, 3 days), Ben (payment, 1 day)']);
  assertEquals(old.action, 'Reply to Ana first.');
});

Deno.test('D-294: the Monday Finance card carries the API usage line, and a failed read skips only that line', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  const fin = src.slice(src.indexOf('async function buildFinanceMessage'), src.indexOf('// ── Main handler'));
  const at = (s: string) => { const i = fin.indexOf(s); if (i < 0) throw new Error(`missing: ${s}`); return i; };
  // after the weekly report is built, before it is rendered; inside a try so it can never break the digest
  const order = [at('const weekly = weeklyFinanceReport('), at('try {'), at("db.rpc('api_usage_daily_v1', { p_days: 8 })"), at("db.rpc('api_budget_daily_v1', { p_days: 8 })"),
    at("weekly.lines.push('', usageWeekLine(usageRows(u.data), budgetRows(b.data), caps, today));"), at('} catch (e)'), at("renderReport(weekly)")];
  assertEquals(order, [...order].sort((a, b) => a - b));
  at('if (u.error || b.error || c.error || !caps)');
});

Deno.test('D-306: a notice or work-order title with an amount is masked in the OPS morning digest and the weekly report', () => {
  const r = opsReport({ ...base, notices: [{ notice_type: 'reminder', title: 'Pay Honey ₱3,560 balance', effective_date: '2026-09-14' }] })!;
  const text = renderReport(r);
  assert(!/3,560/.test(text), text);
  assert(text.includes('Pay Honey [amount hidden]'), text);
  const w = weeklyOpsReport({ today: '2026-09-21', lowStock: [], workOrders: [{ title: 'Refund PHP 1,780 to guest', priority: 'high' }], handoffs: [], arrivals: [] });
  const wt = renderReport(w);
  assert(!/1,780/.test(wt), wt);
});

Deno.test('D-306: the OPS digest keeps a cleaning-pay or expense title whole and masks a booking-income one', () => {
  const keep = renderReport(opsReport({ ...base, notices: [{ notice_type: 'reminder', title: 'Pay Honey ₱500', effective_date: '2026-09-14' }, { notice_type: 'reminder', title: 'Bili ng supplies ₱320', effective_date: '2026-09-14' }] })!);
  assert(keep.includes('Pay Honey ₱500') && keep.includes('Bili ng supplies ₱320'), keep);
  const hide = renderReport(opsReport({ ...base, notices: [{ notice_type: 'reminder', title: 'Collect ₱3,000 balance from guest', effective_date: '2026-09-14' }] })!);
  assert(!hide.includes('3,000'), hide);
});

Deno.test('D-315: the Monday roll-up tells an overdue clean from a fee paid with no ledger row', () => {
  const fin = weeklyFinanceReport({ today: '2026-10-19', pending: [], overdueLines: [], consoleUrl: 'u', decisions: [], warns: [
    { check: 'cleaner_fees_settled', label: 'Cleaning fees settled in the ledger', n: 1, status: 'warn', d: { d: [{ guest: 'Dale', cleaned: '2026-10-01', fee: null, paid: null }] } },
  ] });
  const text = fin.lines.join('\n');
  assert(text.includes('🟡 1 clean unpaid for more than two weeks.'), text);
  assert(!/settled in the ledger|marked paid/.test(text), text);
});
