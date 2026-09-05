import { assertEquals } from 'jsr:@std/assert@1';
import { buildEventDetail, type BookingRecord, type EventRecord } from './logic.ts';

const booking: BookingRecord = {
  id: '63000000-0000-4000-8000-000000000001', status: 'confirmed',
  checkin_date: '2026-10-01', checkout_date: '2026-10-03', pax: 2,
  total_amount: 4000, deposit_amount: 2000, guest_name: 'Synthetic Guest',
  guest_email: 'guest@example.invalid', guest_phone: '000',
};
const event = (event_type: string, route_class: string, template_key: string): EventRecord => ({
  id: '64000000-0000-4000-8000-000000000001', event_type,
  aggregate_id: booking.id, route_class, template_key, payload: {},
});

Deno.test('Finance detail includes amounts but excludes guest contact', () => {
  const detail = buildEventDetail(event('booking.requested', 'finance', 'finance.booking_requested'), 'CH-W01', booking, 'soon')!;
  assertEquals(detail.total_amount, 4000);
  assertEquals('guest_email' in detail, false);
});

Deno.test('guest detail includes contact but excludes financial fields', () => {
  const detail = buildEventDetail(event('booking.confirmed', 'guest', 'guest.booking_confirmed'), 'CH-W03', booking, 'soon')!;
  assertEquals(detail.guest_email, 'guest@example.invalid');
  assertEquals('total_amount' in detail, false);
});

Deno.test('wrong workflow or route fails closed', () => {
  assertEquals(buildEventDetail(event('booking.confirmed', 'guest', 'guest.booking_confirmed'), 'CH-W02', booking, 'soon'), null);
  assertEquals(buildEventDetail(event('booking.requested', 'internal', 'internal.event'), 'CH-W01', booking, 'soon'), null);
});
