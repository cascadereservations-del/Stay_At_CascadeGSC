begin;
select plan(50);

select has_table('public','finance_reconciliation_candidates','candidate table exists');
select has_table('public','finance_reconciliation_reviews','review table exists');
select has_table('public','finance_reconciled_facts','fact table exists');
select has_table('public','management_target_versions','target table exists');
select has_function('public','record_finance_reconciliation',array['uuid','text','date','text','text','text','text','text','text','numeric','text','text','text','numeric','text'],'candidate RPC exists');
select has_function('public','review_finance_reconciliation',array['uuid','text','numeric','text','text'],'review RPC exists');
select has_function('public','get_management_metrics',array['uuid','date','date'],'metrics RPC exists');
select has_function('public','publish_management_target',array['uuid','text','numeric','text','date','date','text','text'],'target RPC exists');
select ok(not has_function_privilege('service_role','public.review_finance_reconciliation(uuid,text,numeric,text,text)','execute'),'service cannot reconcile');
select ok(not has_table_privilege('authenticated','public.finance_reconciled_facts','insert'),'facts cannot be forged');
select ok(not has_table_privilege('anon','public.finance_reconciliation_candidates','select'),'anonymous cannot browse Finance');

insert into public.properties(id,name,is_active) values('e1000000-0000-4000-8000-000000000001','Synthetic Finance',true);
insert into auth.users(id) values('e2000000-0000-4000-8000-000000000001'),('e2000000-0000-4000-8000-000000000002'),('e2000000-0000-4000-8000-000000000003');
insert into public.staff_access_profiles(user_id,role) values
 ('e2000000-0000-4000-8000-000000000001','finance'),
 ('e2000000-0000-4000-8000-000000000002','cleaner'),
 ('e2000000-0000-4000-8000-000000000003','owner');
insert into public.staff_property_access(user_id,property_id) values
 ('e2000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001'),
 ('e2000000-0000-4000-8000-000000000002','e1000000-0000-4000-8000-000000000001');

create function pg_temp.make_candidate(p_kind text,p_unit text,p_value numeric,p_key text,p_channel text default 'not_applicable')
returns uuid language sql as $$
  select public.record_finance_reconciliation(
    'e1000000-0000-4000-8000-000000000001',p_kind,current_date,p_unit,'synthetic_general',p_channel,
    'ledger_transaction','primary_'||p_key,md5('primary_'||p_key)||md5('primary_'||p_key),p_value,
    'approved_expense','counter_'||p_key,md5('counter_'||p_key)||md5('counter_'||p_key),p_value,p_key
  );
$$;
create function pg_temp.add_fact(p_kind text,p_unit text,p_value numeric,p_key text,p_channel text default 'not_applicable')
returns void language plpgsql as $$
declare v_candidate uuid;
begin
  v_candidate:=pg_temp.make_candidate(p_kind,p_unit,p_value,p_key,p_channel);
  perform public.review_finance_reconciliation(v_candidate,'approved',p_value,'Synthetic reconciliation','review_'||p_key);
end;
$$;

set local role authenticated;
set local request.jwt.claims='{"sub":"e2000000-0000-4000-8000-0000000000ff","aal":"aal1"}';
select throws_ok($$select pg_temp.make_candidate('operating_expense','PHP',300,'wave5-aal1-candidate-01')$$,'42501',null,'Unknown user denied (aal no longer gates, D-094)');
set local request.jwt.claims='{"sub":"e2000000-0000-4000-8000-000000000002","aal":"aal2"}';
select throws_ok($$select pg_temp.make_candidate('operating_expense','PHP',300,'wave5-cleaner-candidate1')$$,'42501',null,'OPS denied');
set local request.jwt.claims='{"sub":"e2000000-0000-4000-8000-000000000001","aal":"aal2"}';

select set_config('cascade.w5_exact',pg_temp.make_candidate('gross_booking_income','PHP',900,'wave5-income-fact-001','direct')::text,true);
select is(pg_temp.make_candidate('gross_booking_income','PHP',900,'wave5-income-fact-001','direct'),current_setting('cascade.w5_exact')::uuid,'candidate retry stable');
select is((select comparison_outcome from public.finance_reconciliation_candidates where id=current_setting('cascade.w5_exact')::uuid),'exact_match','equal values match');
select is((select value_delta from public.finance_reconciliation_candidates where id=current_setting('cascade.w5_exact')::uuid),0::numeric,'exact delta zero');

