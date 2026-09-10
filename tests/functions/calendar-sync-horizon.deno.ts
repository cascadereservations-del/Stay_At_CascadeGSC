import { assertEquals } from 'jsr:@std/assert@1';
import { classifyMissingAirbnbRows } from '../../supabase/functions/calendar-sync/horizon.ts';

Deno.test('keeps a missing row inside the rolling feed-horizon guard', () => {
  const result = classifyMissingAirbnbRows(
    [
      { uid: 'feed-a', checkout: '2027-09-08' },
      { uid: 'feed-tail', checkout: '2027-09-10' },
    ],
    [
      { id: 'present', uid: 'feed-a', checkin_date: '2027-09-01' },
      { id: 'rolling-tail', uid: 'old-tail', checkin_date: '2027-09-09' },
    ],
  );

  assertEquals(result.feedHorizon, '2027-09-10');
  assertEquals(result.horizonGuard, '2027-09-08');
  assertEquals(result.horizonSkipped, 1);
  assertEquals(result.rowsToReap, []);
});

Deno.test('reaps only missing rows before the feed-horizon guard', () => {
  const result = classifyMissingAirbnbRows(
    [{ uid: 'live', checkout: '2027-09-10' }],
    [
      { id: 'live-row', uid: 'live', checkin_date: '2027-08-01' },
      { id: 'stale-row', uid: 'stale', checkin_date: '2027-09-07' },
      { id: 'tail-row', uid: 'tail', checkin_date: '2027-09-08' },
    ],
  );

  assertEquals(result.horizonSkipped, 1);
  assertEquals(result.rowsToReap.map((row) => row.id), ['stale-row']);
});

Deno.test('fails closed when a feed has no checkout horizon', () => {
  const result = classifyMissingAirbnbRows(
    [{ uid: 'malformed', checkout: '' }],
    [{ id: 'unknown', uid: 'missing', checkin_date: '2027-01-01' }],
  );

  assertEquals(result.feedHorizon, '');
  assertEquals(result.horizonGuard, null);
  assertEquals(result.horizonSkipped, 1);
  assertEquals(result.rowsToReap, []);
});
