begin;
select plan(43);

select has_table('public','booking_holds','booking holds exist');
select has_table('public','booking_rate_policy_versions','versioned rate policies exist');
select has_table('public','booking_refund_authorizations','refund authorizations exist');
select has_table('public','booking_lifecycle_events','append-only lifecycle audit exists');
select has_function('public','create_booking_hold',array['uuid','timestamp with time zone','text'],'guarded hold RPC exists');
select has_function('public','expire_booking_holds',array['timestamp with time zone','integer'],'hold expiry RPC exists');
select has_function('public','record_booking_lifecycle_action',array['uuid','text','text','text','date','date'],'human lifecycle RPC exists');
select has_function('public','authorize_booking_refund',array['uuid','numeric','text','text','text'],'named refund authorization exists');
select ok(not has_table_privilege('service_role','public.booking_refund_authorizations','insert'),'service cannot fabricate refund approval');
select ok(not has_function_privilege('service_role','public.authorize_booking_refund(uuid,numeric,text,text,text)','execute'),'service cannot authorize a refund');
select ok(not has_function_privilege('service_role','public.record_booking_lifecycle_action(uuid,text,text,text,date,date)','execute'),'service cannot impersonate lifecycle manager');
select ok(has_function_privilege('service_role','public.create_booking_hold(uuid,timestamp with time zone,text)','execute'),'submission service may create holds');
select ok(not has_table_privilege('authenticated','public.booking_lifecycle_events','update'),'audit is append-only to staff');

insert into public.properties(id,name,is_active)
values('81000000-0000-4000-8000-000000000001','Synthetic Lifecycle Property',true)
on conflict(id) do nothing;
insert into auth.users(id) values
 ('82000000-0000-4000-8000-000000000001'),
 ('82000000-0000-4000-8000-000000000002'),
 ('82000000-0000-4000-8000-000000000003')
on conflict(id) do nothing;
insert into public.staff_access_profiles(user_id,role,disabled_at,sessions_revoked_after) values
 ('82000000-0000-4000-8000-000000000001','admin',null,null),
 ('82000000-0000-4000-8000-000000000002','finance',null,null),
 ('82000000-0000-4000-8000-000000000003','cleaner',null,null)
on conflict(user_id) do update set role=excluded.role,disabled_at=null,sessions_revoked_after=null;
insert into public.staff_property_access(user_id,property_id) values
 ('82000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000001'),
 ('82000000-0000-4000-8000-000000000002','81000000-0000-4000-8000-000000000001'),
 ('82000000-0000-4000-8000-000000000003','81000000-0000-4000-8000-000000000001')
on conflict do nothing;

insert into public.booking_inquiries(
 id,property_id,guest_name,guest_phone,checkin_date,checkout_date,source,status,total_amount,deposit_amount
) values
 ('83000000-0000-4000-8000-000000000001','81000000-0000-4000-8000-000000000001','Hold One','000',current_date+100,current_date+102,'direct','pending',4000,2000),
 ('83000000-0000-4000-8000-000000000002','81000000-0000-4000-8000-000000000001','Hold Collision','000',current_date+101,current_date+103,'direct','pending',4000,2000),
 ('83000000-0000-4000-8000-000000000003','81000000-0000-4000-8000-000000000001','Amend','000',current_date+110,current_date+112,'direct','confirmed',4000,2000),
 ('83000000-0000-4000-8000-000000000004','81000000-0000-4000-8000-000000000001','Cancel','000',current_date+120,current_date+122,'direct','confirmed',4000,2000),
 ('83000000-0000-4000-8000-000000000005','81000000-0000-4000-8000-000000000001','No Show','000',current_date+130,current_date+132,'direct','confirmed',4000,2000),
 ('83000000-0000-4000-8000-000000000006','81000000-0000-4000-8000-000000000001','Reconcile','000',current_date+140,current_date+142,'direct','confirmed',4000,2000),
 ('83000000-0000-4000-8000-000000000007','81000000-0000-4000-8000-000000000001','Timezone Hold','000',current_date+150,current_date+152,'direct','pending',4000,2000);
