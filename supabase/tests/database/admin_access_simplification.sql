begin;
select plan(12);

-- D-094: no assurance-level gate anywhere in the staff matrix.
select ok(public.staff_access_allowed('owner','read_finance',null,'aal1'), 'owner reads finance on a password session');
select ok(public.staff_access_allowed('admin','approve_payment',null,'aal1'), 'admin approves payments on a password session');
select ok(public.staff_access_allowed('admin','manage_staff',null,null), 'null aal is fine');
select ok(not public.staff_access_allowed('cleaner','read_finance',null,'aal2'), 'role matrix still applies');
select ok(not public.staff_access_allowed('owner','read_finance',now(),'aal2'), 'disabled profile still denied');
select ok((select prosrc not like '%aal2%' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='management_owner_authorized'), 'management_owner_authorized has no aal clause');

-- Grants and policies the new admin reads through.
select ok(has_table_privilege('authenticated','public.airbnb_reservations','select'), 'authenticated may select airbnb_reservations');
select ok(not has_table_privilege('anon','public.airbnb_reservations','select'), 'anon still may not');
select ok(has_table_privilege('authenticated','public.job_heartbeats','select'), 'authenticated may select job_heartbeats');
select policies_are('public','job_heartbeats',array['job_heartbeats_staff_read'],'job_heartbeats has exactly the staff read policy');

-- A named cleaner assigned to the property reads reservations of that property only.
insert into public.properties(id,name,is_active) values('e1000000-0000-4000-8000-0000000000d1','Synthetic Access',true),('e1000000-0000-4000-8000-0000000000d2','Other Property',false);
insert into auth.users(id) values('e2000000-0000-4000-8000-0000000000d1');
insert into public.staff_access_profiles(user_id,role) values('e2000000-0000-4000-8000-0000000000d1','cleaner');
insert into public.staff_property_access(user_id,property_id) values('e2000000-0000-4000-8000-0000000000d1','e1000000-0000-4000-8000-0000000000d1');
insert into public.airbnb_reservations(id,property_id,confirmation_code,status,guest_name,checkin_date,checkout_date) values
 ('e3000000-0000-4000-8000-0000000000d1','e1000000-0000-4000-8000-0000000000d1','HMD1','confirmed','Ana','2026-10-01','2026-10-03'),
 ('e3000000-0000-4000-8000-0000000000d2','e1000000-0000-4000-8000-0000000000d2','HMD2','confirmed','Ben','2026-10-01','2026-10-03');
select set_config('request.jwt.claims', json_build_object('sub','e2000000-0000-4000-8000-0000000000d1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select is((select count(*) from public.airbnb_reservations where confirmation_code in ('HMD1','HMD2')), 1::bigint, 'cleaner sees only her property');
select lives_ok($$select count(*) from public.job_heartbeats$$, 'cleaner can read heartbeats without error');

select * from finish();
rollback;
