-- Session 79, D-323: intake_resolve_v1 opens a confirmed Airbnb reservation with a guest for an 'airbnb' token, and the direct path is
-- unchanged. Synthetic property, guests, reservations and made-up 64-hex token hashes only (public repo), all inside begin/rollback.
begin;
select plan(23);

select ok((select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.intake_resolve_v1(text)'::regprocedure),
  'intake_resolve_v1 is still security definer with an empty search_path');
select ok(not has_function_privilege('service_role', 'public.intake_resolve_v1(text)', 'execute')
      and not has_function_privilege('authenticated', 'public.intake_resolve_v1(text)', 'execute')
      and not has_function_privilege('anon', 'public.intake_resolve_v1(text)', 'execute'),
  'intake_resolve_v1 stays internal');

-- Airbnb: A confirmed + guest (future), B cancelled, C confirmed but cancelled_at set, D checked out, E no guest, F completed.
-- Direct: X confirmed + guest. Tokens: one per row, plus a direct-typed token on A and an airbnb-typed token on X (cross-type, must miss).
insert into public.properties(id, name, is_active) values ('e7900000-0000-4000-8000-0000000000a1', 'Synthetic Airbnb Intake Property', true);
insert into public.guests(id, property_id, name) values
  ('e7930000-0000-4000-8000-0000000000a1', 'e7900000-0000-4000-8000-0000000000a1', 'Zz Airbnb Guest'),
  ('e7930000-0000-4000-8000-0000000000b2', 'e7900000-0000-4000-8000-0000000000a1', 'Zz Other Guest'),
  ('e7930000-0000-4000-8000-0000000000c3', 'e7900000-0000-4000-8000-0000000000a1', 'Zz Direct Guest');
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, cancelled_at, guest_id, guest_name, guest_count, checkin_date, checkout_date) values
  ('e7920001-0000-4000-8000-0000000000a1', 'e7900000-0000-4000-8000-0000000000a1', 'HMZZS79A', 'confirmed', null,  'e7930000-0000-4000-8000-0000000000a1', 'Zz Airbnb Guest', 3, current_date + 4, current_date + 6),
  ('e7920002-0000-4000-8000-0000000000b2', 'e7900000-0000-4000-8000-0000000000a1', 'HMZZS79B', 'cancelled', now(), 'e7930000-0000-4000-8000-0000000000b2', 'Zz Other Guest', 1, current_date + 8, current_date + 9),
  ('e7920003-0000-4000-8000-0000000000c3', 'e7900000-0000-4000-8000-0000000000a1', 'HMZZS79C', 'confirmed', now(), 'e7930000-0000-4000-8000-0000000000b2', 'Zz Other Guest', 1, current_date + 10, current_date + 11),
  ('e7920004-0000-4000-8000-0000000000d4', 'e7900000-0000-4000-8000-0000000000a1', 'HMZZS79D', 'confirmed', null,  'e7930000-0000-4000-8000-0000000000b2', 'Zz Other Guest', 1, current_date - 5, current_date - 3),
  ('e7920005-0000-4000-8000-0000000000e5', 'e7900000-0000-4000-8000-0000000000a1', 'HMZZS79E', 'confirmed', null,  null,                                   'Zz Nobody',      1, current_date + 12, current_date + 13),
  ('e7920006-0000-4000-8000-0000000000f6', 'e7900000-0000-4000-8000-0000000000a1', 'HMZZS79F', 'completed', null,  'e7930000-0000-4000-8000-0000000000b2', 'Zz Other Guest', 1, current_date - 1, current_date + 1);
-- M: a mirror row of a direct booking (source 'direct', DIRECT:<uuid> code), confirmed with a guest and a future checkout.
insert into public.airbnb_reservations(id, property_id, confirmation_code, source, status, guest_id, guest_name, guest_count, checkin_date, checkout_date) values
  ('e7920008-0000-4000-8000-000000000008', 'e7900000-0000-4000-8000-0000000000a1', 'DIRECT:e7920007-0000-4000-8000-000000000007', 'direct', 'confirmed', 'e7930000-0000-4000-8000-0000000000c3', 'Zz Direct Guest', 2, current_date + 20, current_date + 22);
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, total_amount, deposit_amount, source, status) values
  ('e7920007-0000-4000-8000-000000000007', 'e7900000-0000-4000-8000-0000000000a1', 'e7930000-0000-4000-8000-0000000000c3', 'Zz Direct Guest', 'zz-x@example.invalid', '0000000007', current_date + 20, current_date + 22, 2, 4000, 2000, 'direct', 'confirmed');
