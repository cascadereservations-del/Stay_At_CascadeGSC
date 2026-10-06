-- Session 74, lane G3: release money_fixes_20261007 part 1. A clean with no checkout or check-in date is paid on its MANILA day:
-- 23:30Z is 07:30 the next morning in Manila. Synthetic zz fixtures (uuids e7700000-...); the property and the rate rows the
-- function reads are inserted guarded, as staff_pay_requests.sql does. Everything rolls back.
begin;
select plan(8);

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true),
         set_config('role', 'authenticated', true)
$$;
grant execute on function pg_temp.as_user(uuid) to public;

-- the live bodies were patched: no UTC cast of cleaned_at left, the Manila cast present -------------------------------------
select ok((select p.prosrc !~ 'cleaned_at::date' and p.prosrc like '%cleaned_at at time zone ''Asia/Manila''%'
             from pg_proc p where p.oid = 'public.staff_pay_candidates_v1()'::regprocedure),
  'staff_pay_candidates_v1 groups a clean by its Manila date');
select ok((select p.prosrc !~ 'cleaned_at::date' and p.prosrc like '%cleaned_at at time zone ''Asia/Manila''%'
             from pg_proc p where p.oid = 'public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)'::regprocedure),
  'staff_pay_request_create_v1 books a clean on its Manila date');
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""']) from pg_proc p
            where p.oid in ('public.staff_pay_candidates_v1()'::regprocedure, 'public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)'::regprocedure)),
  'both stay security definer with an empty search_path');

-- fixtures -----------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');
insert into auth.users(id) values ('e7700000-0000-4000-8000-0000000000a1');
insert into public.staff_access_profiles(user_id, role) values ('e7700000-0000-4000-8000-0000000000a1', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values ('e7700000-0000-4000-8000-0000000000a1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
-- s1 07:30 Manila Oct 6 (= 23:30Z Oct 5), s2 23:30 Manila Oct 6 (= 15:30Z), s3 00:00 Manila Oct 7 (= 16:00Z), s4 has a checkout date that wins
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, cleaning_type, cleaned_at, checkout_date, submitted_by_user_id) values
  ('e7700000-0000-4000-8000-0000000000b1', 'zz-g3-s1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', 'turnover', timestamptz '2026-10-05 23:30:00+00', null, 'e7700000-0000-4000-8000-0000000000a1'),
  ('e7700000-0000-4000-8000-0000000000b2', 'zz-g3-s2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', 'turnover', timestamptz '2026-10-06 15:30:00+00', null, 'e7700000-0000-4000-8000-0000000000a1'),
  ('e7700000-0000-4000-8000-0000000000b3', 'zz-g3-s3', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', 'turnover', timestamptz '2026-10-06 16:00:00+00', null, 'e7700000-0000-4000-8000-0000000000a1'),
  ('e7700000-0000-4000-8000-0000000000b4', 'zz-g3-s4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', 'turnover', timestamptz '2026-10-05 23:30:00+00', date '2026-10-02', 'e7700000-0000-4000-8000-0000000000a1');

-- candidates --------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('e7700000-0000-4000-8000-0000000000a1');
insert into _t select 'cand', public.staff_pay_candidates_v1();
reset role;
select is((select v->>'ok' from _t where k = 'cand'), 'true', 'candidates answers the cleaner');
select is((select jsonb_agg(x->>'date' order by ord) from _t, jsonb_array_elements(v->'sessions') with ordinality as e(x, ord) where k = 'cand'),
  '["2026-10-02","2026-10-06","2026-10-06","2026-10-07"]'::jsonb,
  'a clean at 23:30Z is listed on its Manila day (Oct 6), 15:30Z stays Oct 6, 16:00Z is Oct 7, and a checkout date still wins');
select is((select (x->>'base')::numeric from _t, jsonb_array_elements(v->'sessions') as x where k = 'cand' and x->>'id' = 'e7700000-0000-4000-8000-0000000000b1'), 500::numeric,
  'the 23:30Z clean is priced with the rate in force on its Manila day');

-- request: the snapshot lines carry the Manila date --------------------------------------------------------------------------
select pg_temp.as_user('e7700000-0000-4000-8000-0000000000a1');
insert into _t select 'req', public.staff_pay_request_create_v1(
  '[{"id":"e7700000-0000-4000-8000-0000000000b1"},{"id":"e7700000-0000-4000-8000-0000000000b3"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-g3-manila-0001');
reset role;
select is((select v->>'ok' from _t where k = 'req'), 'true', 'a request for the two late-evening / early-morning cleans is created');
select is((select jsonb_agg(l->>'date' order by l->>'date') from _t, jsonb_array_elements(v->'lines') l where k = 'req'),
  '["2026-10-06","2026-10-07"]'::jsonb, 'the request lines are dated on the Manila day, not the previous UTC day');

select * from finish();
rollback;
