begin;
select plan(21);
select has_table('public','cleaning_verification_evidence','evidence table exists');
select has_table('public','cleaning_verification_reviews','review table exists');
select has_function('public','record_cleaning_verification_evidence',array['uuid','uuid','text','text','text','text','text[]','text'],'named evidence RPC exists');
select has_function('public','review_cleaning_verification',array['uuid','text','text','text'],'named review RPC exists');
select ok(not has_function_privilege('service_role','public.review_cleaning_verification(uuid,text,text,text)','execute'),'service cannot review');
select ok(not has_table_privilege('authenticated','public.cleaning_verification_reviews','insert'),'staff cannot fabricate reviews');

insert into public.properties(id,name,is_active) values('b1000000-0000-4000-8000-000000000001','Synthetic Cleaning Property',true) on conflict(id) do nothing;
insert into auth.users(id) values('b2000000-0000-4000-8000-000000000001'),('b2000000-0000-4000-8000-000000000002'),('b2000000-0000-4000-8000-000000000003') on conflict(id) do nothing;
insert into public.staff_access_profiles(user_id,role,disabled_at,sessions_revoked_after) values
 ('b2000000-0000-4000-8000-000000000001','cleaner',null,null),('b2000000-0000-4000-8000-000000000002','inspector',null,null),('b2000000-0000-4000-8000-000000000003','admin',null,null)
on conflict(user_id) do update set role=excluded.role,disabled_at=null,sessions_revoked_after=null;
insert into public.staff_property_access(user_id,property_id) values
 ('b2000000-0000-4000-8000-000000000001','b1000000-0000-4000-8000-000000000001'),('b2000000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000001'),('b2000000-0000-4000-8000-000000000003','b1000000-0000-4000-8000-000000000001') on conflict do nothing;
insert into public.cleaning_sessions(id,submission_id,cleaner_name,property_id,submitted_by_user_id)
values('b3000000-0000-4000-8000-000000000001','wave3-session-1','Synthetic Cleaner','b1000000-0000-4000-8000-000000000001','b2000000-0000-4000-8000-000000000001');
insert into public.meter_readings(id,session_id,property_id,submitted_by_user_id,electric_prev,electric_curr)
values('b4000000-0000-4000-8000-000000000001','b3000000-0000-4000-8000-000000000001','b1000000-0000-4000-8000-000000000001','b2000000-0000-4000-8000-000000000001',100,110);

set local role authenticated;
set local request.jwt.claims='{"sub":"b2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select set_config('cascade.w3_evidence',public.record_cleaning_verification_evidence(
 'b3000000-0000-4000-8000-000000000001','b4000000-0000-4000-8000-000000000001','meter_photo',repeat('a',64),repeat('b',64),'uncertain',array['digits_unclear'],'wave3-meter-evidence-0001')::text,true);
select is(public.record_cleaning_verification_evidence(
 'b3000000-0000-4000-8000-000000000001','b4000000-0000-4000-8000-000000000001','meter_photo',repeat('a',64),repeat('b',64),'uncertain',array['digits_unclear'],'wave3-meter-evidence-0001'),current_setting('cascade.w3_evidence')::uuid,'evidence retry is idempotent');
select throws_ok($$select public.review_cleaning_verification(current_setting('cascade.w3_evidence')::uuid,'accepted','Cleaner self approval','wave3-cleaner-review-0001')$$,'42501',null,'cleaner cannot self approve');
set local request.jwt.claims='{"sub":"b2000000-0000-4000-8000-000000000002","aal":"aal1"}';
select set_config('cascade.w3_review',public.review_cleaning_verification(current_setting('cascade.w3_evidence')::uuid,'inspection_required','Meter digits remain unclear','wave3-inspector-review-01')::text,true);
select is(public.review_cleaning_verification(current_setting('cascade.w3_evidence')::uuid,'inspection_required','Meter digits remain unclear','wave3-inspector-review-01'),current_setting('cascade.w3_review')::uuid,'review retry is idempotent');
select throws_ok($$select public.review_cleaning_verification(current_setting('cascade.w3_evidence')::uuid,'overridden','Inspector override attempt','wave3-inspector-override-1')$$,'42501',null,'inspector cannot override');
reset role;
select is((select submitted_by_user_id from public.cleaning_verification_evidence where id=current_setting('cascade.w3_evidence')::uuid),'b2000000-0000-4000-8000-000000000001'::uuid,'evidence names cleaner');
select is((select reviewer_user_id from public.cleaning_verification_reviews where id=current_setting('cascade.w3_review')::uuid),'b2000000-0000-4000-8000-000000000002'::uuid,'review names inspector');
select is((select outcome from public.cleaning_verification_reviews where id=current_setting('cascade.w3_review')::uuid),'inspection_required','uncertainty stays unresolved');
select is((select electric_curr from public.meter_readings where id='b4000000-0000-4000-8000-000000000001'),110::numeric,'review does not alter meter fact');
select is((select count(*) from public.transactions where external_ref='b3000000-0000-4000-8000-000000000001'),0::bigint,'verification creates no Finance row');
select ok((select relrowsecurity from pg_class where oid='public.cleaning_verification_evidence'::regclass),'evidence RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.cleaning_verification_reviews'::regclass),'review RLS enabled');
select ok(not has_table_privilege('anon','public.cleaning_verification_evidence','select'),'anonymous cannot read evidence');
select ok(not has_table_privilege('service_role','public.cleaning_verification_evidence','select'),'service cannot browse evidence');
select ok(has_function_privilege('authenticated','public.review_cleaning_verification(uuid,text,text,text)','execute'),'authenticated staff enter guarded review');
select is((select count(*) from public.cleaning_verification_reviews where evidence_id=current_setting('cascade.w3_evidence')::uuid),1::bigint,'one review row retained');
select * from finish();
rollback;
