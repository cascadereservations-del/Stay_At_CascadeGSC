-- Session 127 (lane B1, SQL): release s127_bill_reminders_20261128. Contract: docs/s127/CONTRACT-B.md "Rules both lanes rely on", "Lane B1" and Addendum 1.
-- bill_schedule_cfg_v1 (key-by-key fallback), bill_due_open_v1 (rows open only from pay_day, one call per day inserts nothing twice, the single nudge, the estimate of the cycle that closed in the month),
-- bill_step_v1 (the Finance gate, pay / cancel / skip / paid, ONE transactions row, repeat = already_paid, duplicate screenshot, typed override, amount band, every refusal reason),
-- today_bills_v1 "due", the restrictive app_settings policies, and notices_v1 returning a 'reminder' notice with no source to every role. Every expected value is hand-computed in the comment above its block.
-- Synthetic fixtures only (uuids e1280000-..., properties ...b1 to ...b3, names "Zz ..."). All dates are fixed (March to September 2020) except the Today card, whose rows use the Manila month of today
-- itself so the expected period is always the current one. calendar_events and every generated column are never inserted. The rate table is cleared INSIDE this transaction (a real backup holds real rows).
-- Nothing in this file can run without a Postgres that holds the Cascade schema: it is run by the rehearsal (scripts/recovery/p6/migration-rehearsal-on-host.sh <backup> <release.json> <this file>).
begin;
select plan(64);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant select on public.app_settings to anon, authenticated;

create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1280000-0000-4000-8000-0000000000' || p)::uuid $$;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', '{}', true), set_config('role', 'anon', true);
$$;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
-- the contract default of the bill_schedule setting, restored between blocks
create function pg_temp.cfg_default() returns jsonb language sql as $$
  select '{"reading_day":21,"pay_day":27,"nudge_day":28,"bills":{"electric":{"label":"Electricity (SOCOTECO II)","account":"","account_name":""},"water":{"label":"Water (Gensan Water District)","account":"","account_name":""},"internet":{"label":"Internet","amount":1500,"pay_to_name":"","pay_to_number":"","note":""},"netflix":{"label":"Netflix","amount":449}}}'::jsonb
$$;
create function pg_temp.cfg_set(p jsonb) returns jsonb language plpgsql as $f$
begin
  update public.app_settings set value = p where key = 'bill_schedule';
  return public.bill_schedule_cfg_v1();
end $f$;
-- the id of a bill row
create function pg_temp.bid(k text, prop text, per text) returns uuid language sql stable as $$
  select id from public.utility_bills where property_id = pg_temp.id(prop) and kind = k and period = per
$$;
-- a screenshot proof with ids no other call uses, read amount amt, optionally confirmed
create temp sequence _pseq start 100;
create function pg_temp.rp(amt numeric, conf boolean default false) returns jsonb language plpgsql as $f$
declare n bigint := nextval('_pseq');
begin
  return jsonb_build_object('file_unique_id', 'zz128-u' || n, 'file_id', 'zz128-f' || n, 'sha256', 'zz128-s' || n, 'amount', amt, 'reference', 'ZZR' || n,
                            'read', jsonb_build_object('amount', amt), 'verdict', 'read') || case when conf then '{"confirmed":true}'::jsonb else '{}'::jsonb end;
end $f$;
-- bill_step_v1 as the admin whose Telegram id is 128000002
create function pg_temp.adm(p_id uuid, p_step text, p_proof jsonb default null) returns jsonb language sql as $$
  select public.bill_step_v1(p_id, p_step, 128000002, 'Zz Admin', p_proof)
$$;
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  (pg_temp.id('b1'), 'Zz S128 bills', true), (pg_temp.id('b2'), 'Zz S128 plain', true), (pg_temp.id('b3'), 'Zz S128 today', true);
insert into auth.users(id, email) values
  (pg_temp.id('a1'), 'zz128-cleaner@example.com'), (pg_temp.id('a2'), 'zz128-admin@example.com'), (pg_temp.id('a3'), 'zz128-laundry@example.com'),
  (pg_temp.id('a4'), 'zz128-finance@example.com'), (pg_temp.id('a5'), 'zz128-disabled@example.com'), (pg_temp.id('a6'), 'zz128-nostaff@example.com');
insert into public.staff_access_profiles(user_id, role, disabled_at, telegram_user_id) values
  (pg_temp.id('a1'), 'cleaner', null, 128000001), (pg_temp.id('a2'), 'admin', null, 128000002), (pg_temp.id('a3'), 'laundry', null, null),
  (pg_temp.id('a4'), 'finance', null, 128000004), (pg_temp.id('a5'), 'admin', now(), 128000005);
insert into public.staff_property_access(user_id, property_id) values
  (pg_temp.id('a1'), pg_temp.id('b1')), (pg_temp.id('a2'), pg_temp.id('b1')), (pg_temp.id('a3'), pg_temp.id('b1')),
  (pg_temp.id('a1'), pg_temp.id('b3')), (pg_temp.id('a2'), pg_temp.id('b3')), (pg_temp.id('a3'), pg_temp.id('b3'));

delete from public.utility_rates;
delete from public.app_settings where key = 'bill_schedule';

-- 1. the settings row: the migration insert (copied here, same text), idempotent, contract default ---------------------------------------------------------------------
insert into public.app_settings(key, value)
select 'bill_schedule', '{"reading_day":21,"pay_day":27,"nudge_day":28,"bills":{"electric":{"label":"Electricity (SOCOTECO II)","account":"","account_name":""},"water":{"label":"Water (Gensan Water District)","account":"","account_name":""},"internet":{"label":"Internet","amount":1500,"pay_to_name":"","pay_to_number":"","note":""},"netflix":{"label":"Netflix","amount":449}}}'::jsonb
 where not exists (select 1 from public.app_settings a where a.key = 'bill_schedule');
select ok((select value = pg_temp.cfg_default() from public.app_settings where key = 'bill_schedule') and (select count(*) from public.app_settings where key = 'bill_schedule') = 1,
          'the insert creates the missing bill_schedule row with exactly the contract default (account numbers, payee name, number and note are empty strings)');
update public.app_settings set value = '{"pay_day":5}'::jsonb where key = 'bill_schedule';
insert into public.app_settings(key, value)
select 'bill_schedule', pg_temp.cfg_default() where not exists (select 1 from public.app_settings a where a.key = 'bill_schedule');
select ok((select value = '{"pay_day":5}'::jsonb from public.app_settings where key = 'bill_schedule') and (select count(*) from public.app_settings where key = 'bill_schedule') = 1,
          'the insert is idempotent: an existing row is never replaced');
update public.app_settings set value = pg_temp.cfg_default() where key = 'bill_schedule';

