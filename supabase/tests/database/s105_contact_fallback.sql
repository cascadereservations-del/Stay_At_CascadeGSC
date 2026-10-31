begin;
select plan(9);

insert into public.properties(id,name,is_active) values('e1000000-0000-4000-8000-0000000105a1','Synthetic s105',true);
insert into auth.users(id) values('e2000000-0000-4000-8000-0000000105a1'),('e2000000-0000-4000-8000-0000000105a2'),('e2000000-0000-4000-8000-0000000105a3');
insert into public.staff_access_profiles(user_id,role) values('e2000000-0000-4000-8000-0000000105a1','owner'),('e2000000-0000-4000-8000-0000000105a2','cleaner');
insert into public.staff_access_profiles(user_id,role,disabled_at) values('e2000000-0000-4000-8000-0000000105a3','admin',now());

-- g1: number only on the dashboard profile; g2: guests.phone wins over the profile; g3: blank guests.phone falls through; g4: nothing anywhere.
insert into public.guests(id,property_id,name,phone,phone_e164) values
  ('e3000000-0000-4000-8000-0000000105a1','e1000000-0000-4000-8000-0000000105a1','Synthetic One',null,null),
  ('e3000000-0000-4000-8000-0000000105a2','e1000000-0000-4000-8000-0000000105a1','Synthetic Two','0917 000 0002','+639170000002'),
  ('e3000000-0000-4000-8000-0000000105a3','e1000000-0000-4000-8000-0000000105a1','Synthetic Three','  ',null),
  ('e3000000-0000-4000-8000-0000000105a4','e1000000-0000-4000-8000-0000000105a1','Synthetic Four',null,null);
insert into public.guest_profile_details(guest_id,property_id,contact_number) values
  ('e3000000-0000-4000-8000-0000000105a1','e1000000-0000-4000-8000-0000000105a1','0917 000 0001'),
  ('e3000000-0000-4000-8000-0000000105a2','e1000000-0000-4000-8000-0000000105a1','0917 999 9999'),
  ('e3000000-0000-4000-8000-0000000105a3','e1000000-0000-4000-8000-0000000105a1','0917 000 0003');

select set_config('request.jwt.claims', json_build_object('sub','e2000000-0000-4000-8000-0000000105a1','role','authenticated')::text, true);
select is(public.staff_guest_contact_v1('e3000000-0000-4000-8000-0000000105a1')->>'phone','0917 000 0001','owner: a number saved only on the dashboard profile is returned');
select is(public.staff_guest_contact_v1('e3000000-0000-4000-8000-0000000105a2')->>'phone','+639170000002','owner: guests.phone_e164 still wins over the profile number');
select is(public.staff_guest_contact_v1('e3000000-0000-4000-8000-0000000105a3')->>'phone','0917 000 0003','owner: a blank guests.phone falls through to the profile number');
select ok(public.staff_guest_contact_v1('e3000000-0000-4000-8000-0000000105a4')->'phone' = 'null'::jsonb,'owner: no number anywhere gives a null phone');
select ok(public.staff_guest_contact_v1('e3000000-0000-4000-8000-0000000105a5')->'phone' = 'null'::jsonb,'owner: an unknown guest id gives a null phone, no error');

select set_config('request.jwt.claims', json_build_object('sub','e2000000-0000-4000-8000-0000000105a2','role','authenticated')::text, true);
select is(public.staff_guest_contact_v1('e3000000-0000-4000-8000-0000000105a1'),'{}'::jsonb,'cleaner: gets nothing, not the profile number');

select set_config('request.jwt.claims', json_build_object('sub','e2000000-0000-4000-8000-0000000105a3','role','authenticated')::text, true);
select is(public.staff_guest_contact_v1('e3000000-0000-4000-8000-0000000105a1'),'{}'::jsonb,'disabled admin: gets nothing');

select ok(not has_function_privilege('authenticated','public.staff_guest_contact_v1(uuid)','execute')
          and not has_function_privilege('anon','public.staff_guest_contact_v1(uuid)','execute')
          and not has_function_privilege('service_role','public.staff_guest_contact_v1(uuid)','execute'),'no role may call it directly');
select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.staff_guest_contact_v1(uuid)'::regprocedure),'still security definer with an empty search_path');

select * from finish();
rollback;