insert into public.guest_access_tokens(property_id, booking_type, booking_id, token_hash, expires_at, revoked_at) values
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920001-0000-4000-8000-0000000000a1', repeat('a7', 32), now() + interval '30 days', null),
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920002-0000-4000-8000-0000000000b2', repeat('b7', 32), now() + interval '30 days', null),
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920003-0000-4000-8000-0000000000c3', repeat('c7', 32), now() + interval '30 days', null),
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920004-0000-4000-8000-0000000000d4', repeat('d7', 32), now() + interval '30 days', null),
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920005-0000-4000-8000-0000000000e5', repeat('e7', 32), now() + interval '30 days', null),
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920006-0000-4000-8000-0000000000f6', repeat('f7', 32), now() + interval '30 days', null),
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920001-0000-4000-8000-0000000000a1', repeat('17', 32), now() + interval '30 days', now()),
  ('e7900000-0000-4000-8000-0000000000a1', 'direct', 'e7920001-0000-4000-8000-0000000000a1', repeat('27', 32), now() + interval '30 days', null),
  ('e7900000-0000-4000-8000-0000000000a1', 'direct', 'e7920007-0000-4000-8000-000000000007', repeat('37', 32), now() + interval '30 days', null),
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920007-0000-4000-8000-000000000007', repeat('47', 32), now() + interval '30 days', null),
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920008-0000-4000-8000-000000000008', repeat('67', 32), now() + interval '30 days', null);
insert into public.guest_access_tokens(property_id, booking_type, booking_id, token_hash, expires_at, created_at) values
  ('e7900000-0000-4000-8000-0000000000a1', 'airbnb', 'e7920001-0000-4000-8000-0000000000a1', repeat('57', 32), now() - interval '1 day', now() - interval '10 days');

-- 3-5 the resolver itself (owner context)
select is((select row(booking_id, property_id, guest_id, ref, pax, guest_name)::text from public.intake_resolve_v1(repeat('a7', 32))),
  row('e7920001-0000-4000-8000-0000000000a1'::uuid, 'e7900000-0000-4000-8000-0000000000a1'::uuid, 'e7930000-0000-4000-8000-0000000000a1'::uuid, 'HMZZS79A', 3, 'Zz Airbnb Guest')::text,
  'an Airbnb token resolves to its reservation, ref = confirmation code, pax = guest_count');
select is((select count(*)::int from public.intake_resolve_v1(repeat('a7', 32))), 1, 'exactly one row');
select is((select ref from public.intake_resolve_v1(repeat('37', 32))), 'E7920007', 'a direct token still resolves with the 8-character ref');

set local role service_role;
-- 6-14 what opens nothing
select is(public.intake_guest_context_v1(repeat('b7', 32)), null::jsonb, 'a cancelled Airbnb reservation returns null');
select is(public.intake_guest_context_v1(repeat('c7', 32)), null::jsonb, 'a confirmed reservation with cancelled_at set returns null');
select is(public.intake_guest_context_v1(repeat('d7', 32)), null::jsonb, 'an Airbnb stay already checked out returns null');
select is(public.intake_guest_context_v1(repeat('e7', 32)), null::jsonb, 'an Airbnb reservation with no guest record returns null');
select is(public.intake_guest_context_v1(repeat('f7', 32)), null::jsonb, 'a completed Airbnb reservation returns null');
select is(public.intake_guest_context_v1(repeat('17', 32)), null::jsonb, 'a revoked Airbnb token returns null');
select is(public.intake_guest_context_v1(repeat('57', 32)), null::jsonb, 'an expired Airbnb token returns null');
select is(public.intake_guest_context_v1(repeat('27', 32)), null::jsonb, 'a direct-typed token on an Airbnb id returns null');
select is(public.intake_guest_context_v1(repeat('47', 32)), null::jsonb, 'an Airbnb-typed token on a direct booking id returns null');
select is(public.intake_guest_context_v1(repeat('67', 32)), null::jsonb, 'an Airbnb-typed token on a source=direct mirror row returns null');

-- 15-17 the context for an Airbnb stay: same keys as direct, can save
select is((select array_agg(k order by k) from jsonb_object_keys(public.intake_guest_context_v1(repeat('a7', 32))) k),
  array['can_save','checkin_date','checkout_date','guest_name','max_uploads_per_day','pax','people','ref','uploads_today']::text[],
  'the Airbnb context carries exactly the same keys as a direct one (no amount, no status)');
select is(public.intake_guest_context_v1(repeat('a7', 32)) ->> 'ref', 'HMZZS79A', 'the Airbnb context ref is the confirmation code');
select is((public.intake_guest_context_v1(repeat('a7', 32)) ->> 'can_save')::boolean, true, 'an Airbnb stay with a guest can save');

-- 18-20 the save RPCs work for the Airbnb guest
select is(public.intake_save_guest_details_v1(repeat('a7', 32), '{"contact_number":"0917 000 2222","id_type":"passport"}'::jsonb) ->> 'ok', 'true', 'Airbnb details write succeeds');
select ok(public.intake_save_guest_companion_v1(repeat('a7', 32), 'Zz Airbnb Guest', 'passport', null, null) ->> 'id' is not null, 'Airbnb companion is created');
select is(public.intake_save_guest_companion_v1(repeat('b7', 32), 'Zz Other Guest', null, null, null) ->> 'reason', 'invalid_token', 'a cancelled Airbnb token writes nothing');
reset role;

-- 21-22 provenance and isolation
select ok((select count(*) = 1 and bool_and(changed_by is null and reason = 'guest form HMZZS79A') from public.guest_companion_history where guest_id = 'e7930000-0000-4000-8000-0000000000a1'),
  'the companion history carries reason guest form <confirmation code>');
select is((select count(*)::int from public.guest_companions where guest_id = 'e7930000-0000-4000-8000-0000000000b2'), 0, 'refused Airbnb tokens wrote nothing for the other guest');

select * from finish();
rollback;