-- 2. grants and shape -----------------------------------------------------------------------------------------------------------------------------------
select ok(has_function_privilege('service_role', 'public.bill_due_open_v1(uuid,date)', 'execute') and has_function_privilege('service_role', 'public.bill_step_v1(uuid,text,bigint,text,jsonb)', 'execute')
          and not has_function_privilege('anon', 'public.bill_due_open_v1(uuid,date)', 'execute') and not has_function_privilege('authenticated', 'public.bill_due_open_v1(uuid,date)', 'execute')
          and not has_function_privilege('anon', 'public.bill_step_v1(uuid,text,bigint,text,jsonb)', 'execute') and not has_function_privilege('authenticated', 'public.bill_step_v1(uuid,text,bigint,text,jsonb)', 'execute'),
          'bill_due_open_v1 and bill_step_v1 run for service_role only');
select ok((select bool_and(not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('service_role', f, 'execute'))
             from unnest(array['public.bill_cfg_text_v1(jsonb,text)', 'public.bill_schedule_cfg_v1()', 'public.bill_json_v1(public.utility_bills)']) f),
          'the three internal helpers run for nobody (not anon, authenticated, service_role)');
select ok(has_function_privilege('authenticated', 'public.today_bills_v1(uuid)', 'execute') and not has_function_privilege('anon', 'public.today_bills_v1(uuid)', 'execute')
          and not has_function_privilege('service_role', 'public.today_bills_v1(uuid)', 'execute'), 'today_bills_v1 still runs for signed-in users only (grants restated)');
select ok((select count(*) = 6 and bool_and(p.proconfig = array['search_path=""']) from pg_proc p
            where p.oid in ('public.bill_due_open_v1(uuid,date)'::regprocedure, 'public.bill_step_v1(uuid,text,bigint,text,jsonb)'::regprocedure, 'public.today_bills_v1(uuid)'::regprocedure,
                            'public.bill_cfg_text_v1(jsonb,text)'::regprocedure, 'public.bill_schedule_cfg_v1()'::regprocedure, 'public.bill_json_v1(public.utility_bills)'::regprocedure))
          and (select bool_and(p.prosecdef) from pg_proc p where p.oid in ('public.bill_due_open_v1(uuid,date)'::regprocedure, 'public.bill_step_v1(uuid,text,bigint,text,jsonb)'::regprocedure, 'public.today_bills_v1(uuid)'::regprocedure)),
          'the six new or replaced functions pin search_path to empty; the two Telegram functions and today_bills_v1 are security definer');
select ok((select relrowsecurity from pg_class where oid = 'public.utility_bills'::regclass)
          and not has_table_privilege('anon', 'public.utility_bills', 'select,insert,update,delete') and not has_table_privilege('authenticated', 'public.utility_bills', 'select,insert,update,delete')
          and has_table_privilege('service_role', 'public.utility_bills', 'select,insert,update'), 'utility_bills: RLS on, no table privilege for anon or authenticated, service_role has it');
select ok(md5(replace((select p.prosrc from pg_proc p where p.oid = 'public.today_bills_v1(uuid)'::regprocedure), chr(13), '')) = '1f581c3b6ce841395c5e7d2cf6207936',
          'today_bills_v1 is exactly the body this release pins (the lane A body f7cfd2f8... plus the due key)');
select ok((select pg_get_constraintdef(oid) like '%''bill''%' and pg_get_constraintdef(oid) like '%''cleaner_fee''%' and pg_get_constraintdef(oid) like '%''refund''%' and pg_get_constraintdef(oid) like '%''telegram''%'
            from pg_constraint where conrelid = 'public.transactions'::regclass and conname = 'transactions_source_check'),
          'transactions_source_check now lists bill and still lists the older values');
insert into _t select 'badsrc', pg_temp.try($$insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
  values ('e1280000-0000-4000-8000-0000000000b1', 'expense', 'utilities', 'confirmed', 'zz128_not_a_source', 1, 'Zz', date '2020-01-01', 'zz128-badsrc', 'x', 'x') returning to_jsonb(1)$$);
select is((select v ->> 'err' from _t where k = 'badsrc'), '23514', 'the source check still refuses an unknown source (check_violation)');

-- 3. bill_schedule_cfg_v1: key by key, never raises. Hand-written expected values ------------------------------------------------------------------------------
select ok(public.bill_schedule_cfg_v1() = '{"reading_day":21,"pay_day":27,"nudge_day":28,"bills":{
    "electric":{"label":"Electricity (SOCOTECO II)","account":"","account_name":"","pay_to_name":"","pay_to_number":"","note":"","amount":null},
    "water":{"label":"Water (Gensan Water District)","account":"","account_name":"","pay_to_name":"","pay_to_number":"","note":"","amount":null},
    "internet":{"label":"Internet","account":"","account_name":"","pay_to_name":"","pay_to_number":"","note":"","amount":1500},
    "netflix":{"label":"Netflix","account":"","account_name":"","pay_to_name":"","pay_to_number":"","note":"","amount":449}}}'::jsonb,
          'the default setting reads as 21 / 27 / 28 and the four bills with empty account, pay-to and note strings (amount only for internet 1500 and netflix 449)');
-- reading_day -3 -> held up to 1; pay_day 40 -> held down to 28 (not the default 27); nudge_day "x" (a string) -> default 28; amount -5 -> default 1500; label 7 and note ["a"] -> default; netflix "no" (not an object) -> defaults
select ok(pg_temp.cfg_set('{"reading_day":-3,"pay_day":40,"nudge_day":"x","bills":{"internet":{"amount":-5,"label":7,"note":["a"]},"netflix":"no"}}'::jsonb)
          = jsonb_set(jsonb_set(jsonb_set(pg_temp.cfg_set(pg_temp.cfg_default()), '{reading_day}', '1'::jsonb), '{pay_day}', '28'::jsonb), '{nudge_day}', '28'::jsonb),
          'wrong JSON types fall back key by key and never raise; days are held to 1..28');
select ok((select c ->> 'pay_day' = '10' and c ->> 'reading_day' = '5' and c ->> 'nudge_day' = '12' and c #>> '{bills,internet,amount}' = '1234.5' and c #>> '{bills,internet,label}' = 'Zz Net'
                  and c #>> '{bills,internet,pay_to_name}' = 'Zz Payee' and c #>> '{bills,internet,pay_to_number}' = '0900' and c #>> '{bills,internet,note}' = 'Zz note'
                  and c #>> '{bills,electric,account}' = 'ZZ-1' and c #>> '{bills,electric,account_name}' = 'Zz Acct' and c #>> '{bills,electric,label}' = 'Electricity (SOCOTECO II)' and c #>> '{bills,netflix,amount}' = '449'
             from (select pg_temp.cfg_set('{"pay_day":10.9,"reading_day":5,"nudge_day":12,"bills":{"internet":{"amount":1234.5,"label":"Zz Net","pay_to_name":"Zz Payee","pay_to_number":"0900","note":"Zz note"},"electric":{"account":"ZZ-1","account_name":"Zz Acct"}}}'::jsonb) c) x),
          'valid custom values win (pay_day 10.9 is cut to 10); every key not set falls back to its default');
