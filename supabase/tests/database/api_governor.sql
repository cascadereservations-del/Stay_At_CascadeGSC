-- Session 69, D-294: release api_governor_20261004. Two service-role-only tables, three service-role-only functions, the api_caps
-- setting, and V14-V18 in the daily scope of apply_verifier_run_v1. Synthetic rows carry a zz-gov- title or a 2030 timestamp so
-- restored production rows never interfere; everything goes with the closing rollback.
begin;
select plan(37);

select has_table('public', 'llm_usage', 'llm_usage exists');
select has_table('public', 'api_budget_snapshots', 'api_budget_snapshots exists');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.llm_usage'::regclass, 'public.api_budget_snapshots'::regclass)),
  'RLS is on for both tables');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename in ('llm_usage', 'api_budget_snapshots')), 0,
  'no policy for anyone on either table');
select ok(not has_table_privilege('anon', 'public.llm_usage', 'select') and not has_table_privilege('anon', 'public.llm_usage', 'insert')
  and not has_table_privilege('authenticated', 'public.llm_usage', 'select') and not has_table_privilege('authenticated', 'public.llm_usage', 'insert')
  and not has_table_privilege('anon', 'public.api_budget_snapshots', 'select') and not has_table_privilege('anon', 'public.api_budget_snapshots', 'insert')
  and not has_table_privilege('authenticated', 'public.api_budget_snapshots', 'select') and not has_table_privilege('authenticated', 'public.api_budget_snapshots', 'insert'),
  'anon and authenticated cannot read or write either table');
select ok(has_table_privilege('service_role', 'public.llm_usage', 'select') and has_table_privilege('service_role', 'public.llm_usage', 'insert')
  and has_table_privilege('service_role', 'public.api_budget_snapshots', 'select') and has_table_privilege('service_role', 'public.api_budget_snapshots', 'insert'),
  'service_role reads and writes both tables');

select has_function('public', 'api_usage_daily_v1', array['integer'], 'api_usage_daily_v1 exists');
select has_function('public', 'api_budget_daily_v1', array['integer'], 'api_budget_daily_v1 exists');
select has_function('public', 'prune_api_usage_v1', array['integer'], 'prune_api_usage_v1 exists');
select ok(has_function_privilege('service_role', 'public.api_usage_daily_v1(integer)', 'execute')
      and has_function_privilege('service_role', 'public.api_budget_daily_v1(integer)', 'execute')
      and has_function_privilege('service_role', 'public.prune_api_usage_v1(integer)', 'execute'),
  'service_role can execute the three functions');
select ok(not has_function_privilege('anon', 'public.api_usage_daily_v1(integer)', 'execute')
      and not has_function_privilege('authenticated', 'public.api_usage_daily_v1(integer)', 'execute')
      and not has_function_privilege('anon', 'public.api_budget_daily_v1(integer)', 'execute')
      and not has_function_privilege('authenticated', 'public.api_budget_daily_v1(integer)', 'execute')
      and not has_function_privilege('anon', 'public.prune_api_usage_v1(integer)', 'execute')
      and not has_function_privilege('authenticated', 'public.prune_api_usage_v1(integer)', 'execute'),
  'anon and authenticated cannot execute any of them');
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""'])
             from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('api_usage_daily_v1', 'api_budget_daily_v1', 'prune_api_usage_v1', 'apply_verifier_run_v1')),
  'all four are security definer with an empty search_path');

-- Rows insert with the table's own shape (as owner: the rehearsal's service_role has no BYPASSRLS; the grant is checked above).
-- The snapshot is stamped 2030 so it never shares today's Manila day with the pair below.
select lives_ok($$insert into public.llm_usage(title, provider, model, tier, input, output, cost_usd, ok)
  values ('zz-gov-svc', 'openrouter', 'm', 'staff', 1, 1, 0.000001, true)$$, 'a llm_usage row inserts');
select lives_ok($$insert into public.api_budget_snapshots(at, key_name, status, limit_usd, remaining_usd, usage_usd)
  values ('2030-01-01T00:00:00Z', 'primary', 200, 1, 1, 1)$$, 'a budget snapshot inserts');
select ok(not has_sequence_privilege('anon', 'public.llm_usage_id_seq', 'usage') and not has_sequence_privilege('authenticated', 'public.api_budget_snapshots_id_seq', 'usage'),
  'anon and authenticated have no sequence grants');

-- Manila noon today, so the two rows of a pair always share one Manila day.
create temp table zz_noon on commit drop as
  select ((now() at time zone 'Asia/Manila')::date + time '12:00') at time zone 'Asia/Manila' as t;

insert into public.llm_usage(at, title, provider, model, tier, input, output, cost_usd, ok, error, probe)
select z.t + x.off, x.title, x.provider, 'm', x.tier, x.i, x.o, x.c, x.ok, x.err, x.pr
  from zz_noon z, (values
    (interval '0',  'zz-gov-a', 'openrouter', 'staff', 100, 20, 0.001::numeric, true,  null::text, false),
    (interval '1 hour', 'zz-gov-a', 'openrouter', 'staff', 50, 10, null::numeric, false, 'http 500', false),
    (interval '0',  'zz-gov-b', 'omniroute',  'staff', 7, 3, 0.002::numeric, true,  null::text, true),
    (interval '0',  'zz-gov-c', 'gemini',     'guest', 5, 5, null::numeric, true,  null::text, false),
    (interval '-40 days', 'zz-gov-old', 'openrouter', 'staff', 1, 1, 0.5::numeric, true, null::text, false),
    (interval '-200 days', 'zz-gov-ancient', 'openrouter', 'staff', 1, 1, 0.5::numeric, true, null::text, false)
  ) as x(off, title, provider, tier, i, o, c, ok, err, pr);

