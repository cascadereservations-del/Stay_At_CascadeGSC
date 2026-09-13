// deno test daily-digest/digest.test.ts  (run from supabase/functions)
import { assertEquals, assert } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { renderReport } from '../_shared/cascade-core/format.ts';
import { financeReport, opsReport, weatherLine } from './report.ts';

const base = { today: '2026-09-14', tomorrow: '2026-09-15', arrivals: [], departures: [], tmrArrivals: [], tmrDepartures: [], notices: [], stock: [], weather: null, resRows: [] };

Deno.test('ops: quiet day is null; same-day turnover names both guests and asks for the cleaning window', () => {
  assertEquals(opsReport(base), null);
  const r = opsReport({ ...base,
    arrivals: [{ guest_name: 'Queenie Gonzales', nights: 2, checkin_time: '14:00' }],
    departures: [{ guest_name: null, raw_summary: 'Reserved', checkout_time: '11:00' }],
    resRows: [{ guest_name: 'James Rebaya', checkin_date: '2026-09-12', checkout_date: '2026-09-14' }],
  })!;
  assertEquals(r.decision, 'Mon 14 Sep: 1 arrival, 1 departure, same-day turnover.');
  assertEquals(r.lines, ['Arriving: Queenie Gonzales (2 nights, from 2:00 PM)', 'Departing: James Rebaya (by 11:00 AM)']);
  assertEquals(r.action, 'Coordinate the cleaning window between James Rebaya (by 11:00 AM) and Queenie Gonzales (2 nights, from 2:00 PM).');
});

Deno.test('ops: brownout owns the action and forces a send; the render has at most five bullets and no model line', () => {
  const r = opsReport({ ...base,
    notices: [{ notice_type: 'brownout', title: 'Scheduled brownout', effective_date: '2026-09-14', effective_time: '08:00', duration_hours: 4, feeder: 'Feeder 3' }],
    stock: [{ name: 'Bottled water', qty_on_hand: 5, unit: 'pc', runway: 0.5 }, { name: 'Coffee', qty_on_hand: 15, unit: 'pc', runway: 3 }],
    weather: { temp: 31, apparent: 36, rainProb: 10, uvIndex: 8, description: 'Partly cloudy', thunderProb: 45, rainWindow: { startHour: 13, endHour: 16, peakProb: 70 }, tomorrow: { description: 'Showers', high: 30, low: 25, rainProb: 60, thunderProb: 10 } },
    tmrArrivals: [{ guest_name: 'Ana' }],
  })!;
  assertEquals(r.action, 'Prepare for the Scheduled brownout at 8:00 AM for 4h (Feeder 3).');
  assertEquals(r.lines[0], '⚡ Scheduled brownout at 8:00 AM for 4h (Feeder 3)');
  assertEquals(r.lines[1], 'Low stock: Bottled water 5 pc (order today), Coffee 15 pc (~3 days left)');
  assertEquals(r.lines[2], 'Weather: Partly cloudy, 31°C (feels 36°C), UV 8 Very High, rain 1:00 PM–4:00 PM peak 70%, thunder 45%');
  assertEquals(r.lines[3], 'Tomorrow: arriving Ana; Showers 25–30°C, 60% rain');
  const text = renderReport(r);
  assertEquals(text.split('\n').filter((l) => l.startsWith('• ')).length, 4);
  assert(text.endsWith('Do: Prepare for the Scheduled brownout at 8:00 AM for 4h (Feeder 3).'));
  assertEquals(weatherLine(null), '');
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