select ok(pg_temp.cfg_set('"just a string"'::jsonb) = pg_temp.cfg_set(pg_temp.cfg_default()), 'a setting row that is not an object falls back to the defaults');
delete from public.app_settings where key = 'bill_schedule';
select ok(public.bill_schedule_cfg_v1() = (select c from (select pg_temp.cfg_set(pg_temp.cfg_default()) c) x where false union all select public.bill_schedule_cfg_v1() limit 1)
          and (public.bill_schedule_cfg_v1() ->> 'pay_day') = '27' and (public.bill_schedule_cfg_v1() #>> '{bills,internet,amount}') = '1500',
          'no setting row at all: the defaults (pay day 27, internet 1500)');
insert into public.app_settings(key, value) values ('bill_schedule', pg_temp.cfg_default());

-- 4. the restrictive policies: the key holds account numbers, so anon and every account but owner / admin read nothing. Another key stays readable.
insert into public.app_settings(key, value) values ('zz128_public', '{}'::jsonb) on conflict (key) do nothing;
select pg_temp.as_anon();
insert into _t select 'pol_anon_bill', pg_temp.try($$select to_jsonb(count(*)) from public.app_settings where key = 'bill_schedule'$$);
insert into _t select 'pol_anon_pub', pg_temp.try($$select to_jsonb(count(*)) from public.app_settings where key = 'zz128_public'$$);
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'pol_cleaner_bill', pg_temp.try($$select to_jsonb(count(*)) from public.app_settings where key = 'bill_schedule'$$);
insert into _t select 'pol_cleaner_pub', pg_temp.try($$select to_jsonb(count(*)) from public.app_settings where key = 'zz128_public'$$);
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'pol_admin_bill', pg_temp.try($$select to_jsonb(count(*)) from public.app_settings where key = 'bill_schedule'$$);
reset role;
select ok((select v = '0'::jsonb from _t where k = 'pol_anon_bill') and (select v = '1'::jsonb from _t where k = 'pol_anon_pub'), 'anon reads zero rows of bill_schedule but still reads another key');
select ok((select v = '0'::jsonb from _t where k = 'pol_cleaner_bill') and (select v = '1'::jsonb from _t where k = 'pol_cleaner_pub'), 'a cleaner reads zero rows of bill_schedule but still reads another key');
select ok((select v = '1'::jsonb from _t where k = 'pol_admin_bill'), 'an admin (manage_staff) reads the bill_schedule row');

-- 5. bill_due_open_v1. Property b1, March 2020. Rate 10 PHP/kWh (manual, March) and two counted readings.
-- r1 21 Feb 2020 (first reading, 10 kWh, 1.0 m3) lands on its own day 21 Feb = the cycle start, so it is outside the cycle (21 Feb, 21 Mar].
-- r2 1 Mar 2020 (60 kWh, 6.0 m3) is spread over the days after r1's day up to its own: 22 Feb..29 Feb (8 days, 2020 is a leap year) + 1 Mar = 9 days.
-- Electric: 60 kWh in 9 days; days in the cycle 21 Feb -> 21 Mar = 29; per day 60/9 = 6.6667; forecast 6.6667 x 29 = 193.3333 kWh; x 10 + 5.60 fixed = 1938.9333 -> 1938.93.
-- Water: 6.0 m3 in 9 days -> forecast 6/9 x 29 = 19.3333 m3 = 212 (minimum, 0-10) + (19.3333 - 10) x 23.05 = 212 + 215.1333 = 427.1333 -> 427.13.
insert into public.utility_rates(provider, php_per_kwh, effective_from, source) values ('socoteco2', 10, date '2020-03-01', 'manual');
insert into public.meter_readings(id, session_id, property_id, recorded_at, electric_prev, electric_curr, water_prev, electric_delta, water_delta, meter_flag) values
  (pg_temp.id('c1'), null, pg_temp.id('b1'), timestamptz '2020-02-21 09:00+08', 1000, 1010, 50, 10, 1.0, null),
  (pg_temp.id('c2'), null, pg_temp.id('b1'), timestamptz '2020-03-01 09:00+08', 1010, 1070, 51, 60, 6.0, null);
select pg_temp.cfg_set(pg_temp.cfg_default()) is not null as reset;
insert into _t select 'o0', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-03-26');
select ok((select v = '{"new":[],"nudge":[]}'::jsonb from _t where k = 'o0') and (select count(*) = 0 from public.utility_bills where property_id = pg_temp.id('b1')),
          'the 26th, before pay_day 27: both lists empty and no row opened');
insert into _t select 'o1', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-03-27');
select ok((select (select jsonb_agg(e ->> 'kind') from jsonb_array_elements(v -> 'new') e) = '["electric","water","internet","netflix"]'::jsonb and v -> 'nudge' = '[]'::jsonb from _t where k = 'o1')
          and (select count(*) = 4 and bool_and(status = 'due') from public.utility_bills where property_id = pg_temp.id('b1') and period = '2020-03'),
          'the 27th: four rows open (electric, water, internet, netflix, all due) and nothing to nudge');
select ok((select (select jsonb_agg(e -> 'estimate_php') from jsonb_array_elements(v -> 'new') e) = '[1938.93, 427.13, 1500, 449]'::jsonb from _t where k = 'o1')
          and (select array_agg(estimate_php order by kind) = array[1938.93, 1500, 449, 427.13]::numeric[] from public.utility_bills where property_id = pg_temp.id('b1') and period = '2020-03'),
          'estimates: electric 1938.93 and water 427.13 (the cycle that CLOSED on 21 Mar), internet 1500 and netflix 449 (the fixed amounts)');
select ok((select (v -> 'new' -> 2) ?& array['id', 'ref', 'kind', 'period', 'label', 'estimate_php', 'account', 'account_name', 'pay_to_name', 'pay_to_number', 'note']
                 and v -> 'new' -> 2 ->> 'kind' = 'internet' and v -> 'new' -> 2 ->> 'period' = '2020-03' and v -> 'new' -> 2 ->> 'label' = 'Internet'
                 and v -> 'new' -> 2 ->> 'pay_to_name' = '' and v -> 'new' -> 2 ->> 'pay_to_number' = '' and v -> 'new' -> 2 ->> 'note' = '' and v -> 'new' -> 2 ->> 'account' = ''
                 and v -> 'new' -> 2 ->> 'ref' = upper(left(v -> 'new' -> 2 ->> 'id', 8))
             from _t where k = 'o1'),
          'a bill object carries the eleven contract keys; empty settings come back as empty strings; ref is the first 8 characters of the id, upper case');
insert into _t select 'o1b', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-03-27');
select ok((select v = '{"new":[],"nudge":[]}'::jsonb from _t where k = 'o1b') and (select count(*) = 4 from public.utility_bills where property_id = pg_temp.id('b1')),
          'a second call the same day returns nothing new and inserts nothing');
insert into _t select 'o2', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-03-28');
select ok((select v -> 'new' = '[]'::jsonb and (select jsonb_agg(e ->> 'kind') from jsonb_array_elements(v -> 'nudge') e) = '["electric","water","internet","netflix"]'::jsonb from _t where k = 'o2')
          and (select count(*) = 4 from public.utility_bills where property_id = pg_temp.id('b1') and period = '2020-03' and nudged_at is not null),
          'the 28th: the four unpaid rows come back as the nudge and are stamped');
insert into _t select 'o2b', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-03-28');
insert into _t select 'o2c', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-03-29');
select ok((select v = '{"new":[],"nudge":[]}'::jsonb from _t where k = 'o2b') and (select v = '{"new":[],"nudge":[]}'::jsonb from _t where k = 'o2c'), 'the nudge fires once: the same day and the next day return nothing');
-- April: open on the 27th, then electric stays due, internet is paying, water is PAID (typed proof), netflix is skipped. The 28th nudges electric and internet only.
insert into _t select 'a1', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-04-27');
update public.utility_bills set status = 'skipped' where property_id = pg_temp.id('b1') and period = '2020-04' and kind = 'netflix';
update public.utility_bills set status = 'paying', paying_by_tg = 1, paying_by_name = 'Zz' where property_id = pg_temp.id('b1') and period = '2020-04' and kind = 'internet';
update public.utility_bills set status = 'paid', paid_php = 321.40, paid_at = now(), paid_by_name = 'Zz', proof_verdict = 'typed' where property_id = pg_temp.id('b1') and period = '2020-04' and kind = 'water';
insert into _t select 'a2', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-04-28');
select ok((select jsonb_array_length(v -> 'new') = 4 from _t where k = 'a1')
          and (select v -> 'new' = '[]'::jsonb and (select jsonb_agg(e ->> 'kind') from jsonb_array_elements(v -> 'nudge') e) = '["electric","internet"]'::jsonb from _t where k = 'a2'),
          'the nudge covers rows still due or paying (electric, internet) and skips a paid row (water) and a skipped one (netflix)');
-- May: first opened on the 29th (the run was missed on the 27th and 28th): the rows it just opened are not nudged in the same call; the next day nudges them once, and only this month's rows
insert into _t select 'm1', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-05-29');
update public.utility_bills set nudged_at = null where property_id = pg_temp.id('b1') and period = '2020-03' and kind = 'electric';
insert into _t select 'm2', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-05-30');
select ok((select jsonb_array_length(v -> 'new') = 4 and v -> 'nudge' = '[]'::jsonb from _t where k = 'm1')
          and (select jsonb_array_length(v -> 'nudge') = 4 and (select bool_and(e ->> 'period' = '2020-05') from jsonb_array_elements(v -> 'nudge') e) from _t where k = 'm2')
          and (select nudged_at is null from public.utility_bills where property_id = pg_temp.id('b1') and period = '2020-03' and kind = 'electric'),
          'a late first run opens four rows with no nudge in the same call; the next day nudges those four once and never another month''s row');
-- b2 has no reading: a meter bill has no estimate (null, never 0) while the fixed ones keep theirs
insert into _t select 'p1', public.bill_due_open_v1(pg_temp.id('b2'), date '2020-03-27');
select ok((select (select jsonb_agg(e -> 'estimate_php') from jsonb_array_elements(v -> 'new') e) = '[null, null, 1500, 449]'::jsonb from _t where k = 'p1'),
          'no counted reading: electric and water estimates are null; internet 1500 and netflix 449');
-- a custom schedule: pay_day 10, internet 1600, netflix 500 labelled "Zz Stream"
select pg_temp.cfg_set('{"pay_day":10,"nudge_day":12,"bills":{"internet":{"amount":1600},"netflix":{"label":"Zz Stream","amount":500}}}'::jsonb) is not null as custom;
insert into _t select 'q0', public.bill_due_open_v1(pg_temp.id('b2'), date '2020-06-09');
insert into _t select 'q1', public.bill_due_open_v1(pg_temp.id('b2'), date '2020-06-10');
select ok((select v = '{"new":[],"nudge":[]}'::jsonb from _t where k = 'q0') and (select jsonb_array_length(v -> 'new') = 4 from _t where k = 'q1'),
          'pay_day is read from the setting: the 9th opens nothing, the 10th opens four rows');
select ok((select (select jsonb_agg(e -> 'estimate_php') from jsonb_array_elements(v -> 'new') e) = '[null, null, 1600, 500]'::jsonb and v -> 'new' -> 3 ->> 'label' = 'Zz Stream' from _t where k = 'q1'),
          'fixed amounts and labels come from the setting (internet 1600, netflix 500 "Zz Stream")');
select pg_temp.cfg_set(pg_temp.cfg_default()) is not null as reset2;

-- 6. bill_step_v1 on b1, March: electric (1938.93), water (427.13), internet (1500), netflix (449). Actors: admin tg 128000002 "Zz Admin"; finance-role tg 128000004; cleaner tg 128000001;
-- disabled admin tg 128000005; an id with no profile tg 128000099 (a Finance group member the edge function admitted).
insert into _t select 'g1', public.bill_step_v1(pg_temp.bid('electric', 'b1', '2020-03'), 'pay', 128000001, 'Zz Cleaner');
insert into _t select 'g2', public.bill_step_v1(pg_temp.bid('electric', 'b1', '2020-03'), 'pay', null, 'Zz Nobody');
insert into _t select 'g3', public.bill_step_v1(pg_temp.bid('electric', 'b1', '2020-03'), 'pay', 128000005, 'Zz Disabled');
select ok((select bool_and(v = '{"ok":false,"reason":"not_finance"}'::jsonb) from _t where k in ('g1', 'g2', 'g3'))
          and (select status = 'due' and paying_by_tg is null from public.utility_bills where id = pg_temp.bid('electric', 'b1', '2020-03')),
          'a mapped cleaner, a missing Telegram id and a disabled admin are refused (not_finance) and the bill stays due');
insert into _t select 'g4', public.bill_step_v1(pg_temp.bid('water', 'b1', '2020-03'), 'pay', 128000099, 'Zz Guest');
insert into _t select 'g5', public.bill_step_v1(pg_temp.bid('netflix', 'b1', '2020-03'), 'pay', 128000004, 'Zz Finance');
select ok((select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'paying' and v -> 'bill' ->> 'paying_by_name' = 'Zz Guest' from _t where k = 'g4')
          and (select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'paying' from _t where k = 'g5')
          and (select paying_by_tg = 128000004 and paying_at is not null from public.utility_bills where id = pg_temp.bid('netflix', 'b1', '2020-03')),
          'an id with no staff profile and a finance-role profile may pay: due becomes paying and records who and when');
insert into _t select 'n1', pg_temp.adm('e1280000-0000-4000-8000-0000000000ff', 'pay');
insert into _t select 'n2', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'zzz');
insert into _t select 'n3', pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'pay');
select ok((select v = '{"ok":false,"reason":"not_found"}'::jsonb from _t where k = 'n1') and (select v = '{"ok":false,"reason":"bad_step"}'::jsonb from _t where k = 'n2')
          and (select v ->> 'reason' = 'bad_step' from _t where k = 'n3')
          and (select paying_by_tg = 128000004 from public.utility_bills where id = pg_temp.bid('netflix', 'b1', '2020-03')),
          'an unknown id is not_found, an unknown step is bad_step, and a second person cannot take over a bill someone else is paying (bad_step; the first payer stays)');
