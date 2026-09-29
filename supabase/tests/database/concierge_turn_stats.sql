-- Session 62, D-285: release concierge_turn_stats_20260929. The table is the service role's only; the weekly read skips
-- probe rows and rows before the week, and names the top two lint rules by count. Every change goes with the closing rollback.
begin;
select plan(10);

select has_table('public', 'concierge_turn_stats', 'concierge_turn_stats exists');
select ok((select relrowsecurity from pg_class where oid = 'public.concierge_turn_stats'::regclass), 'RLS is on');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'concierge_turn_stats'), 0, 'no policy for anyone');
select ok(not has_table_privilege('anon', 'public.concierge_turn_stats', 'select') and not has_table_privilege('anon', 'public.concierge_turn_stats', 'insert')
  and not has_table_privilege('authenticated', 'public.concierge_turn_stats', 'select'), 'anon and authenticated cannot read or write it');
select ok(has_table_privilege('service_role', 'public.concierge_turn_stats', 'select') and has_table_privilege('service_role', 'public.concierge_turn_stats', 'insert'), 'service_role reads and writes it');
select ok(not has_function_privilege('anon', 'public.cassy_week_v1(timestamptz)', 'execute')
  and not has_function_privilege('authenticated', 'public.cassy_week_v1(timestamptz)', 'execute'), 'cassy_week_v1 is not executable by anon or authenticated');

insert into public.concierge_turn_stats (at, probe, lint, house, miss) values
  ('2030-01-10', false, '{too_long,two_asks}', 'miss', 'parking gate'),
  ('2030-01-10', false, '{too_long}',          'miss', 'parking gate'),
  ('2030-01-10', false, '{exclaim}',           'miss', 'laundry'),
  ('2030-01-10', false, '{}',                  'hit',  null),
  ('2030-01-10', false, '{}',                  null,   null),
  ('2030-01-10', true,  '{exclaim,exclaim}',   'miss', 'probe words'),  -- a probe never counts
  ('2029-12-01', false, '{exclaim,exclaim}',   'miss', 'old words');    -- before the week never counts

select is((public.cassy_week_v1('2030-01-01') - 'rules' - 'teach'), '{"turns": 5, "linted": 3, "misses": 3}'::jsonb, 'counts skip probes and rows before p_since');
select is(public.cassy_week_v1('2030-01-01') -> 'rules', '[{"rule": "too_long", "n": 2}, {"rule": "exclaim", "n": 1}]'::jsonb, 'top two rules, most first, ties by name');
select is(public.cassy_week_v1('2030-01-01') -> 'teach', '[{"words": "parking gate", "n": 2}, {"words": "laundry", "n": 1}]'::jsonb, 'teach list, most first, no probe or old words');

set local role anon;
select throws_ok($$select 1 from public.concierge_turn_stats$$, '42501', null, 'anon select is refused');
reset role;

select * from finish();
rollback;