insert into public.calendar_events(property_id,uid,source,status,checkin_date,checkout_date,recon_status)
values
 ('81000000-0000-4000-8000-000000000001','cascade-direct-83000000-0000-4000-8000-000000000003','direct','confirmed',current_date+110,current_date+112,'matched'),
 ('81000000-0000-4000-8000-000000000001','cascade-direct-83000000-0000-4000-8000-000000000004','direct','confirmed',current_date+120,current_date+122,'matched'),
 ('81000000-0000-4000-8000-000000000001','cascade-direct-83000000-0000-4000-8000-000000000005','direct','confirmed',current_date+130,current_date+132,'matched');

set local role authenticated;
set local request.jwt.claims='{"sub":"82000000-0000-4000-8000-000000000001","aal":"aal2"}';
select set_config('cascade.e_policy',public.publish_booking_rate_policy(
 '81000000-0000-4000-8000-000000000001',current_date,current_date+365,2000,'php','{"minimum_nights":2}',
 'Approved seasonal rate','module-e-rate-policy-0001'
)::text,true);
select is(public.publish_booking_rate_policy(
 '81000000-0000-4000-8000-000000000001',current_date,current_date+365,2000,'PHP','{"minimum_nights":2}',
 'Approved seasonal rate','module-e-rate-policy-0001'
),current_setting('cascade.e_policy')::uuid,'rate publication retry is idempotent');
select is((select approved_by from public.booking_rate_policy_versions where id=current_setting('cascade.e_policy')::uuid),
 '82000000-0000-4000-8000-000000000001'::uuid,'rate version names its human approver');
reset role;

set local role service_role;
select set_config('cascade.e_hold',(public.create_booking_hold(
 '83000000-0000-4000-8000-000000000001',now()+interval '10 minutes','module-e-booking-hold-0001'
)->>'hold_id'),true);
select is(public.create_booking_hold(
 '83000000-0000-4000-8000-000000000001',now()+interval '10 minutes','module-e-booking-hold-0001'
)->>'already_processed','true','hold retry is idempotent');
select throws_ok(
 $$select public.create_booking_hold('83000000-0000-4000-8000-000000000002',now()+interval '10 minutes','module-e-collision-hold-001')$$,
 '23P01',null,'overlapping hold fails under the property lock');
reset role;
select throws_ok(
 $$update public.booking_inquiries set status='confirmed' where id='83000000-0000-4000-8000-000000000002'$$,
 '23P01',null,'a competing active hold also blocks confirmation');
set local role service_role;
select set_config('cascade.e_expired',public.expire_booking_holds(now()+interval '11 minutes',10)::text,true);
select set_config('cascade.e_expired_retry',public.expire_booking_holds(now()+interval '11 minutes',10)::text,true);
reset role;
select is((select rate_policy_version_id from public.booking_holds where id=current_setting('cascade.e_hold')::uuid),
 current_setting('cascade.e_policy')::uuid,'hold snapshots the effective rate version');
select is(current_setting('cascade.e_expired')::integer,1,'expiry worker closes one due hold');
select is((select status from public.booking_holds where id=current_setting('cascade.e_hold')::uuid),'expired','hold is expired');
select is((select status from public.booking_inquiries where id='83000000-0000-4000-8000-000000000001'),'expired','pending booking records expiry');
select is(current_setting('cascade.e_expired_retry')::integer,0,'expiry retry is idempotent');
select throws_ok(
 $$update public.booking_inquiries set status='confirmed' where id='83000000-0000-4000-8000-000000000001'$$,
 '23514',null,'an expired booking cannot be confirmed later');

set local timezone='Asia/Manila';
set local role service_role;
select set_config('cascade.e_tz_hold',(public.create_booking_hold(
 '83000000-0000-4000-8000-000000000007',now()+interval '10 minutes','module-e-timezone-hold-001'
)->>'hold_id'),true);
set local timezone='UTC';
select set_config('cascade.e_tz_expired',public.expire_booking_holds(now()+interval '11 minutes',10)::text,true);
reset role;
select is(current_setting('cascade.e_tz_expired')::integer,1,'absolute expiry survives a timezone change');
select is((select status from public.booking_holds where id=current_setting('cascade.e_tz_hold')::uuid),'expired','timezone test hold expires once');