insert into _t select 'n4', public.bill_step_v1(pg_temp.bid('netflix', 'b1', '2020-03'), 'pay', 128000004, 'Zz Finance');
insert into _t select 'n5', pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'cancel');
insert into _t select 'n6', pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'cancel');
select ok((select v ->> 'ok' = 'true' from _t where k = 'n4') and (select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'due' from _t where k = 'n5') and (select v ->> 'reason' = 'bad_step' from _t where k = 'n6')
          and (select paying_by_tg is null and paying_by_name is null and paying_at is null from public.utility_bills where id = pg_temp.bid('netflix', 'b1', '2020-03')),
          'the same person tapping pay again is fine; cancel puts a paying bill back to due and clears who; cancel on a due bill is bad_step');
-- skip on b2 June netflix: no expense row; skipping again is fine; a skipped bill cannot be marked paid
insert into _t select 's1', pg_temp.adm(pg_temp.bid('netflix', 'b2', '2020-06'), 'skip');
insert into _t select 's2', pg_temp.adm(pg_temp.bid('netflix', 'b2', '2020-06'), 'skip');
insert into _t select 's3', pg_temp.adm(pg_temp.bid('netflix', 'b2', '2020-06'), 'paid', pg_temp.rp(500));
select ok((select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'skipped' from _t where k = 's1') and (select v ->> 'ok' = 'true' from _t where k = 's2') and (select v ->> 'reason' = 'bad_step' from _t where k = 's3')
          and (select count(*) = 0 from public.transactions where source = 'bill' and property_id = pg_temp.id('b2')),
          'skip marks the bill skipped (twice is fine), writes no transaction, and a skipped bill cannot be paid');
