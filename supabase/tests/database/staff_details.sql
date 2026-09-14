begin;
select plan(12);

select has_table('public','staff_details','staff_details table exists');
select has_table('public','staff_details_history','staff_details_history table exists');
select has_function('public','save_staff_details_v1',array['uuid','jsonb','integer','text'],'save RPC exists');
select has_function('public','list_staff_details_v1',array[]::text[],'list RPC exists');
select ok(not has_table_privilege('anon','public.staff_details','select'), 'anon cannot read staff details');
select ok(not has_function_privilege('anon','public.save_staff_details_v1(uuid,jsonb,integer,text)','execute'), 'anon cannot save staff details');

-- Synthetic fixtures: an owner (manage_staff) and a cleaner (no manage_staff).
insert into auth.users(id) values('f2000000-0000-4000-8000-0000000000a1'),('f2000000-0000-4000-8000-0000000000a2');
insert into public.staff_access_profiles(user_id,role) values('f2000000-0000-4000-8000-0000000000a1','owner'),('f2000000-0000-4000-8000-0000000000a2','cleaner');

-- Cleaner cannot save another staffer's details, and cannot even self-manage.
select set_config('request.jwt.claims', json_build_object('sub','f2000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select throws_ok(
  $$select public.save_staff_details_v1('f2000000-0000-4000-8000-0000000000a2'::uuid, '{"fee_turnover":"500"}'::jsonb, null, 'cleaner attempt')$$,
  '42501','manage_staff denied','cleaner cannot save staff details, even their own'
);
-- list returns zero rows for a caller without manage_staff, not an error.
select is((select count(*) from public.list_staff_details_v1())::int, 0, 'unauthorized list returns zero rows, not an error');

-- Owner (manage_staff allowed) saves the cleaner's fee structure; round-trips.
select set_config('request.jwt.claims', json_build_object('sub','f2000000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is(
  (public.save_staff_details_v1('f2000000-0000-4000-8000-0000000000a2'::uuid,
    '{"fee_turnover":"500","fee_transport":"150","fee_deep_clean":"1000","contact_number":"09171111111"}'::jsonb,
    null, 'owner sets fee structure')->>'ok')::boolean,
  true, 'owner save returns ok'
);
select is((select count(*) from public.list_staff_details_v1() where user_id='f2000000-0000-4000-8000-0000000000a2')::int, 1, 'owner list sees the saved row');
reset role;
select is((select fee_turnover from public.staff_details where user_id='f2000000-0000-4000-8000-0000000000a2')::text,'500','fee_turnover round-trips');
select is((select count(*) from public.staff_details_history where user_id='f2000000-0000-4000-8000-0000000000a2')::int, 1, 'one history row recorded for the save');

select * from finish();
rollback;
