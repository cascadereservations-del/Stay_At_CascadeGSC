begin;
select plan(6);

insert into public.booking_inquiries (id, guest_name, guest_phone, checkin_date, checkout_date, source, status)
values ('11111111-1111-4111-8111-111111111111', 'Synthetic Guest', '0000000000', current_date + 10, current_date + 12, 'direct', 'pending');

select is((select count(*) from public.automation_outbox where aggregate_id = '11111111-1111-4111-8111-111111111111'::uuid and event_type = 'booking.requested'), 1::bigint, 'insert emits one booking.requested event');
update public.booking_inquiries set receipt_image_path = '11111111-1111-4111-8111-111111111111/test.jpg' where id = '11111111-1111-4111-8111-111111111111';
select is((select count(*) from public.automation_outbox where aggregate_id = '11111111-1111-4111-8111-111111111111'::uuid and event_type = 'booking.receipt_uploaded'), 1::bigint, 'receipt transition emits one event');
update public.booking_inquiries set status = 'confirmed' where id = '11111111-1111-4111-8111-111111111111';
update public.booking_inquiries set status = 'confirmed' where id = '11111111-1111-4111-8111-111111111111';
select is((select count(*) from public.automation_outbox where aggregate_id = '11111111-1111-4111-8111-111111111111'::uuid and event_type = 'booking.confirmed'), 1::bigint, 'confirmed replay does not duplicate event');
update public.booking_inquiries set status = 'cancelled' where id = '11111111-1111-4111-8111-111111111111';
select is((select count(*) from public.automation_outbox where aggregate_id = '11111111-1111-4111-8111-111111111111'::uuid and event_type = 'booking.cancelled'), 1::bigint, 'cancelled transition emits one event');
select ok(not (select payload ? 'guest_name' or payload ? 'guest_phone' or payload ? 'receipt_image_path' from public.automation_outbox where aggregate_id = '11111111-1111-4111-8111-111111111111'::uuid limit 1), 'outbox payload excludes guest PII and receipt path');
select is((select count(*) from public.automation_outbox where aggregate_id = '11111111-1111-4111-8111-111111111111'::uuid), 4::bigint, 'all expected lifecycle events are idempotent');

select * from finish();
rollback;