-- paid: electric. Pay first (admin), then the screenshot read 1960.50. Band for estimate 1938.93 is 969.465 .. 3877.86, so 1960.50 is inside.
insert into _t select 'e0', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'pay');
insert into _t select 'e1', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'paid',
  '{"file_unique_id":"zz128-u1","file_id":"zz128-f1","sha256":"zz128-s1","amount":1960.5,"reference":"ZZREF1","read":{"amount":1960.5},"verdict":"read","unknown_key":1}'::jsonb);
select ok((select v ->> 'ok' = 'true' and (v ->> 'paid_php')::numeric = 1960.5 and v -> 'bill' ->> 'status' = 'paid' and v -> 'bill' ->> 'paid_by_name' = 'Zz Admin' and v -> 'bill' ->> 'paying_by_name' = 'Zz Admin' from _t where k = 'e1'),
          'paid with a read screenshot: ok, paid_php 1960.5 (the amount read, fee included, not the estimate 1938.93), status paid, settled by Zz Admin');
select ok((select count(*) = 1 from public.transactions where external_ref = 'bill:electric:2020-03')
          and (select t.txn_type = 'expense' and t.category = 'utilities' and t.status = 'confirmed' and t.source = 'bill' and t.gross_amount = 1960.50 and t.payee_name = 'Electricity (SOCOTECO II)'
                      and t.property_id = pg_temp.id('b1') and t.transaction_date = public.manila_today() and t.logged_by = 'Telegram: Zz Admin'
                      and t.notes = 'Utility bill electric 2020-03 (Electricity (SOCOTECO II)). Bill ' || (select ref from public.utility_bills where id = pg_temp.bid('electric', 'b1', '2020-03')) || '.'
                 from public.transactions t where t.external_ref = 'bill:electric:2020-03'),
          'exactly ONE transactions row: expense, utilities, confirmed, source bill, 1960.50, payee the bill label, Manila today, logged by Telegram: Zz Admin, notes naming kind, period and ref');
select ok((select b.txn_id = (select id from public.transactions where external_ref = 'bill:electric:2020-03') and b.proof_verdict = 'read' and b.proof_sha256 = 'zz128-s1' and b.proof_file_unique_id = 'zz128-u1'
                  and b.proof_file_id = 'zz128-f1' and b.proof_amount = 1960.50 and b.proof_reference = 'ZZREF1' and b.paid_php = 1960.50 and b.paid_by_tg = 128000002 and b.paid_at is not null
             from public.utility_bills b where b.id = pg_temp.bid('electric', 'b1', '2020-03')),
          'the bill row stores txn_id, the verdict read, the screenshot ids and sha256, the amount read, the reference and who paid');
insert into _t select 'e2', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'paid', pg_temp.rp(1999));
insert into _t select 'e3', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'paid',
  '{"file_unique_id":"zz128-u1","file_id":"zz128-f1","sha256":"zz128-s1","amount":1960.5,"verdict":"read"}'::jsonb);
select ok((select v ->> 'reason' = 'already_paid' and v ->> 'ok' = 'false' from _t where k = 'e2') and (select v ->> 'reason' = 'already_paid' from _t where k = 'e3')
          and (select count(*) = 1 from public.transactions where external_ref = 'bill:electric:2020-03')
          and (select paid_php = 1960.50 from public.utility_bills where id = pg_temp.bid('electric', 'b1', '2020-03')),
          'a repeat paid (new screenshot or the same one) is already_paid: still one transaction and the amount is unchanged');
insert into _t select 'x1', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'pay');
insert into _t select 'x2', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'cancel');
insert into _t select 'x3', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'skip');
select ok((select bool_and(v ->> 'reason' = 'already_paid') from _t where k in ('x1', 'x2', 'x3')), 'pay, cancel and skip on a paid bill are all already_paid');
-- duplicate screenshot across bills: the same sha256 with a new file id, and the same file id with a new sha256
insert into _t select 'd1', pg_temp.adm(pg_temp.bid('water', 'b1', '2020-03'), 'paid',
  '{"file_unique_id":"zz128-u2","sha256":"zz128-s1","amount":430,"verdict":"read"}'::jsonb);
