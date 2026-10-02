// D-290 chains + guest-details reminder. Synthetic fixtures only (public repo). deno test daily-digest/chains.test.ts
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { chainSpan, fetchChains, stayContinues, type Chain } from '../_shared/cascade-core/chains.ts';
import { chainCard, detailsCard, midStayFor, stayOnFor } from './cards.ts';
import { opsReport } from './report.ts';

const chain: Chain = {
  junction_date: '2026-10-02', guest_id: 'g-1', guest_name: 'Test Guest',
  first_uid: 'uid-a', first_source: 'airbnb', first_code: 'HMTEST0001', first_checkin: '2026-09-28',
  next_uid: 'uid-b', next_code: 'HMTEST0002', next_checkout: '2026-10-04',
};

Deno.test('chain card: Airbnb to Airbnb gives the what-happened line, Marifel\'s steps and a Done button', () => {
  const c = chainCard(chain);
  assertEquals(c.text, [
    '🟡 ATTENTION · Test stays on',
    '',
    'Test Guest stays Mon 28 Sep to Sun 4 Oct on two Airbnb bookings, joined Fri 2 Oct. No turnover and no cleaning on Fri 2 Oct.',
    '',
    'Marifel, in Airbnb:',
    '1. On HMTEST0001 (ends Fri 2 Oct) skip "Checkout Reminder w/ Next Guest" and "5.2 After Departure".',
    '2. On HMTEST0002 (starts Fri 2 Oct) skip "2. Pre-Arrival Welcome" and send a short note instead of re-asking IDs (the booking confirmation went out automatically).',
    '3. Keep the same door code for the whole stay.',
    '4. Next time use Airbnb\'s Change reservation to extend instead of a second booking.',
  ].join('\n'));
  assertEquals(c.buttons, [{ text: '✅ Done', callback_data: 'stc:done:2026-10-02:HMTEST0001' }]);
  assertEquals([c.kind, c.ref], ['stay_continues', '2026-10-02:HMTEST0001']);
  assert(!/[₱]|PHP/.test(c.text), 'OPS cards never show guest money');
});

Deno.test('chain card: direct-only says no Airbnb action; mixed only steps the Airbnb side; no code means no button', () => {
  const direct = chainCard({ ...chain, first_uid: 'direct:11', first_source: 'direct', first_code: 'DIR-TEST1', next_uid: 'direct:22', next_code: 'DIR-TEST2' });
  assert(direct.text.includes('on two direct bookings, joined Fri 2 Oct'));
  assert(direct.text.endsWith('Our messages already adjust, no Airbnb action.\nKeep the same door code for the whole stay.'));
  assert(!direct.text.includes('Marifel'));
  const mixed = chainCard({ ...chain, next_uid: 'direct:22', next_code: 'DIR-TEST2' });
  assert(mixed.text.includes('two bookings (one Airbnb, one direct)'));
  assert(mixed.text.includes('1. On HMTEST0001 (ends Fri 2 Oct) skip'));
  assert(mixed.text.includes('2. DIR-TEST2 is a direct booking: our messages already adjust.'));
  assert(!mixed.text.includes('Change reservation'));
  const noCode = chainCard({ ...chain, first_code: null });
  assertEquals(noCode.buttons, []);
  assertEquals(noCode.ref, '2026-10-02:uid-a');
  const long = chainCard({ ...chain, first_code: 'X'.repeat(60) });
  assertEquals(long.buttons, [], 'a callback over 64 bytes is dropped, not sent broken');
});

Deno.test('guest-details card: arrives vs arrived, Open guest link, Saved callback within 64 bytes', () => {
  const gid = '123e4567-e89b-12d3-a456-426614174000';
  const c = detailsCard({ guestId: gid, guest: 'Test Guest', checkin: '2026-10-03', code: 'HMTEST0003', source: 'airbnb' }, '2026-10-02');
  assertEquals(c.text, [
    '🟡 ATTENTION · guest details',
    '',
    'Guest details not saved yet: Test Guest arrives Sat 3 Oct (HMTEST0003). Save the names, mobile number and ID photos they sent in the Airbnb chat to the dashboard.',
  ].join('\n'));
  assertEquals(c.buttons, [
    { text: 'Open guest', url: `https://cascadereservations-del.github.io/cascade-admin-dashboard/#/guests/${gid}` },
    { text: '✅ Saved', callback_data: `crm:done:2026-10-03:${gid}` },
  ]);
  assert(new TextEncoder().encode(c.buttons[1].callback_data!).length <= 64);
  assertEquals([c.kind, c.ref], ['guest_details', `2026-10-03:${gid}`]);
  const inHouse = detailsCard({ guestId: gid, guest: 'Test Guest', checkin: '2026-10-01', source: 'direct' }, '2026-10-02');
  assert(inHouse.text.includes('Test Guest arrived Thu 1 Oct. Save the names, mobile number and ID photos they sent in the Messenger chat'));
});

