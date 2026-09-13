begin;
select plan(22);

-- Objects
select has_table('public','follow_up_tasks','follow-up tasks table exists');
select has_table('public','work_orders','work orders table exists');
select has_table('public','readiness_reviews','readiness reviews table exists');
select has_table('public','guest_profile_details','guest profile details table exists');
select has_function('public','get_hospitality_metrics_v1',array['uuid','date','date'],'metrics RPC exists');
select has_function('public','get_admin_overview_v1',array['uuid'],'overview RPC exists');
select has_function('public','get_guest_timeline_v1',array['uuid'],'timeline RPC exists');
select ok(not has_function_privilege('anon','public.get_hospitality_metrics_v1(uuid,date,date)','execute'),'anon cannot read metrics');
select ok(not has_table_privilege('authenticated','public.work_orders','insert'),'work orders are written only through the RPC');

-- Synthetic fixtures: one property, an owner (aal2) and a cleaner.
insert into public.properties(id,name,is_active) values('e1000000-0000-4000-8000-0000000000a1','Synthetic Metrics',true);
insert into auth.users(id) values('e2000000-0000-4000-8000-0000000000a1'),('e2000000-0000-4000-8000-0000000000a2');
insert into public.staff_access_profiles(user_id,role) values('e2000000-0000-4000-8000-0000000000a1','owner'),('e2000000-0000-4000-8000-0000000000a2','cleaner');
insert into public.staff_property_access(user_id,property_id) values('e2000000-0000-4000-8000-0000000000a2','e1000000-0000-4000-8000-0000000000a1');
insert into public.app_settings(key,value) values('operating_start_date','"2026-01-01"'::jsonb) on conflict (key) do update set value = excluded.value;

-- Stays: A crosses the month boundary (Jan 30 -> Feb 2, 3 nights, 6000 gross),
-- B is cancelled, C is in the future, D has no amount (coverage gap).
insert into public.airbnb_reservations(id,property_id,confirmation_code,status,guest_name,checkin_date,checkout_date,guest_paid,host_service_fee,host_payout) values
 ('e3000000-0000-4000-8000-0000000000a1','e1000000-0000-4000-8000-0000000000a1','HMA','completed','Ana','2026-01-30','2026-02-02',6300,180,5820),
 ('e3000000-0000-4000-8000-0000000000a2','e1000000-0000-4000-8000-0000000000a1','HMB','cancelled','Ben','2026-02-10','2026-02-12',4000,120,3880),
 ('e3000000-0000-4000-8000-0000000000a3','e1000000-0000-4000-8000-0000000000a1','HMC','confirmed','Cy','2099-03-01','2099-03-03',4000,120,3880),
 ('e3000000-0000-4000-8000-0000000000a4','e1000000-0000-4000-8000-0000000000a1','HMD','completed','Dee','2026-02-20','2026-02-21',null,null,null);
insert into public.calendar_events(property_id,uid,source,checkin_date,checkout_date,status) values('e1000000-0000-4000-8000-0000000000a1','blk-1','airbnb','2026-02-05','2026-02-07','blocked');

-- Owner with aal2 sees finance metrics.
select set_config('request.jwt.claims', json_build_object('sub','e2000000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);

select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-02-01','2026-03-01')->'metrics'->'sold_nights'->>'value'),'2','February sold nights: 1 of stay A (Feb 1) + 1 of stay D; cancelled and future excluded');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-01-01','2026-02-01')->'metrics'->'sold_nights'->>'value'),'2','January sold nights: Jan 30 and Jan 31 of stay A');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-02-01','2026-03-01')->'metrics'->'capacity_nights'->>'value'),'28','February capacity is 28 nights');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-02-01','2026-03-01')->>'blockedNights'),'2','blocked nights are reported, not sold');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-01-01','2026-02-01')->'metrics'->'accommodation_revenue'->>'value'),'4000.00','January revenue = 2 of 3 nights of 6000 (host payout + fee) allocated evenly');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-02-01','2026-03-01')->'metrics'->'accommodation_revenue'->>'coverage'),'partial','February revenue coverage is partial because stay D has no amount');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-02-01','2026-03-01')->'metrics'->'revpar'->>'value'),null,'RevPAR is withheld under partial coverage');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-02-01','2026-03-01')->'metrics'->'future_booked_nights'->>'value'),'2','future nights are reported separately');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2025-06-01','2025-07-01')->'metrics'->'occupancy'->>'value'),null,'zero sellable nights yields null, not 0');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-02-01','2026-03-01')->'metrics'->'cancellation_rate'->>'value'),'50.00','cancellation cohort by scheduled arrival: 1 of 2 (A arrives in January, C in 2099)');

-- Cleaner (aal1) gets operational metrics without finance values.
select set_config('request.jwt.claims', json_build_object('sub','e2000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-02-01','2026-03-01')->>'financeVisible'),'false','cleaner does not see finance metrics');
select is((public.get_hospitality_metrics_v1('e1000000-0000-4000-8000-0000000000a1','2026-02-01','2026-03-01')->'metrics'->'accommodation_revenue'->>'coverage'),'missing','finance metric is missing, not zero, for operational roles');
select throws_ok($$select public.get_report_drilldown_v1('e1000000-0000-4000-8000-0000000000a1','adr|v1|e1000000-0000-4000-8000-0000000000a1|2026-02-01|2026-03-01')$$,'42501','finance drilldown denied','drilldown re-authorises');

select * from finish();
rollback;