insert into _t select 'd2', pg_temp.adm(pg_temp.bid('water', 'b1', '2020-03'), 'paid',
  '{"file_unique_id":"zz128-u1","sha256":"zz128-s2","amount":430,"verdict":"read"}'::jsonb);
select ok((select v ->> 'reason' = 'duplicate_proof' and v ->> 'other_ref' = (select ref from public.utility_bills where id = pg_temp.bid('electric', 'b1', '2020-03')) from _t where k = 'd1')
          and (select v ->> 'reason' = 'duplicate_proof' from _t where k = 'd2')
          and (select status = 'paying' and proof_sha256 is null from public.utility_bills where id = pg_temp.bid('water', 'b1', '2020-03'))
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:water:2020-03'),
          'the electric screenshot used on the water bill is duplicate_proof by sha256 or by file id, naming the other bill; the water bill is unchanged and nothing is written');
insert into _t select 'w1', pg_temp.adm(pg_temp.bid('water', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz128-u3","file_id":"zz128-f3","sha256":"zz128-s3","amount":430,"verdict":"read"}'::jsonb);
select ok((select v ->> 'ok' = 'true' and (v ->> 'paid_php')::numeric = 430 from _t where k = 'w1')
          and (select paying_by_name = 'Zz Guest' and paid_by_name = 'Zz Admin' from public.utility_bills where id = pg_temp.bid('water', 'b1', '2020-03'))
          and (select count(*) = 1 from public.transactions where external_ref = 'bill:water:2020-03' and gross_amount = 430 and payee_name = 'Water (Gensan Water District)'),
          'water paid 430 (inside 213.565 .. 854.26 around the estimate 427.13): the payer who tapped (Zz Guest) is kept and the settler (Zz Admin) is recorded');
-- bad amounts on internet (due): 0, -5, 100000.01 (over the 100,000 cap), "abc", missing, "12.345" (three decimals), 0.004 (rounds to 0.00), and 100000.01 with confirmed true
insert into _t select 'ba', jsonb_build_array(
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz-b1","sha256":"zz-b1","amount":0}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz-b2","sha256":"zz-b2","amount":-5}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz-b3","sha256":"zz-b3","amount":100000.01}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz-b4","sha256":"zz-b4","amount":"abc"}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz-b5","sha256":"zz-b5"}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz-b6","sha256":"zz-b6","amount":"12.345"}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz-b7","sha256":"zz-b7","amount":0.004}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz-b8","sha256":"zz-b8","amount":100000.01,"confirmed":true}'));
select ok((select v = '[{"ok":false,"reason":"bad_amount"},{"ok":false,"reason":"bad_amount"},{"ok":false,"reason":"bad_amount"},{"ok":false,"reason":"bad_amount"},{"ok":false,"reason":"bad_amount"},{"ok":false,"reason":"bad_amount"},{"ok":false,"reason":"bad_amount"},{"ok":false,"reason":"bad_amount"}]'::jsonb from _t where k = 'ba')
          and (select status = 'due' and proof_sha256 is null from public.utility_bills where id = pg_temp.bid('internet', 'b1', '2020-03'))
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:internet:2020-03'),
          'bad_amount for 0, a negative, over 100,000, text, a missing amount, three decimals, and an amount that rounds to 0 (confirmed true does not bypass it); nothing is stored');
-- a proof with no screenshot ids and no typed flag is not a proof (bad_step); neither is a missing proof or one that is not an object
insert into _t select 'bs', jsonb_build_array(
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', null),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"amount":1510}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"amount":1510,"sha256":"zz-c"}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '[1]'));
select ok((select (select jsonb_agg(e ->> 'reason') from jsonb_array_elements(v) e) = '["bad_step","bad_step","bad_step","bad_step"]'::jsonb from _t where k = 'bs')
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:internet:2020-03'),
          'no proof, no screenshot ids, one id missing and a non-object proof are all bad_step; nothing is written');
-- typed override: no screenshot, 1510 inside the fixed band 1500 .. 1550
insert into _t select 'ty', pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"typed":true,"amount":1510,"verdict":"typed"}'::jsonb);
select ok((select v ->> 'ok' = 'true' and (v ->> 'paid_php')::numeric = 1510 from _t where k = 'ty')
          and (select proof_verdict = 'typed' and proof_sha256 is null and proof_file_unique_id is null and proof_amount = 1510 and paid_php = 1510 and txn_id is not null from public.utility_bills where id = pg_temp.bid('internet', 'b1', '2020-03'))
          and (select count(*) = 1 and sum(gross_amount) = 1510 from public.transactions where external_ref = 'bill:internet:2020-03'),
          'typed override: paid without a screenshot, verdict typed, no sha256 or file id stored, one transaction of 1510');
-- amount band, fixed bill: netflix 449 .. 499. 600, 448.99 and 499.01 are asked about (nothing stored); 600 with confirmed true is accepted
insert into _t select 'cb', jsonb_build_array(
  pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'paid', pg_temp.rp(600)),
  pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'paid', pg_temp.rp(448.99)),
  pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'paid', pg_temp.rp(499.01)));
select ok((select v = '[{"ok":false,"reason":"confirm_amount","read":600},{"ok":false,"reason":"confirm_amount","read":448.99},{"ok":false,"reason":"confirm_amount","read":499.01}]'::jsonb from _t where k = 'cb')
          and (select status = 'due' and proof_sha256 is null from public.utility_bills where id = pg_temp.bid('netflix', 'b1', '2020-03'))
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:netflix:2020-03'),
          'netflix 600, 448.99 and 499.01 are outside the band 449 .. 499: confirm_amount with the amount read; the bill is unchanged and nothing is written');
insert into _t select 'cc', pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'paid', pg_temp.rp(600, true));
select ok((select v ->> 'ok' = 'true' and (v ->> 'paid_php')::numeric = 600 from _t where k = 'cc') and (select count(*) = 1 and sum(gross_amount) = 600 from public.transactions where external_ref = 'bill:netflix:2020-03'),
          'confirmed true accepts the amount outside the band: netflix 600 is paid and written once');
-- band edges on b2 fixtures. netflix 449 and 499 exactly; internet 1550 exactly (1499.99 and 1550.01 asked); water 213.57 and 854.26 (213.56 and 854.27 asked); electric with no estimate always asks.
-- water band: 427.13 / 2 = 213.565 .. 427.13 x 2 = 854.26.
insert into public.utility_bills(property_id, kind, period, estimate_php) values
  (pg_temp.id('b2'), 'netflix', '2020-07', 449), (pg_temp.id('b2'), 'netflix', '2020-08', 449), (pg_temp.id('b2'), 'internet', '2020-07', 1500),
  (pg_temp.id('b2'), 'water', '2020-07', 427.13), (pg_temp.id('b2'), 'water', '2020-08', 427.13), (pg_temp.id('b2'), 'electric', '2020-07', null);