select is((select jsonb_build_array(calls, fails, input, output, cost_usd) from public.api_usage_daily_v1(35) where title = 'zz-gov-a'),
  '[2, 1, 150, 30, 0.001]'::jsonb, 'two calls, one failed: calls, fails, tokens and cost (null cost ignored)');
select is((select model from public.api_usage_daily_v1(35) where title = 'zz-gov-a'), 'm', 'the model is its own column');
select is((select day from public.api_usage_daily_v1(35) where title = 'zz-gov-a'), (now() at time zone 'Asia/Manila')::date,
  'day is the Manila date');
select is((select probe from public.api_usage_daily_v1(35) where title = 'zz-gov-b'), true, 'a probe row is its own group, flagged');
select is((select cost_usd from public.api_usage_daily_v1(35) where title = 'zz-gov-c'), 0::numeric, 'a group whose costs are all null reports 0');
select is((select count(*)::int from public.api_usage_daily_v1(35) where title = 'zz-gov-old'), 0, 'a row older than p_days is left out');
select is((select count(*)::int from public.api_usage_daily_v1(60) where title = 'zz-gov-old'), 1, 'and comes back with a wider window');

insert into public.api_budget_snapshots(at, key_name, status, limit_usd, remaining_usd, usage_usd)
select z.t + x.off, x.k, 200, x.l, x.r, x.u
  from zz_noon z, (values
    (interval '0',      'primary', 1::numeric, 0.90::numeric, 10.00::numeric),
    (interval '1 hour', 'primary', 2::numeric, 0.70::numeric, 10.25::numeric),
    (interval '0',      'backup',  3::numeric, 2.00::numeric,  5.00::numeric),
    (interval '-200 days', 'primary', 1::numeric, 1::numeric, 1::numeric)
  ) as x(off, k, l, r, u);

select is((select to_jsonb(b) - 'day' from public.api_budget_daily_v1(35) b
            where b.key_name = 'primary' and b.day = (now() at time zone 'Asia/Manila')::date and b.snapshots = 2),
  '{"key_name": "primary", "limit_usd": 2, "min_remaining_usd": 0.7, "spent_usd": 0.25, "snapshots": 2}'::jsonb,
  'spent is max minus min lifetime usage; limit is the latest; remaining is the lowest');
select is((select snapshots from public.api_budget_daily_v1(35) b where b.key_name = 'backup' and b.day = (now() at time zone 'Asia/Manila')::date),
  1, 'one backup snapshot that day');
select ok((select b.spent_usd is null from public.api_budget_daily_v1(35) b where b.key_name = 'backup' and b.day = (now() at time zone 'Asia/Manila')::date),
  'spent is null with fewer than two snapshots');

set local role anon;
select throws_ok($$select 1 from public.llm_usage$$, '42501', null, 'anon select is refused');
reset role;

select ok((select jsonb_array_length(value -> 'caps') = 4 from public.app_settings where key = 'api_caps'), 'api_caps is seeded with four caps');
select is((select value #>> '{rules,pressure_pct}' from public.app_settings where key = 'api_caps'), '70', 'api_caps carries the rules');
select is((select value #>> '{credit,openrouter_usd}' from public.app_settings where key = 'api_caps'), '10', 'api_caps carries the credit');

-- apply_verifier_run_v1: V14-V18 are daily-scope checks, so a V16 is accepted, survives an hourly run, and resolves on the next
-- daily run that no longer raises it.
select ok((select prosrc like '%''V13'',''V14'',''V15'',''V16'',''V17'',''V18''%' from pg_proc
            where pronamespace = 'public'::regnamespace and proname = 'apply_verifier_run_v1'),
  'the daily scope array names V14 to V18');
select ok((public.apply_verifier_run_v1('daily',
  '[{"key":"V16:zz-gov-test","check_id":"V16","severity":"yellow","title":"Cap headroom zz","detail":{"cap":"zz"}}]'::jsonb,
  '2030-01-10T05:00:00Z') -> 'new') @> '[{"key":"V16:zz-gov-test","check_id":"V16"}]'::jsonb,
  'a V16 finding is accepted and reported as new');
select public.apply_verifier_run_v1('hourly', '[]'::jsonb, '2030-01-10T06:00:00Z');
select is((select status from public.verifier_findings where key = 'V16:zz-gov-test'), 'open',
  'an hourly run does not resolve a V16 (it is not an hourly check)');
select public.apply_verifier_run_v1('daily', '[]'::jsonb, '2030-01-11T05:00:00Z');
select is((select status from public.verifier_findings where key = 'V16:zz-gov-test'), 'resolved',
  'the next daily run that does not raise it resolves it');

-- Prune last: the 200-day-old rows (one per table) go, the 40-day-old row stays.
select is(public.prune_api_usage_v1(120), 2, 'prune deletes the two rows older than 120 days and reports 2');
select is((select count(*)::int from public.llm_usage where title = 'zz-gov-ancient') + (select count(*)::int from public.api_budget_snapshots where at < now() - interval '120 days'),
  0, 'the old rows are gone');
select is((select count(*)::int from public.llm_usage where title = 'zz-gov-old'), 1, 'a 40-day-old row is kept');
select throws_ok($$select public.prune_api_usage_v1(0)$$, '22023', null, 'prune refuses a keep window under one day');

select * from finish();
rollback;