set local role authenticated;
set local request.jwt.claims='{"sub":"82000000-0000-4000-8000-000000000003","aal":"aal2"}';
select throws_ok(
 $$select public.record_booking_lifecycle_action('83000000-0000-4000-8000-000000000003','cancel','module-e-cleaner-cancel-01','Cleaner attempted cancellation',null,null)$$,
 '42501',null,'OPS cleaner cannot change booking lifecycle');
select throws_ok(
 $$select public.authorize_booking_refund('83000000-0000-4000-8000-000000000004',500,'PHP','Cleaner attempted refund','module-e-cleaner-refund-01')$$,
 '42501',null,'OPS cleaner cannot authorize refund');

set local request.jwt.claims='{"sub":"82000000-0000-4000-8000-000000000001","aal":"aal2"}';
select is(public.record_booking_lifecycle_action(
 '83000000-0000-4000-8000-000000000003','amend','module-e-amend-booking-001','Guest requested new dates',current_date+113,current_date+115
)->>'already_processed','false','admin records amendment');
select is(public.record_booking_lifecycle_action(
 '83000000-0000-4000-8000-000000000003','amend','module-e-amend-booking-001','Guest requested new dates',current_date+113,current_date+115
)->>'already_processed','true','amendment retry is idempotent');
select lives_ok(
 $$select public.record_booking_lifecycle_action('83000000-0000-4000-8000-000000000004','cancel','module-e-cancel-booking-01','Guest requested cancellation',null,null)$$,
 'admin records cancellation');
select lives_ok(
 $$select public.record_booking_lifecycle_action('83000000-0000-4000-8000-000000000005','no_show','module-e-no-show-booking-1','Guest did not arrive',null,null)$$,
 'admin records no-show');
select lives_ok(
 $$select public.record_booking_lifecycle_action('83000000-0000-4000-8000-000000000006','reconcile_calendar','module-e-reconcile-cal-001','Repair missing calendar projection',null,null)$$,
 'admin reconciles a missing projection');
set local request.jwt.claims='{"sub":"82000000-0000-4000-8000-0000000000ff","aal":"aal1"}';
select throws_ok(
 $$select public.authorize_booking_refund('83000000-0000-4000-8000-000000000004',500,'PHP','AAL1 refund attempt','module-e-aal1-refund-0001')$$,
 '42501',null,'unknown user cannot authorize a refund (aal no longer gates, D-094)');
set local request.jwt.claims='{"sub":"82000000-0000-4000-8000-000000000002","aal":"aal2"}';
select set_config('cascade.e_refund',(public.authorize_booking_refund(
 '83000000-0000-4000-8000-000000000004',500,'php','Reviewed cancellation refund','module-e-finance-refund-01'
)->>'authorization_id'),true);
select is(public.authorize_booking_refund(
 '83000000-0000-4000-8000-000000000004',500,'PHP','Reviewed cancellation refund','module-e-finance-refund-01'
)->>'already_processed','true','refund authorization retry is idempotent');
reset role;

select is((select checkin_date from public.calendar_events where uid='cascade-direct-83000000-0000-4000-8000-000000000003'),current_date+113,'calendar projection follows amendment');
select is((select status from public.calendar_events where uid='cascade-direct-83000000-0000-4000-8000-000000000004'),'cancelled','cancellation releases calendar occupancy');
select is((select status from public.calendar_events where uid='cascade-direct-83000000-0000-4000-8000-000000000005'),'confirmed','no-show does not rewrite historical occupancy');
select is((select count(*) from public.calendar_events where uid='cascade-direct-83000000-0000-4000-8000-000000000006'),1::bigint,'reconciliation creates one canonical projection');
select is((select reviewer_user_id from public.booking_refund_authorizations where id=current_setting('cascade.e_refund')::uuid),
 '82000000-0000-4000-8000-000000000002'::uuid,'refund authorization names the Finance reviewer');
select is((select status from public.booking_inquiries where id='83000000-0000-4000-8000-000000000004'),'cancelled','refund authorization does not alter booking state');
select is((select count(*) from public.booking_decisions where booking_id='83000000-0000-4000-8000-000000000006'),0::bigint,'lifecycle actions never fabricate confirmation decisions');
select ok((select count(*) >= 8 from public.booking_lifecycle_events),'every lifecycle operation leaves audit history');

select * from finish();
rollback;