insert into _t select 'be', jsonb_build_array(
  pg_temp.adm(pg_temp.bid('internet', 'b2', '2020-07'), 'paid', pg_temp.rp(1499.99)),
  pg_temp.adm(pg_temp.bid('internet', 'b2', '2020-07'), 'paid', pg_temp.rp(1550.01)),
  pg_temp.adm(pg_temp.bid('water', 'b2', '2020-07'), 'paid', pg_temp.rp(213.56)),
  pg_temp.adm(pg_temp.bid('water', 'b2', '2020-07'), 'paid', pg_temp.rp(854.27)),
  pg_temp.adm(pg_temp.bid('electric', 'b2', '2020-07'), 'paid', pg_temp.rp(100)));
select ok((select (select bool_and(e ->> 'reason' = 'confirm_amount') from jsonb_array_elements(v) e) and jsonb_array_length(v) = 5 from _t where k = 'be'),
          'just outside each band is asked about: internet 1499.99 and 1550.01, water 213.56 and 854.27, and an electric bill with no estimate at all');
insert into _t select 'bo', jsonb_build_array(
  pg_temp.adm(pg_temp.bid('netflix', 'b2', '2020-07'), 'paid', pg_temp.rp(449)),
  pg_temp.adm(pg_temp.bid('netflix', 'b2', '2020-08'), 'paid', pg_temp.rp(499)),
  pg_temp.adm(pg_temp.bid('internet', 'b2', '2020-07'), 'paid', pg_temp.rp(1550)),
  pg_temp.adm(pg_temp.bid('water', 'b2', '2020-07'), 'paid', pg_temp.rp(854.26)),
  pg_temp.adm(pg_temp.bid('water', 'b2', '2020-08'), 'paid', pg_temp.rp(213.57)),
  pg_temp.adm(pg_temp.bid('electric', 'b2', '2020-07'), 'paid', pg_temp.rp(100, true)));
select ok((select (select bool_and(e ->> 'ok' = 'true') from jsonb_array_elements(v) e) and jsonb_array_length(v) = 6 from _t where k = 'bo')
          and (select count(*) = 6 and bool_and(status = 'paid' and paying_by_name = 'Zz Admin') from public.utility_bills where property_id = pg_temp.id('b2') and period in ('2020-07', '2020-08')),
          'exactly on the edge is accepted without a question (netflix 449 and 499, internet 1550, water 854.26 and 213.57); an unknown estimate is accepted once confirmed; a bill paid straight from due records the settler as payer');
-- confirmed true bypasses neither a duplicate screenshot nor a bad amount: a new electric row for b2 August with the electric screenshot of b1
insert into public.utility_bills(property_id, kind, period, estimate_php) values (pg_temp.id('b2'), 'electric', '2020-08', 1000);
insert into _t select 'cd', pg_temp.adm(pg_temp.bid('electric', 'b2', '2020-08'), 'paid', '{"file_unique_id":"zz128-u1","sha256":"zz128-s1","amount":1000,"confirmed":true,"verdict":"read"}'::jsonb);
select ok((select v ->> 'reason' = 'duplicate_proof' from _t where k = 'cd'), 'confirmed true does not bypass a duplicate screenshot');
-- an expense row that already exists for the ref (a paid bill whose row was reset by hand) is found again, never doubled
insert into public.utility_bills(property_id, kind, period, estimate_php) values (pg_temp.id('b2'), 'netflix', '2020-09', 449);
insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
values (pg_temp.id('b2'), 'expense', 'utilities', 'confirmed', 'bill', 449, 'Netflix', date '2020-09-27', 'bill:netflix:2020-09', 'Zz orphan ledger row', 'Zz');
insert into _t select 'or', pg_temp.adm(pg_temp.bid('netflix', 'b2', '2020-09'), 'paid', pg_temp.rp(449));
select ok((select v ->> 'ok' = 'true' from _t where k = 'or') and (select count(*) = 1 from public.transactions where external_ref = 'bill:netflix:2020-09')
          and (select b.txn_id = t.id and t.notes = 'Zz orphan ledger row' and t.gross_amount = 449 from public.utility_bills b join public.transactions t on t.external_ref = 'bill:netflix:2020-09' where b.id = pg_temp.bid('netflix', 'b2', '2020-09')),
          'an existing non-void ledger row for the ref is linked, not duplicated (one row, untouched)');
-- the ledger invariant for b1 March: four paid bills (electric, water, internet, netflix) and exactly four bill transactions, one per kind
select ok((select count(*) = 4 from public.utility_bills where property_id = pg_temp.id('b1') and period = '2020-03' and status = 'paid')
          and (select count(*) = 4 and count(distinct external_ref) = 4 and sum(gross_amount) = 1960.50 + 430 + 1510 + 600 from public.transactions where property_id = pg_temp.id('b1') and source = 'bill' and external_ref like 'bill:%:2020-03'),
          'b1 March: four paid bills and exactly four bill transactions, one per ref, totalling 1960.50 + 430 + 1510 + 600 = 4500.50');
-- table checks and the API roles
insert into _t select 'ck1', pg_temp.try($$update public.utility_bills set status = 'paid' where id = (select id from public.utility_bills where property_id = 'e1280000-0000-4000-8000-0000000000b2' and kind = 'internet' and period = '2020-07') and false is not true returning to_jsonb(1)$$);
insert into _t select 'ck2', pg_temp.try($$update public.utility_bills set status = 'paid', paid_php = 5, paid_at = now(), paid_by_name = 'Zz', proof_verdict = 'read' where id = (select id from public.utility_bills where property_id = 'e1280000-0000-4000-8000-0000000000b2' and kind = 'netflix' and period = '2020-06') returning to_jsonb(1)$$);
insert into _t select 'ck3', pg_temp.try($$update public.utility_bills set proof_sha256 = 'zz128-s1' where id = (select id from public.utility_bills where property_id = 'e1280000-0000-4000-8000-0000000000b2' and kind = 'netflix' and period = '2020-06') returning to_jsonb(1)$$);
select ok((select v ->> 'err' = '23514' from _t where k = 'ck2'), 'the table itself refuses PAID with a read verdict and no sha256 (check_violation)');
select ok((select v ->> 'err' = '23505' from _t where k = 'ck3'), 'the table itself refuses a second row with an already used screenshot sha256 (unique violation)');
select pg_temp.as_anon();
insert into _t select 'r1', pg_temp.try($$select public.bill_step_v1('e1280000-0000-4000-8000-0000000000ff', 'pay', 1, 'x')$$);
insert into _t select 'r2', pg_temp.try($$select public.bill_due_open_v1('e1280000-0000-4000-8000-0000000000b1', date '2020-03-27')$$);
insert into _t select 'r3', pg_temp.try($$select to_jsonb(count(*)) from public.utility_bills$$);
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'r4', pg_temp.try($$select public.bill_step_v1('e1280000-0000-4000-8000-0000000000ff', 'pay', 128000002, 'x')$$);
insert into _t select 'r5', pg_temp.try($$select public.bill_due_open_v1('e1280000-0000-4000-8000-0000000000b1', date '2020-03-27')$$);
insert into _t select 'r6', pg_temp.try($$select to_jsonb(count(*)) from public.utility_bills$$);
reset role;
select ok((select bool_and(v ->> 'err' = '42501') from _t where k in ('r1', 'r2', 'r3', 'r4', 'r5', 'r6')) and (select count(*) = 6 from _t where k in ('r1', 'r2', 'r3', 'r4', 'r5', 'r6')),
          'anon and a signed-in admin cannot call bill_step_v1 or bill_due_open_v1 and cannot read utility_bills (permission denied, called as those roles)');

