-- Session 60, D-282: release house_facts_20260929. The table is the service role's only; the seed is whole and in voice.
-- Every change goes with the closing rollback.
begin;
select plan(11);

select has_table('public', 'house_facts', 'house_facts exists');
select ok((select relrowsecurity from pg_class where oid = 'public.house_facts'::regclass), 'RLS is on');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'house_facts'), 0, 'no policy for anyone');
select ok(not has_table_privilege('anon', 'public.house_facts', 'select') and not has_table_privilege('authenticated', 'public.house_facts', 'select'), 'anon and authenticated cannot read it');
select ok(has_table_privilege('service_role', 'public.house_facts', 'select') and has_table_privilege('service_role', 'public.house_facts', 'insert') and has_table_privilege('service_role', 'public.house_facts', 'update'), 'service_role reads and writes it');
select col_type_is('public', 'concierge_threads', 'verified_until', 'date', 'concierge_threads.verified_until is a date');
select results_eq($$select tier, count(*)::int from public.house_facts where is_active group by tier order by tier$$,
  $$values ('guest'::text, 5), ('public'::text, 30), ('staff'::text, 9)$$, '44 seed rows: 30 public, 5 guest, 9 staff');
select is((select count(*)::int from public.house_facts where body like '%!%'), 0, 'no exclamation marks (Cassy voice)');
select is((select count(*)::int from public.house_facts where body ~ '3562|GCash|UnionBank|09\d{9}'), 0, 'no door code, payment rail or raw number in a row');
select throws_ok($$insert into public.house_facts(topic, title, body, tier) values ('zz-synthetic', 'x', 'x', 'secret')$$, '23514', null, 'a tier outside public/guest/staff is refused');
set local role anon;
select throws_ok($$select 1 from public.house_facts$$, '42501', null, 'anon select is refused');
reset role;

select * from finish();
rollback;
