-- Session 56 fix: release guest_message_reads_20260928. The 5.2 hold and the digest's ID read, as service_role sees them.
-- Every fixture goes with the closing rollback.
begin;
select plan(9);

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000057', 'Synthetic Guest Reads 56', true);
insert into public.guests(id, property_id, name) values
  ('e6570000-0000-4000-8000-0000000000a1', 'e1000000-0000-4000-8000-000000000057', 'Synthetic Ida'),
  ('e6570000-0000-4000-8000-0000000000a2', 'e1000000-0000-4000-8000-000000000057', 'Synthetic Nox');
insert into public.guest_profile_details(guest_id, property_id, id_on_file) values
  ('e6570000-0000-4000-8000-0000000000a1', 'e1000000-0000-4000-8000-000000000057', true),
  ('e6570000-0000-4000-8000-0000000000a2', 'e1000000-0000-4000-8000-000000000057', false);

-- Q: quiet stay (days 40-42).  W: a work order raised on its dates (days 50-52).  H: a Messenger thread with a complaint.
-- I: ID on file, N: profile without ID, P: no profile at all - all arriving days 1-3.
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, status, source, submitted_at, total_amount, deposit_amount)
values
  ('e6570000-0000-4000-8000-00000000000a', 'e1000000-0000-4000-8000-000000000057', null, 'Synthetic Quiet', 'q@example.com', '09170000571', current_date + 40, current_date + 42, 'confirmed', 'direct', now(), 3560, 1780),
  ('e6570000-0000-4000-8000-00000000000b', 'e1000000-0000-4000-8000-000000000057', null, 'Synthetic Work',  'w@example.com', '09170000572', current_date + 50, current_date + 52, 'confirmed', 'direct', now(), 3560, 1780),
  ('e6570000-0000-4000-8000-00000000000c', 'e1000000-0000-4000-8000-000000000057', null, 'Synthetic Hand',  'h@example.com', '09170000573', current_date + 60, current_date + 62, 'confirmed', 'direct', now(), 3560, 1780),
  ('e6570000-0000-4000-8000-00000000000d', 'e1000000-0000-4000-8000-000000000057', 'e6570000-0000-4000-8000-0000000000a1', 'Synthetic Ida', 'i@example.com', '09170000574', current_date + 1, current_date + 3, 'confirmed', 'direct', now(), 3560, 1780),
  ('e6570000-0000-4000-8000-00000000000e', 'e1000000-0000-4000-8000-000000000057', 'e6570000-0000-4000-8000-0000000000a2', 'Synthetic Nox', 'n@example.com', '09170000575', current_date + 2, current_date + 4, 'confirmed', 'direct', now(), 3560, 1780),
  ('e6570000-0000-4000-8000-00000000000f', 'e1000000-0000-4000-8000-000000000057', null, 'Synthetic Pim', 'p@example.com', '09170000576', current_date + 3, current_date + 5, 'confirmed', 'direct', now(), 3560, 1780);

insert into public.work_orders(property_id, source_kind, source_ref, title, status, created_at)
values ('e1000000-0000-4000-8000-000000000057', 'manual', 'synthetic-56', 'Synthetic broken shower', 'open', ((current_date + 51) + time '10:00') at time zone 'Asia/Manila');
insert into public.concierge_threads(psid, guest_name, booking_flow) values ('synthetic-psid-56', 'Synthetic Hand', jsonb_build_object('booking_id', 'e6570000-0000-4000-8000-00000000000c'));
insert into public.concierge_handoffs(psid, guest_name, guest_text, risk, status) values ('synthetic-psid-56', 'Synthetic Hand', 'the aircon is broken', 'complaint', 'open');

select ok(not public.guest_message_hold_v1('e6570000-0000-4000-8000-00000000000a'), 'a quiet stay is not held');
select ok(public.guest_message_hold_v1('e6570000-0000-4000-8000-00000000000b'), 'an open work order raised on the stay dates holds 5.2');
select ok(public.guest_message_hold_v1('e6570000-0000-4000-8000-00000000000c'), 'an open complaint on the booking thread holds 5.2');
update public.concierge_handoffs set status = 'dismissed' where psid = 'synthetic-psid-56';
select ok(not public.guest_message_hold_v1('e6570000-0000-4000-8000-00000000000c'), 'a dismissed handoff does not hold');
update public.work_orders set status = 'resolved' where source_ref = 'synthetic-56';
select ok(not public.guest_message_hold_v1('e6570000-0000-4000-8000-00000000000b'), 'a resolved work order does not hold');

select is((select array_agg(guest_name order by checkin_date) from public.arrivals_without_id_v1(current_date, current_date + 3) where guest_name like 'Synthetic%'),
  array['Synthetic Nox', 'Synthetic Pim'], 'arrivals without an ID: the profile without one and the guest with no profile, not the one on file');
select ok(not exists (select 1 from public.arrivals_without_id_v1(current_date, current_date + 3) where guest_name = 'Synthetic Quiet'), 'outside the window is not listed');

select ok(has_function_privilege('service_role', 'public.guest_message_hold_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.guest_message_hold_v1(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.guest_message_hold_v1(uuid)', 'execute'), 'guest_message_hold_v1 is service_role only');
select ok(has_function_privilege('service_role', 'public.arrivals_without_id_v1(date, date)', 'execute')
      and not has_function_privilege('anon', 'public.arrivals_without_id_v1(date, date)', 'execute')
      and not has_function_privilege('authenticated', 'public.arrivals_without_id_v1(date, date)', 'execute'), 'arrivals_without_id_v1 is service_role only');

select * from finish();
rollback;