-- 7. today_bills_v1 "due". Property b3, the Manila month of today. Rows: electric due 1000.55; water paid 321.40 (estimate 300); internet due 1500; netflix skipped 449; and an older electric row (2020-01) that must not show.
-- Settings carry an account number and a payee number that must never appear in the payload.
select pg_temp.cfg_set('{"bills":{"electric":{"account":"ZZACCT123"},"internet":{"pay_to_number":"09990000000"}}}'::jsonb) is not null as acct;
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict) values
  (pg_temp.id('b3'), 'electric', to_char(public.manila_today(), 'YYYY-MM'), 1000.55, 'due', null, null, null, null),
  (pg_temp.id('b3'), 'water', to_char(public.manila_today(), 'YYYY-MM'), 300, 'paid', 321.40, now(), 'Zz Admin', 'typed'),
  (pg_temp.id('b3'), 'internet', to_char(public.manila_today(), 'YYYY-MM'), 1500, 'due', null, null, null, null),
  (pg_temp.id('b3'), 'netflix', to_char(public.manila_today(), 'YYYY-MM'), 449, 'skipped', null, null, null, null),
  (pg_temp.id('b3'), 'electric', '2020-01', 999, 'due', null, null, null, null);
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'tb_cleaner', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
insert into _t select 'tb_b1', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b1')$$);
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'tb_laundry', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_user(pg_temp.id('a6'));
insert into _t select 'tb_nostaff', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_anon();
insert into _t select 'tb_anon', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
reset role;
select ok((select v -> 'due' = jsonb_build_array(
             jsonb_build_object('kind', 'electric', 'label', 'Electricity (SOCOTECO II)', 'period', to_char(public.manila_today(), 'YYYY-MM'), 'status', 'due', 'estimate_php', 1000.55, 'paid_php', null),
             jsonb_build_object('kind', 'water', 'label', 'Water (Gensan Water District)', 'period', to_char(public.manila_today(), 'YYYY-MM'), 'status', 'paid', 'estimate_php', 300, 'paid_php', 321.4),
             jsonb_build_object('kind', 'internet', 'label', 'Internet', 'period', to_char(public.manila_today(), 'YYYY-MM'), 'status', 'due', 'estimate_php', 1500, 'paid_php', null),
             jsonb_build_object('kind', 'netflix', 'label', 'Netflix', 'period', to_char(public.manila_today(), 'YYYY-MM'), 'status', 'skipped', 'estimate_php', 449, 'paid_php', null))
           from _t where k = 'tb_cleaner'),
          'a cleaner sees this month''s four rows in electric, water, internet, netflix order with exactly kind, label, period, status, estimate_php and paid_php (the January row does not show)');
select ok((select v::text !~ 'ZZACCT123|09990000000|account|pay_to' from _t where k = 'tb_cleaner'), 'no account number, payee number or settings key is in the Today payload');
select ok((select jsonb_array_length(v -> 'due') = 4 from _t where k = 'tb_laundry'), 'laundry sees the same four rows');
select ok((select v -> 'due' = '[]'::jsonb and (select array_agg(k order by k) from jsonb_object_keys(v) k) = array['due', 'electric', 'last_reading_at', 'since', 'water'] from _t where k = 'tb_b1'),
          'a property with no bill row this month has due = [] and the four lane A keys are all still there');
select ok((select v ->> 'err' = '42501' from _t where k = 'tb_nostaff') and (select v ->> 'err' = '42501' from _t where k = 'tb_anon'), 'a user with no staff profile and anon are still refused (42501)');
select pg_temp.cfg_set(pg_temp.cfg_default()) is not null as reset3;

-- 8. notices_v1: an ops_notices row of type reminder with no source (what the daily step writes) reaches every role on Today as type note / source manual. Dated today, audience default (staff).
insert into public.ops_notices(property_id, notice_type, title, description, effective_date) values
  (pg_temp.id('b1'), 'reminder', 'Zz meter reading', 'Please send today''s electricity and water reading.', public.manila_today());
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'nt_cleaner', pg_temp.try($$select public.notices_v1('e1280000-0000-4000-8000-0000000000b1')$$);
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'nt_laundry', pg_temp.try($$select public.notices_v1('e1280000-0000-4000-8000-0000000000b1')$$);
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'nt_admin', pg_temp.try($$select public.notices_v1('e1280000-0000-4000-8000-0000000000b1')$$);
select pg_temp.as_user(pg_temp.id('a6'));
insert into _t select 'nt_nostaff', pg_temp.try($$select public.notices_v1('e1280000-0000-4000-8000-0000000000b1')$$);
reset role;
select ok((select count(*) = 1 from _t, jsonb_array_elements(v -> 'notices') e where k = 'nt_cleaner' and e ->> 'title' = 'Zz meter reading' and e ->> 'type' = 'note' and e ->> 'source' = 'manual'), 'notices_v1 returns the reminder to a cleaner (type note, source manual)');
select ok((select count(*) = 1 from _t, jsonb_array_elements(v -> 'notices') e where k = 'nt_laundry' and e ->> 'title' = 'Zz meter reading' and e ->> 'type' = 'note' and e ->> 'source' = 'manual'), 'notices_v1 returns the reminder to laundry');
select ok((select count(*) = 1 from _t, jsonb_array_elements(v -> 'notices') e where k = 'nt_admin' and e ->> 'title' = 'Zz meter reading' and e ->> 'type' = 'note' and e ->> 'source' = 'manual'), 'notices_v1 returns the reminder to an admin');
select ok((select v ->> 'err' = '42501' from _t where k = 'nt_nostaff'), 'a user with no staff profile gets no notices (42501)');

select * from finish();
rollback;
