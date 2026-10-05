-- Session 72, SPEC-42 s6: guest_booking_status_v1 (booking status page). Synthetic property, bookings and tokens only,
-- inside begin/rollback. Real names, phones and e-mails never appear: the fixtures use obviously fake values, and the key-set
-- test proves the RPC returns none of them anyway.
begin;
select plan(24);

select ok((select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.guest_booking_status_v1(text)'::regprocedure),
  'the RPC is security definer with an empty search_path');
select ok(not has_function_privilege('anon', 'public.guest_booking_status_v1(text)', 'execute'), 'anon cannot call it');
select ok(not has_function_privilege('authenticated', 'public.guest_booking_status_v1(text)', 'execute'), 'authenticated cannot call it');
select ok(has_function_privilege('service_role', 'public.guest_booking_status_v1(text)', 'execute'), 'service_role can call it');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'public.guest_booking_status_v1(text)'::regprocedure and a.grantee = 0),
  'PUBLIC has no execute grant');
select ok(exists (select 1 from pg_indexes where schemaname = 'public' and tablename = 'guest_access_tokens' and indexname = 'guest_access_tokens_booking_id_idx'),
  'the booking_id index exists');

-- Fixtures: A (pending, active hold, no receipt), B (confirmed, receipt), C (cancelled), D (pending with receipt).
-- The first 8 characters of each id differ, because the guest-facing ref is those 8 characters.
insert into public.properties(id, name, is_active) values ('e8100000-0000-4000-8000-0000000000a1', 'Synthetic Status Property', true);
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, total_amount, deposit_amount, source, status, receipt_image_path) values
  ('e8200001-0000-4000-8000-0000000000a1', 'e8100000-0000-4000-8000-0000000000a1', 'Zz Synthetic A', 'zz-a@example.invalid', '0000000001', current_date + 10, current_date + 12, 2, 4000, 2000, 'direct', 'pending', null),
  ('e8200002-0000-4000-8000-0000000000b2', 'e8100000-0000-4000-8000-0000000000a1', 'Zz Synthetic B', 'zz-b@example.invalid', '0000000002', current_date + 20, current_date + 22, 3, 5000, 2500, 'direct', 'confirmed', 'e8200002-0000-4000-8000-0000000000b2/n.jpg'),
  ('e8200003-0000-4000-8000-0000000000c3', 'e8100000-0000-4000-8000-0000000000a1', 'Zz Synthetic C', 'zz-c@example.invalid', '0000000003', current_date + 30, current_date + 31, 1, 2000, 1000, 'direct', 'cancelled', null),
  ('e8200004-0000-4000-8000-0000000000d4', 'e8100000-0000-4000-8000-0000000000a1', 'Zz Synthetic D', 'zz-d@example.invalid', '0000000004', current_date + 40, current_date + 41, 1, 2000, 1000, 'direct', 'pending', 'e8200004-0000-4000-8000-0000000000d4/n.jpg');
insert into public.booking_holds(property_id, booking_id, checkin_date, checkout_date, expires_at, status, idempotency_key) values
  ('e8100000-0000-4000-8000-0000000000a1', 'e8200001-0000-4000-8000-0000000000a1', current_date + 10, current_date + 12, now() + interval '20 hours', 'active', 'zz-status-hold-a-0000000001');
