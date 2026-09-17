begin;
select plan(8);

select has_function('public','staff_decide_direct_booking_v1',array['uuid','text','text','uuid'],'staff gate exists');
select ok(has_function_privilege('authenticated','public.staff_decide_direct_booking_v1(uuid,text,text,uuid)','execute'), 'authenticated may call the gate');
select ok(not has_function_privilege('anon','public.staff_decide_direct_booking_v1(uuid,text,text,uuid)','execute'), 'anon may not call the gate');
select ok(not has_function_privilege('authenticated','public.decide_direct_booking(uuid,text,text,uuid)','execute'), 'the inner decision stays service_role only');

-- Synthetic fixtures: an owner (approve_payment), a cleaner (none) and one pending direct request.
insert into auth.users(id) values('f2900000-0000-4000-8000-0000000000a1'),('f2900000-0000-4000-8000-0000000000a2');
insert into public.staff_access_profiles(user_id,role) values('f2900000-0000-4000-8000-0000000000a1','owner'),('f2900000-0000-4000-8000-0000000000a2','cleaner');
insert into public.staff_property_access(user_id,property_id) values('f2900000-0000-4000-8000-0000000000a2','6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
insert into public.booking_inquiries (id, property_id, guest_name, guest_phone, checkin_date, checkout_date, source, status, total_amount)
values ('29292929-2929-4929-8929-292929292929', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Gate Fixture', '000', current_date + 200, current_date + 202, 'direct', 'pending', 3000);

-- A cleaner's session is refused by the gate itself.
select set_config('request.jwt.claims', json_build_object('sub','f2900000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select throws_ok(
  $$select public.staff_decide_direct_booking_v1('29292929-2929-4929-8929-292929292929'::uuid,'confirm','gate-test-cleaner',null)$$,
  '42501','approve_payment is required to decide a direct booking','a cleaner cannot decide a direct booking'
);

-- An owner passes the gate; the inner function still demands a named Finance review.
select set_config('request.jwt.claims', json_build_object('sub','f2900000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select throws_ok(
  $$select public.staff_decide_direct_booking_v1('29292929-2929-4929-8929-292929292929'::uuid,'confirm','gate-test-owner',null)$$,
  '42501','named Finance review required','an owner passes the gate and meets the unchanged Finance-review requirement'
);
select throws_ok(
  $$select public.staff_decide_direct_booking_v1('00000000-0000-4000-8000-000000000000'::uuid,'confirm','gate-test-missing',null)$$,
  'P0002','booking not found','an unknown booking is refused'
);
reset role;
select is((select status from public.booking_inquiries where id='29292929-2929-4929-8929-292929292929'), 'pending', 'nothing was decided');

select * from finish();
rollback;
