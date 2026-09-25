-- Session 49: release supersede_pending_hold_20260925 (SPEC-30, D-233, D-239).
-- A guest who changes dates releases their OWN earlier unpaid request - and only theirs, only when the new dates are
-- then free. Every fixture lives inside this transaction and goes with the closing rollback.
begin;
select plan(13);

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000030', 'Synthetic Supersede 30', true);

-- A: the guest's earlier request, 1 h old, no receipt, with its calendar block, hold and pending income row.
-- B: same guest, has a receipt.   C: same guest, 25 h old.   D: same phone, another e-mail.
-- G: another guest's own request; F: somebody else's booking on the dates G moves to.
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, status, source, submitted_at, receipt_image_path)
values
  ('ea000000-0000-4000-8000-00000000000a', 'e1000000-0000-4000-8000-000000000030', 'Synthetic Ana', 'ana@example.com', '09170000001', '2026-11-10', '2026-11-12', 'pending', 'direct', now() - interval '1 hour', null),
  ('ea000000-0000-4000-8000-00000000000b', 'e1000000-0000-4000-8000-000000000030', 'Synthetic Ana', 'ana@example.com', '09170000001', '2026-11-20', '2026-11-21', 'pending', 'direct', now() - interval '2 hours', 'receipts/synthetic-b.jpg'),
  ('ea000000-0000-4000-8000-00000000000c', 'e1000000-0000-4000-8000-000000000030', 'Synthetic Ana', 'ana@example.com', '09170000001', '2026-11-24', '2026-11-25', 'pending', 'direct', now() - interval '25 hours', null),
  ('ea000000-0000-4000-8000-00000000000d', 'e1000000-0000-4000-8000-000000000030', 'Synthetic Other', 'other@example.com', '09170000001', '2026-11-27', '2026-11-28', 'pending', 'direct', now() - interval '1 hour', null),
  ('ea000000-0000-4000-8000-000000000007', 'e1000000-0000-4000-8000-000000000030', 'Synthetic Gil', 'gil@example.com', '09170000002', '2026-12-05', '2026-12-06', 'pending', 'direct', now() - interval '1 hour', null);

insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date)
values
  ('e1000000-0000-4000-8000-000000000030', 'direct:ea000000-0000-4000-8000-00000000000a', 'direct', 'blocked', '2026-11-10', '2026-11-12'),
  ('e1000000-0000-4000-8000-000000000030', 'direct:ea000000-0000-4000-8000-000000000007', 'direct', 'blocked', '2026-12-05', '2026-12-06'),
  ('e1000000-0000-4000-8000-000000000030', 'synthetic-f@airbnb.com', 'airbnb', 'confirmed', '2026-12-01', '2026-12-03');

insert into public.booking_holds(property_id, booking_id, checkin_date, checkout_date, expires_at, status, idempotency_key)
values ('e1000000-0000-4000-8000-000000000030', 'ea000000-0000-4000-8000-00000000000a', '2026-11-10', '2026-11-12', now() + interval '23 hours', 'active', 'hold:ea000000-0000-4000-8000-00000000000a');

insert into public.transactions(property_id, txn_type, category, source, status, transaction_date, gross_amount, currency, booking_id)
values ('e1000000-0000-4000-8000-000000000030', 'income', 'direct_booking', 'direct_booking', 'pending_review', '2026-11-10', 3900, 'PHP', 'ea000000-0000-4000-8000-00000000000a');

-- Ana moves from Nov 10-12 to the overlapping Nov 11-13: her own hold must not stop her.
select set_config('cascade.s30', public.supersede_pending_direct_requests_v1(
  'e1000000-0000-4000-8000-000000000030', 'ANA@example.com ', ' 09170000001', '2026-11-11', '2026-11-13')::text, true);

select is(current_setting('cascade.s30')::jsonb, '{"superseded": ["ea000000-0000-4000-8000-00000000000a"], "reason": "released"}'::jsonb,
  'the earlier unpaid request is released, and only that one');
select is((select status from public.booking_inquiries where id = 'ea000000-0000-4000-8000-00000000000a'), 'cancelled', 'it is cancelled');
select ok((select notes like '%[system] replaced by the guest''s later request%' from public.booking_inquiries where id = 'ea000000-0000-4000-8000-00000000000a'),
  'with a note Finance can read');
select is((select status from public.calendar_events where uid = 'direct:ea000000-0000-4000-8000-00000000000a'), 'cancelled', 'its calendar block is gone');
select is((select status from public.booking_holds where booking_id = 'ea000000-0000-4000-8000-00000000000a'), 'released', 'its hold is released');
select is((select status from public.transactions where booking_id = 'ea000000-0000-4000-8000-00000000000a'), 'void', 'its pending income row is void');

select is((select status from public.booking_inquiries where id = 'ea000000-0000-4000-8000-00000000000b'), 'pending', 'a request with a receipt is never touched');
select is((select status from public.booking_inquiries where id = 'ea000000-0000-4000-8000-00000000000c'), 'pending', 'one older than 24 hours belongs to the expiry job');
select is((select status from public.booking_inquiries where id = 'ea000000-0000-4000-8000-00000000000d'), 'pending',
  'the same phone with another e-mail is somebody else (D-239)');

-- Gil moves onto dates somebody else holds: nothing of his is released, and submit-booking answers 409 as before.
select is(public.supersede_pending_direct_requests_v1(
  'e1000000-0000-4000-8000-000000000030', 'gil@example.com', '09170000002', '2026-12-02', '2026-12-04')->>'reason', 'new_dates_taken',
  'new dates that another booking holds release nothing');
select ok((select b.status = 'pending' and c.status = 'blocked' from public.booking_inquiries b
             join public.calendar_events c on c.uid = 'direct:' || b.id::text where b.id = 'ea000000-0000-4000-8000-000000000007'),
  'so the guest keeps the earlier hold');

select is(public.supersede_pending_direct_requests_v1('e1000000-0000-4000-8000-000000000030', 'ana@example.com', '  ', '2026-11-11', '2026-11-13')->>'reason',
  'not_applicable', 'no phone, no match');

select ok(has_function_privilege('service_role', 'public.supersede_pending_direct_requests_v1(uuid, text, text, date, date)', 'execute')
      and not has_function_privilege('anon', 'public.supersede_pending_direct_requests_v1(uuid, text, text, date, date)', 'execute')
      and not has_function_privilege('authenticated', 'public.supersede_pending_direct_requests_v1(uuid, text, text, date, date)', 'execute'),
  'only submit-booking (service_role) can call it');

select * from finish();
rollback;