Deno.test('ops digest: a junction day is one "stays on" line, not an arrival, a departure or a turnover', () => {
  const base = { today: '2026-10-02', tomorrow: '2026-10-03', arrivals: [], departures: [], tmrArrivals: [], tmrDepartures: [], notices: [], stock: [], weather: null, resRows: [] };
  const r = opsReport({ ...base, stayOn: stayOnFor([chain], '2026-10-02', 'today') })!;
  assertEquals(r.decision, 'Fri 2 Oct: no arrivals or departures.');
  assertEquals(r.lines, ['🔁 Test stays on (same guest, two bookings joined Fri 2 Oct) - no turnover']);
  assertEquals(r.action, '');
  // a different guest arriving the same day is still a plain arrival, not a turnover
  const other = opsReport({ ...base, stayOn: stayOnFor([chain], '2026-10-02', 'today'), arrivals: [{ guest_name: 'Other Guest', nights: 1 }] })!;
  assert(!other.decision.includes('turnover'));
  const tmr = opsReport({ ...base, today: '2026-10-01', tomorrow: '2026-10-02', stayOn: stayOnFor([chain], '2026-10-02', 'tomorrow') })!;
  assertEquals(tmr.lines, ['📆 Tomorrow: Test stays on (same guest, two bookings joined Fri 2 Oct) - no turnover']);
  assertEquals(opsReport({ ...base, stayOn: [] }), null);
});

Deno.test('mid-stay nudge counts nights from the chain start', () => {
  const a = { uid: 'uid-a', guest: 'Test', checkin_date: '2026-09-29', checkout_date: '2026-10-01', nights: 2 };
  const ch: Chain = { ...chain, junction_date: '2026-10-01', first_checkin: '2026-09-29', next_checkout: '2026-10-04' };
  assertEquals(midStayFor(a, '2026-09-30', []), null, 'alone, two nights is no nudge');
  assertEquals(midStayFor(a, '2026-09-30', [ch]), { guest: 'Test', night: 2, nights: 5 });
  const b = { uid: 'uid-b', guest: 'Test', checkin_date: '2026-10-01', checkout_date: '2026-10-04', nights: 3 };
  assertEquals(midStayFor(b, '2026-10-02', []), { guest: 'Test', night: 2, nights: 3 }, 'without the chain the second booking nudges again');
  assertEquals(midStayFor(b, '2026-10-02', [ch]), null, 'with the chain it is night 4 of 5');
});

Deno.test('chainSpan follows a three-booking chain from any booking', () => {
  const c1: Chain = { ...chain, first_uid: 'u1', next_uid: 'u2', first_checkin: '2026-09-28', junction_date: '2026-09-30', next_checkout: '2026-10-02' };
  const c2: Chain = { ...chain, first_uid: 'u2', next_uid: 'u3', first_checkin: '2026-09-30', junction_date: '2026-10-02', next_checkout: '2026-10-05' };
  assertEquals(chainSpan('u2', '2026-09-30', '2026-10-02', [c1, c2]), { start: '2026-09-28', end: '2026-10-05', bookings: 3 });
  assertEquals(chainSpan('u1', '2026-09-28', '2026-09-30', [c1, c2])?.end, '2026-10-05');
  assertEquals(chainSpan('zz', '2026-09-28', '2026-09-30', [c1, c2]), null);
});

Deno.test('a missing RPC degrades to no chains and no continuation', async () => {
  const missing = { rpc: () => Promise.resolve({ data: null, error: { message: 'Could not find the function public.stay_chains_v1' } }) };
  const boom = { rpc: () => { throw new Error('network'); } };
  assertEquals(await fetchChains(missing, 'p', '2026-10-01', '2026-10-15'), []);
  assertEquals(await fetchChains(boom, 'p', '2026-10-01', '2026-10-15'), []);
  assertEquals(await stayContinues(missing, 'p', '2026-10-02'), false);
  assertEquals(await stayContinues(boom, 'p', '2026-10-02'), false);
  assertEquals(await stayContinues({ rpc: () => Promise.resolve({ data: true, error: null }) }, 'p', '2026-10-02'), true);
});
