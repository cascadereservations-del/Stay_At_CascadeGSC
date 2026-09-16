begin;
select plan(16);

-- Columns exist (20260914220000)
select has_column('public','guest_profile_details','contact_number','contact number column exists');
select has_column('public','guest_profile_details','birthday','birthday column exists');
select has_column('public','guest_profile_details','address','address column exists');
select has_column('public','guest_profile_details','airbnb_profile_id','airbnb profile id column exists');
select has_column('public','guest_profile_details','id_on_file','id_on_file column exists');
select has_column('public','guest_profile_details','id_type','id_type column exists');
select has_column('public','guest_profile_details','id_number','id_number column exists');
select has_column('public','guest_profile_details','id_drive_url','id_drive_url column exists');
select has_column('public','guest_profile_details','id_verified_at','id_verified_at column exists');

-- anon is denied outright
select ok(not has_table_privilege('anon','public.guest_profile_details','select'), 'anon cannot read guest profile details');
select ok(not has_function_privilege('anon','public.save_guest_profile_v1(uuid,jsonb,integer,text)','execute'), 'anon cannot save guest profile details');

-- Synthetic fixtures: one property, an owner and a cleaner, one guest.
insert into public.properties(id,name,is_active) values('f1000000-0000-4000-8000-0000000000a1','Synthetic Contact/ID',true);
insert into auth.users(id) values('f1000000-0000-4000-8000-0000000000a2'),('f1000000-0000-4000-8000-0000000000a3');
insert into public.staff_access_profiles(user_id,role) values('f1000000-0000-4000-8000-0000000000a2','owner'),('f1000000-0000-4000-8000-0000000000a3','cleaner');
insert into public.staff_property_access(user_id,property_id) values('f1000000-0000-4000-8000-0000000000a3','f1000000-0000-4000-8000-0000000000a1');
insert into public.guests(id,property_id,name) values('f1000000-0000-4000-8000-0000000000a4','f1000000-0000-4000-8000-0000000000a1','Synthetic Guest');

-- Cleaner (manage_operations denied) cannot save.
select set_config('request.jwt.claims', json_build_object('sub','f1000000-0000-4000-8000-0000000000a3','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select throws_ok(
  $$select public.save_guest_profile_v1('f1000000-0000-4000-8000-0000000000a4'::uuid, '{"contact_number":"09170000000"}'::jsonb, null, 'cleaner attempt')$$,
  '42501','manage_operations denied','cleaner cannot save guest contact/ID fields'
);

-- Owner (manage_operations allowed) saves contact + ID fields; round-trips.
select set_config('request.jwt.claims', json_build_object('sub','f1000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is(
  (public.save_guest_profile_v1('f1000000-0000-4000-8000-0000000000a4'::uuid,
    '{"contact_number":"09171234567","birthday":"1990-05-01","address":"Purok 1","airbnb_profile_id":"abnb-123","id_on_file":true,"id_type":"passport","id_number":"P1234567","id_drive_url":"https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345/view"}'::jsonb,
    null, 'owner fills contact/ID')->>'ok')::boolean,
  true, 'owner save returns ok'
);
reset role;
select is((select contact_number from public.guest_profile_details where guest_id='f1000000-0000-4000-8000-0000000000a4'),'09171234567','contact_number round-trips');
select is((select id_number from public.guest_profile_details where guest_id='f1000000-0000-4000-8000-0000000000a4'),'P1234567','id_number round-trips');
select is((select id_on_file from public.guest_profile_details where guest_id='f1000000-0000-4000-8000-0000000000a4')::text,'true','id_on_file round-trips');

select * from finish();
rollback;