select set_config('cascade.w5_missing',public.record_finance_reconciliation(
 'e1000000-0000-4000-8000-000000000001','operating_expense',current_date,'PHP','missing_receipt','not_applicable',
 'ledger_transaction','primary_missing_001',repeat('a',64),100,null,null,null,null,'wave5-missing-fact-001')::text,true);
select is((select comparison_outcome from public.finance_reconciliation_candidates where id=current_setting('cascade.w5_missing')::uuid),'missing_fields','missing counterpart flagged');
select throws_ok($$select public.review_finance_reconciliation(current_setting('cascade.w5_missing')::uuid,'approved',100,'Unsupported approval','wave5-missing-review-01')$$,'22023','reconciled value not supported','missing evidence cannot approve');

select set_config('cascade.w5_mismatch',public.record_finance_reconciliation(
 'e1000000-0000-4000-8000-000000000001','operating_expense',current_date,'PHP','mismatch_expense','not_applicable',
 'ledger_transaction','primary_mismatch_01',repeat('b',64),1000,'approved_expense','counter_mismatch_1',repeat('c',64),900,'wave5-mismatch-fact-01')::text,true);
select is((select comparison_outcome from public.finance_reconciliation_candidates where id=current_setting('cascade.w5_mismatch')::uuid),'mismatch','difference flagged');
select is((select value_delta from public.finance_reconciliation_candidates where id=current_setting('cascade.w5_mismatch')::uuid),100::numeric,'difference recorded');
select lives_ok($$select public.review_finance_reconciliation(current_setting('cascade.w5_mismatch')::uuid,'needs_follow_up',null,'Check source difference','wave5-followup-review01')$$,'follow-up retained');
select is((select count(*) from public.finance_reconciled_facts where candidate_id=current_setting('cascade.w5_mismatch')::uuid),0::bigint,'follow-up creates no fact');
select throws_ok($$select public.review_finance_reconciliation(current_setting('cascade.w5_mismatch')::uuid,'approved',950,'Unsupported midpoint','wave5-midpoint-review-01')$$,'22023','reconciled value not supported','unsupported midpoint denied');
select set_config('cascade.w5_mismatch_review',public.review_finance_reconciliation(current_setting('cascade.w5_mismatch')::uuid,'approved',900,'Counterpart verified','wave5-final-review-0001')::text,true);
select is((select reconciled_value from public.finance_reconciled_facts where candidate_id=current_setting('cascade.w5_mismatch')::uuid),900::numeric,'reviewed source value becomes fact');
select is((select reconciled_by_user_id from public.finance_reconciled_facts where candidate_id=current_setting('cascade.w5_mismatch')::uuid),'e2000000-0000-4000-8000-000000000001'::uuid,'named reconciler captured');
select is(public.review_finance_reconciliation(current_setting('cascade.w5_mismatch')::uuid,'approved',900,'Counterpart verified','wave5-final-review-0001'),current_setting('cascade.w5_mismatch_review')::uuid,'review retry stable');

select set_config('cascade.w5_duplicate',public.record_finance_reconciliation(
 'e1000000-0000-4000-8000-000000000001','operating_expense',current_date,'PHP','duplicate_expense','not_applicable',
 'ledger_transaction','primary_duplicate_01',repeat('b',64),1000,'approved_expense','counter_duplicate_1',repeat('d',64),1000,'wave5-duplicate-fact-01')::text,true);
select is((select comparison_outcome from public.finance_reconciliation_candidates where id=current_setting('cascade.w5_duplicate')::uuid),'duplicate_source','reused source hash flagged');
select throws_ok($$select public.review_finance_reconciliation(current_setting('cascade.w5_duplicate')::uuid,'approved',1000,'Duplicate approval','wave5-duplicate-review01')$$,'22023','reconciled value not supported','duplicate cannot approve');