-- Tokens are looked up by hash, so the fixtures store a made-up 64-hex hash per case.
insert into public.guest_access_tokens(property_id, booking_type, booking_id, token_hash, expires_at, revoked_at) values
  ('e8100000-0000-4000-8000-0000000000a1', 'direct', 'e8200001-0000-4000-8000-0000000000a1', repeat('a1', 32), now() + interval '30 days', null),
  ('e8100000-0000-4000-8000-0000000000a1', 'direct', 'e8200002-0000-4000-8000-0000000000b2', repeat('b2', 32), now() + interval '30 days', null),
  ('e8100000-0000-4000-8000-0000000000a1', 'direct', 'e8200003-0000-4000-8000-0000000000c3', repeat('c3', 32), now() + interval '30 days', null),
  ('e8100000-0000-4000-8000-0000000000a1', 'direct', 'e8200004-0000-4000-8000-0000000000d4', repeat('d4', 32), now() + interval '30 days', null),
  ('e8100000-0000-4000-8000-0000000000a1', 'direct', 'e8200001-0000-4000-8000-0000000000a1', repeat('e5', 32), now() + interval '30 days', now()),
  ('e8100000-0000-4000-8000-0000000000a1', 'airbnb', 'e8200001-0000-4000-8000-0000000000a1', repeat('f6', 32), now() + interval '30 days', null);
-- An expired token still has to satisfy expires_at > created_at, so it is created in the past.
insert into public.guest_access_tokens(property_id, booking_type, booking_id, token_hash, expires_at, created_at) values
  ('e8100000-0000-4000-8000-0000000000a1', 'direct', 'e8200001-0000-4000-8000-0000000000a1', repeat('07', 32), now() - interval '1 day', now() - interval '10 days');

set local role service_role;

select is((public.guest_booking_status_v1(repeat('a1', 32))->>'ref'), 'E8200001', 'a valid token returns its own booking ref');
select is((public.guest_booking_status_v1(repeat('a1', 32))->>'status'), 'pending', 'a valid token returns the booking status');
select is((public.guest_booking_status_v1(repeat('a1', 32))->>'checkin_date')::date, current_date + 10, 'a valid token returns the check-in date');
select is((public.guest_booking_status_v1(repeat('a1', 32))->>'hold_status'), 'active', 'the active hold status is returned');
select ok((public.guest_booking_status_v1(repeat('a1', 32))->>'hold_expires_at')::timestamptz > now() + interval '19 hours', 'the hold deadline is returned');
select is((public.guest_booking_status_v1(repeat('a1', 32))->>'has_receipt')::boolean, false, 'has_receipt is false when no receipt is on file');

select is((select array_agg(k order by k) from jsonb_object_keys(public.guest_booking_status_v1(repeat('a1', 32))) k),
  array['booking_id','checkin_date','checkout_date','deposit_amount','has_receipt','hold_expires_at','hold_status','pax','ref','server_now','status','total_amount']::text[],
  'the answer carries exactly the allowed keys: no name, phone, e-mail, address, door code or receipt path');

select is((public.guest_booking_status_v1(repeat('b2', 32))->>'ref'), 'E8200002', 'a second token returns its own booking, not A');
select is((public.guest_booking_status_v1(repeat('b2', 32))->>'total_amount')::numeric, 5000::numeric, 'B shows its own total');
select is((public.guest_booking_status_v1(repeat('b2', 32))->>'has_receipt')::boolean, true, 'has_receipt is true when a receipt is on file, without the path');
select is((public.guest_booking_status_v1(repeat('c3', 32))->>'status'), 'cancelled', 'a cancelled booking still answers, as cancelled');

select is(public.guest_booking_status_v1(repeat('00', 32)), null::jsonb, 'an unknown token returns null');
select is(public.guest_booking_status_v1('not-a-hash'), null::jsonb, 'a malformed hash returns null');
select is(public.guest_booking_status_v1(repeat('07', 32)), null::jsonb, 'an expired token returns null');
select is(public.guest_booking_status_v1(repeat('e5', 32)), null::jsonb, 'a revoked token returns null');
select is(public.guest_booking_status_v1(repeat('f6', 32)), null::jsonb, 'an Airbnb-type token returns null');

reset role;
select ok((select last_used_at is not null from public.guest_access_tokens where token_hash = repeat('a1', 32)), 'a valid read stamps last_used_at');
select ok((select last_used_at is null from public.guest_access_tokens where token_hash = repeat('e5', 32)), 'a refused read leaves last_used_at empty');

select * from finish();
rollback;
