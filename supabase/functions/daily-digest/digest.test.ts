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
  assert(mid.action.startsWith('send Ben this (Copy, or Revise with Cassy):\n📨 Hi Ben,'));
  assert(withHeader(mid.kind, 'Mon 14 Sep', renderReport(mid)).startsWith('🟢 DAILY · Mon 14 Sep\n\n'));
});

Deno.test('weekly: ops roll-up leads with the waiting guest; finance roll-up leads with the overdue payout', () => {
  const ops = weeklyOpsReport({ today: '2026-09-21', lowStock: [{ name: 'Tea', qty_on_hand: 3, unit: 'pc', runway: 0 }], workOrders: [{ title: 'Aircon leak', priority: 'high' }], handoffs: [{ guest: 'Ben', risk: 'payment', days: 3 }], arrivals: [{ guest: 'Ana', date: '2026-09-23', nights: 2 }] });
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
