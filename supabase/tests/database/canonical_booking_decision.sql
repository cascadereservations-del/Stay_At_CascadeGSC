begin;
select plan(10);

select has_function(
  'public',
  'decide_direct_booking',
  array['uuid', 'text', 'text', 'uuid'],
  'canonical direct-booking decision RPC requires an explicit Finance review'
);

insert into public.properties (id, name)
values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Synthetic Cascade Property')
on conflict (id) do nothing;

insert into public.booking_inquiries (id, property_id, guest_name, guest_phone, checkin_date, checkout_date, source, status, total_amount)
values ('66666666-6666-4666-8666-666666666666', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Canonical Success', '000', current_date + 40, current_date + 42, 'direct', 'pending', 3000);
insert into public.calendar_events (property_id, uid, source, status, checkin_date, checkout_date, recon_status)
values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'direct:66666666-6666-4666-8666-666666666666', 'direct', 'blocked', current_date + 40, current_date + 42, 'manual_entry');

select is(
  public.decide_direct_booking_without_finance_review('66666666-6666-4666-8666-666666666666', 'confirm', 'canonical-success-key-0001')->>'outcome',
  'confirmed',
  'confirmation succeeds as one canonical decision'
);
select is((select status from public.booking_inquiries where id = '66666666-6666-4666-8666-666666666666'), 'confirmed', 'booking becomes confirmed');
select is((select count(*) from public.airbnb_reservations where confirmation_code = 'DIRECT:66666666-6666-4666-8666-666666666666'), 1::bigint, 'one direct reservation exists');
select is((select status from public.calendar_events where uid = 'cascade-direct-66666666-6666-4666-8666-666666666666'), 'confirmed', 'calendar becomes canonical confirmed occupancy');
select is((select count(*) from public.automation_outbox where event_type = 'calendar.projection_requested' and aggregate_id = (select id from public.calendar_events where uid = 'cascade-direct-66666666-6666-4666-8666-666666666666')), 1::bigint, 'one calendar projection is queued');
select ok(
  (public.decide_direct_booking_without_finance_review('66666666-6666-4666-8666-666666666666', 'confirm', 'canonical-success-key-0001')->>'already_processed')::boolean,
  'same idempotency key returns the stored decision'
);
select is((select count(*) from public.booking_decisions where booking_id = '66666666-6666-4666-8666-666666666666'), 1::bigint, 'retry does not create a second decision');

insert into public.booking_inquiries (id, property_id, guest_name, guest_phone, checkin_date, checkout_date, source, status)
values ('77777777-7777-4777-8777-777777777777', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Canonical Conflict', '000', current_date + 41, current_date + 43, 'direct', 'pending');
insert into public.calendar_events (property_id, uid, source, status, checkin_date, checkout_date, recon_status)
values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'direct:77777777-7777-4777-8777-777777777777', 'direct', 'blocked', current_date + 41, current_date + 43, 'manual_entry');

select is(
  public.decide_direct_booking_without_finance_review('77777777-7777-4777-8777-777777777777', 'confirm', 'canonical-conflict-key-01')->>'outcome',
  'conflict',
  'overlapping approval is rejected'
);
select is((select status from public.booking_inquiries where id = '77777777-7777-4777-8777-777777777777'), 'pending', 'conflicted booking remains unconfirmed');

select * from finish();
rollback;