select public.review_finance_reconciliation(current_setting('cascade.w5_exact')::uuid,'approved',900,'Direct booking verified','wave5-income-review-001');
select pg_temp.add_fact('operating_expense','PHP',300,'wave5-expense-fact-001');
select pg_temp.add_fact('occupied_nights','night',4,'wave5-occupied-fact-01');
select pg_temp.add_fact('available_nights','night',10,'wave5-available-fact-1');
select pg_temp.add_fact('electricity_usage','kWh',20,'wave5-electric-use-001');
select pg_temp.add_fact('electricity_cost','PHP',200,'wave5-electric-cost-01');
select pg_temp.add_fact('water_usage','m3',3,'wave5-water-use-fact1');
select pg_temp.add_fact('water_cost','PHP',60,'wave5-water-cost-fact');
select pg_temp.add_fact('nonoperating_exclusion','PHP',50,'wave5-excluded-fact-01');
select set_config('cascade.w5_metrics',public.get_management_metrics('e1000000-0000-4000-8000-000000000001',current_date-9,current_date)::text,true);
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,gross_booking_income}')::numeric,900::numeric,'gross income from reconciled facts');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,operating_expenses}')::numeric,1200::numeric,'approved operating expenses include reconciled mismatch and expense');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,operating_profit}')::numeric,-300::numeric,'operating profit formula');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,cost_per_available_night}')::numeric,120::numeric,'cost per available night');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,cost_per_occupied_night}')::numeric,300::numeric,'cost per occupied night');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,adr}')::numeric,225::numeric,'ADR');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,revpar}')::numeric,90::numeric,'RevPAR');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,occupancy_pct}')::numeric,40::numeric,'occupancy');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,electricity_daily_kwh}')::numeric,2::numeric,'daily electricity use');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{metrics,water_daily_m3}')::numeric,0.3::numeric,'daily water use');
select is((current_setting('cascade.w5_metrics')::jsonb#>>'{exclusions,nonoperating_amount}')::numeric,50::numeric,'non-operating amount excluded');
select ok(current_setting('cascade.w5_metrics')::jsonb->>'data_freshness' is not null,'data freshness disclosed');
select is((current_setting('cascade.w5_metrics')::jsonb->>'internal_management_only')::boolean,true,'internal label present');
select is((current_setting('cascade.w5_metrics')::jsonb->>'statutory_or_tax_compliance')::boolean,false,'no compliance claim');

select throws_ok($$select public.publish_management_target('e1000000-0000-4000-8000-000000000001','occupancy_pct',50,'percent',current_date-30,null,'Owner target','wave5-target-occupancy1')$$,'42501',null,'Finance cannot publish owner target');
set local request.jwt.claims='{"sub":"e2000000-0000-4000-8000-000000000003","aal":"aal2"}';
select set_config('cascade.w5_target',public.publish_management_target('e1000000-0000-4000-8000-000000000001','occupancy_pct',50,'percent',current_date-30,null,'Owner target','wave5-target-occupancy1')::text,true);
select is(public.publish_management_target('e1000000-0000-4000-8000-000000000001','occupancy_pct',50,'percent',current_date-30,null,'Owner target','wave5-target-occupancy1'),current_setting('cascade.w5_target')::uuid,'target retry stable');
select throws_ok($$select public.publish_management_target('e1000000-0000-4000-8000-000000000001','occupancy_pct',55,'percent',current_date-30,null,'Owner target','wave5-target-occupancy1')$$,'22023','target idempotency conflict','changed target retry denied');
select throws_ok($$select public.publish_management_target('e1000000-0000-4000-8000-000000000001','occupancy_pct',60,'percent',current_date,null,'Overlapping target','wave5-target-overlap-01')$$,'23P01','target effective dates overlap','target overlap denied');
set local request.jwt.claims='{"sub":"e2000000-0000-4000-8000-000000000001","aal":"aal2"}';
select is((public.get_management_metrics('e1000000-0000-4000-8000-000000000001',current_date-9,current_date)#>>'{targets,occupancy_pct,value}')::numeric,50::numeric,'effective owner target shown');
set local request.jwt.claims='{"sub":"e2000000-0000-4000-8000-000000000002","aal":"aal2"}';
select throws_ok($$select public.get_management_metrics('e1000000-0000-4000-8000-000000000001',current_date-9,current_date)$$,'42501',null,'OPS cannot read metrics');
select is((select count(*) from public.finance_reconciled_facts),0::bigint,'OPS cannot browse facts');
reset role;
update public.staff_access_profiles set disabled_at=now() where user_id='e2000000-0000-4000-8000-000000000001';
set local role authenticated;
set local request.jwt.claims='{"sub":"e2000000-0000-4000-8000-000000000001","aal":"aal2"}';
select throws_ok($$select public.get_management_metrics('e1000000-0000-4000-8000-000000000001',current_date-9,current_date)$$,'42501',null,'disabled Finance denied');

select * from finish();
rollback;
