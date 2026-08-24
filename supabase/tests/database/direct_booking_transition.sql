begin;
select plan(5);
insert into public.booking_inquiries (id,guest_name,guest_phone,checkin_date,checkout_date,source,status)
values ('55555555-5555-4555-8555-555555555555','Synthetic Calendar','000',current_date+30,current_date+32,'direct','pending');
insert into public.calendar_events (property_id,uid,source,status,checkin_date,checkout_date,recon_status)
values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd','direct:55555555-5555-4555-8555-555555555555','direct','blocked',current_date+30,current_date+32,'manual_entry');
select lives_ok($$select public.apply_direct_booking_transition('55555555-5555-4555-8555-555555555555','confirm')$$,'confirmation transition succeeds');
select is((select count(*) from public.airbnb_reservations where confirmation_code='DIRECT:55555555-5555-4555-8555-555555555555'),1::bigint,'one canonical direct reservation');
select is((select status from public.calendar_events where uid='cascade-direct-55555555-5555-4555-8555-555555555555'),'confirmed','calendar is canonical confirmed occupancy');
select is((select count(*) from public.automation_outbox where event_type='calendar.projection_requested' and aggregate_type='calendar_event'),1::bigint,'one projection request follows canonical state');
select is((select count(*) from public.automation_outbox where event_type='calendar.projection_requested' and aggregate_id=(select id from public.calendar_events where uid='cascade-direct-55555555-5555-4555-8555-555555555555')),1::bigint,'projection event references canonical event');
select * from finish();
rollback;
