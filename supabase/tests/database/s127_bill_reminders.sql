-- Session 127 (lane S, SQL, Staff app): release s127_bill_reminders_20261128. Contract: docs/s127/CONTRACT-B-APP.md (Roles, Lane S) over docs/s127/CONTRACT-B.md "Rules both lanes rely on", Addenda 1 and 3.
-- bill_schedule_cfg_v1 (key-by-key fallback, remind_day), bill_due_open_v1 (rows open from each bill's remind_day, one call per day inserts nothing twice, the estimate of the cycle that closed in the month, the p_min_period floor),
-- bill_step_v1 (the internal core: pay / cancel / skip / paid, ONE transactions row, repeat = already_paid, duplicate screenshot incl. a staff-pay one, amount band, only the payer settles or skips,
-- a ledger row is linked only when it matches, a void row is refused), the Staff app functions called as real roles (anon, cleaner, laundry, no-profile user, disabled admin, finance, admin): bill_pay_open_v1 / settle / cancel / skip,
-- bill_proof_v1, bill_schedule_get_v1 / set_v1, today_bills_v1 "due" with can_pay, no account or payee data in any reply of settle, cancel, skip, proof or today_bills_v1, the daily job (bill_daily_v1: active properties only, one that raises does not stop the others) and the Today notices,
-- staff_pay_admin_settle_v1 refusing a screenshot that already paid a bill, the restrictive app_settings policies, and notices_v1 returning a reminder to every role.
-- Every expected value is hand-computed in the comment above its block.
-- Synthetic fixtures only (uuids e1280000-..., properties ...b1 to ...b9, ...ba, names "Zz ..."). All dates are fixed (2020 to 2026) except the Today card, whose rows use the Manila month of today itself so the expected period is always the current one.
-- calendar_events and every generated column are never inserted. The rate table is cleared INSIDE this transaction (a real backup holds real rows).
-- Nothing in this file can run without a Postgres that holds the Cascade schema: it is run by the rehearsal (scripts/recovery/p6/migration-rehearsal-on-host.sh <backup> <release.json> <this file>).
begin;
select plan(120);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
do $sr$ begin if not (select rolbypassrls from pg_roles where rolname = 'service_role') then alter role service_role bypassrls; end if; end $sr$;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant select on public.app_settings to anon, authenticated;
grant select on storage.objects to authenticated;
-- s131: the production grants of the functions and the table this suite asserts on (a --no-acl restore has none of them; idempotent, rolled back with the suite)
revoke all on function public.utility_billing_default_v1(), public.utility_cfg_num_v1(jsonb,jsonb), public.utility_billing_cfg_v1(), public.utility_cycle_day_v1(date,integer), public.utility_cycle_v1(date,integer), public.utility_rate_by_month_v1(), public.utility_daily_use_v1(uuid,date,date), public.utility_water_php_v1(numeric,jsonb), public.utility_water_next_v1(numeric,jsonb), public.utility_bill_estimate_v1(uuid,date), public.kpi_usage_months_v1(uuid,date), public.kpi_admin_bills_v1(uuid,numeric), public.bill_step_v1(uuid,text,uuid,text,jsonb), public.bill_due_open_v1(uuid,date,text), public.bill_daily_v1(date,uuid), public.bill_reply_v1(jsonb,uuid), public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid), public.bill_pay_info_v1(jsonb,text,text), public.bill_can_v1(uuid), public.bill_actor_name_v1(uuid), public.bill_json_v1(public.utility_bills), public.bill_schedule_cfg_v1(), public.bill_cfg_one_v1(jsonb,text,jsonb,integer), public.bill_cfg_day_v1(jsonb,integer), public.bill_cfg_text_v1(jsonb,text) from public, anon, authenticated, service_role;
revoke all on function public.today_bills_v1(uuid), public.kpi_tab_v1(uuid,date), public.bill_pay_open_v1(uuid), public.bill_pay_settle_v1(uuid,jsonb), public.bill_pay_cancel_v1(uuid), public.bill_pay_skip_v1(uuid), public.bill_proof_v1(uuid), public.bill_schedule_get_v1(uuid,text), public.bill_schedule_set_v1(uuid,text,jsonb), public.staff_pay_admin_settle_v1(uuid,jsonb) from public, anon, service_role;
grant execute on function public.today_bills_v1(uuid), public.kpi_tab_v1(uuid,date), public.bill_pay_open_v1(uuid), public.bill_pay_settle_v1(uuid,jsonb), public.bill_pay_cancel_v1(uuid), public.bill_pay_skip_v1(uuid), public.bill_proof_v1(uuid), public.bill_schedule_get_v1(uuid,text), public.bill_schedule_set_v1(uuid,text,jsonb), public.staff_pay_admin_settle_v1(uuid,jsonb) to authenticated;
revoke all on public.utility_bills from public, anon, authenticated;
grant select, insert, update on public.utility_bills to service_role;

create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1280000-0000-4000-8000-0000000000' || p)::uuid $$;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_anon() returns void language sql as $$
  select set_config('request.jwt.claims', '{}', true), set_config('role', 'anon', true);
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role":"service_role"}', true), set_config('role', 'service_role', true);
$$;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
-- call a one-argument function of the release as the current role; an exception comes back as {err, msg}
create function pg_temp.c1(f text, a uuid) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute format('select public.%I(%L)', f, a) into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create function pg_temp.c2(f text, a uuid, b jsonb) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute format('select public.%I(%L, %L::jsonb)', f, a, b) into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
create function pg_temp.cs(f text, a uuid, k text, b jsonb default null) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  if b is null then execute format('select public.%I(%L, %L)', f, a, k) into r;
  else execute format('select public.%I(%L, %L, %L::jsonb)', f, a, k, b) into r; end if;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
-- s131: the schedule as s127 stored it, with remind_day 27 STORED on each bill (s131 changed only the default of a bill with no stored remind_day, to 25); restored between blocks so every opening scenario below keeps its day 27
create function pg_temp.cfg_default() returns jsonb language sql as $$
  select '{"reading_day":21,"pay_day":27,"bills":{"electric":{"label":"Electricity (SOCOTECO II)","account":"","account_name":"","remind_day":27},"water":{"label":"Water (Gensan Water District)","account":"","account_name":"","remind_day":27},"internet":{"label":"Internet","amount":1500,"pay_to_name":"","pay_to_number":"","note":"","remind_day":27},"netflix":{"label":"Netflix","amount":449,"remind_day":27}}}'::jsonb
$$;
-- the hand-written value bill_schedule_cfg_v1() must return: reading day, pay day and the remind_day every bill carries (s131: a bill with none stored carries 25, no longer the pay day)
create function pg_temp.cfg_expected(p_read integer default 21, p_pay integer default 27, p_remind integer default 25) returns jsonb language sql as $$
  select jsonb_build_object('reading_day', p_read, 'pay_day', p_pay, 'bills', jsonb_build_object(
    'electric', jsonb_build_object('label', 'Electricity (SOCOTECO II)', 'account', '', 'account_name', '', 'pay_to_name', '', 'pay_to_number', '', 'note', '', 'amount', null, 'remind_day', p_remind),
    'water',    jsonb_build_object('label', 'Water (Gensan Water District)', 'account', '', 'account_name', '', 'pay_to_name', '', 'pay_to_number', '', 'note', '', 'amount', null, 'remind_day', p_remind),
    'internet', jsonb_build_object('label', 'Internet', 'account', '', 'account_name', '', 'pay_to_name', '', 'pay_to_number', '', 'note', '', 'amount', 1500, 'remind_day', p_remind),
    'netflix',  jsonb_build_object('label', 'Netflix', 'account', '', 'account_name', '', 'pay_to_name', '', 'pay_to_number', '', 'note', '', 'amount', 449, 'remind_day', p_remind)))
$$;
-- s131: the utility_billing setting with electric.open_from and water.open_from = p (the March 2020 estimates of b1 start their cycle there; production's open_from is 2026-10-21); null = no row, the defaults
create function pg_temp.ub_open(p date) returns void language plpgsql as $f$
begin
  delete from public.app_settings where key = 'utility_billing';
  if p is not null then
    insert into public.app_settings(key, value)
    values ('utility_billing', jsonb_set(jsonb_set(public.utility_billing_default_v1(), '{electric,open_from}', to_jsonb(p::text)), '{water,open_from}', to_jsonb(p::text)));
  end if;
end $f$;
create function pg_temp.cfg_set(p jsonb) returns jsonb language plpgsql as $f$
begin
  update public.app_settings set value = p where key = 'bill_schedule';
  return public.bill_schedule_cfg_v1();
end $f$;
-- the id of a bill row
create function pg_temp.bid(k text, prop text, per text) returns uuid language sql stable as $$
  select id from public.utility_bills where property_id = pg_temp.id(prop) and kind = k and period = per
$$;
-- a bill id registered while superuser, so a role-switched block can read it from _t (the table itself is closed to the API roles)
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.reg(n text, k text, prop text, per text) returns void language sql as $$
  insert into _t select 'id_' || n, to_jsonb(pg_temp.bid(k, prop, per)::text)
$$;
create function pg_temp.bi(n text) returns uuid language sql stable as $$ select (v #>> '{}')::uuid from _t where k = 'id_' || n $$;
-- a stored screenshot: the object in the private bucket and the sha256 upload-photo recorded for it (repeat(sha, 64)); returns the path
create function pg_temp.ph(prop text, usr text, nm text, sha text) returns text language plpgsql as $f$
declare p text := pg_temp.id(prop)::text || '/' || pg_temp.id(usr)::text || '/' || nm;
begin
  insert into storage.objects(bucket_id, name) values ('cleaning-photos', p);
  insert into public.staff_upload_hashes(path, sha256) values (p, repeat(sha, 64));
  return p;
end $f$;
-- a screenshot proof with ids no other call uses, read amount amt, optionally confirmed (the internal core's input)
create temp sequence _pseq start 100;
create function pg_temp.rp(amt numeric, conf boolean default false) returns jsonb language plpgsql as $f$
declare n bigint := nextval('_pseq');
begin
  return jsonb_build_object('file_unique_id', 'zz128-u' || n, 'file_id', 'zz128-f' || n, 'sha256', 'zz128-s' || n, 'amount', amt, 'reference', 'ZZR' || n,
                            'read', jsonb_build_object('amount', amt), 'verdict', 'read') || case when conf then '{"confirmed":true}'::jsonb else '{}'::jsonb end;
end $f$;
-- bill_step_v1 (internal, called as the owner) as the admin a2 "Zz Admin", as the finance user a4 "Zz Finance", as the finance user a7 "Zz Guest"
create function pg_temp.adm(p_id uuid, p_step text, p_proof jsonb default null) returns jsonb language sql as $$
  select public.bill_step_v1(p_id, p_step, pg_temp.id('a2'), 'Zz Admin', p_proof)
$$;
create function pg_temp.fin(p_id uuid, p_step text, p_proof jsonb default null) returns jsonb language sql as $$
  select public.bill_step_v1(p_id, p_step, pg_temp.id('a4'), 'Zz Finance', p_proof)
$$;
create function pg_temp.gst(p_id uuid, p_step text, p_proof jsonb default null) returns jsonb language sql as $$
  select public.bill_step_v1(p_id, p_step, pg_temp.id('a7'), 'Zz Guest', p_proof)
$$;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  (pg_temp.id('b1'), 'Zz S128 bills', true), (pg_temp.id('b2'), 'Zz S128 plain', true), (pg_temp.id('b3'), 'Zz S128 today', true), (pg_temp.id('b4'), 'Zz S128 catch-up', true),
  (pg_temp.id('b5'), 'Zz S128 floor', true), (pg_temp.id('b6'), 'Zz S128 remind', true), (pg_temp.id('b7'), 'Zz S128 app', true), (pg_temp.id('b9'), 'Zz S128 daily', true),
  (pg_temp.id('b8'), 'Zz S128 inactive', false), (pg_temp.id('ba'), 'Zz S128 raises', true);
insert into auth.users(id, email, raw_user_meta_data) values
  (pg_temp.id('a1'), 'zz128-cleaner@example.com', '{"display_name":"Zz Cleaner"}'::jsonb), (pg_temp.id('a2'), 'zz128-admin@example.com', '{"display_name":"Zz Admin"}'::jsonb),
  (pg_temp.id('a3'), 'zz128-laundry@example.com', '{"display_name":"Zz Laundry"}'::jsonb), (pg_temp.id('a4'), 'zz128-finance@example.com', '{"display_name":"Zz Finance"}'::jsonb),
  (pg_temp.id('a5'), 'zz128-disabled@example.com', '{"display_name":"Zz Disabled"}'::jsonb), (pg_temp.id('a6'), 'zz128-nostaff@example.com', '{"display_name":"Zz Nostaff"}'::jsonb),
  (pg_temp.id('a7'), 'zz128-guest@example.com', '{"display_name":"Zz Guest"}'::jsonb);
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  (pg_temp.id('a1'), 'cleaner', null), (pg_temp.id('a2'), 'admin', null), (pg_temp.id('a3'), 'laundry', null),
  (pg_temp.id('a4'), 'finance', null), (pg_temp.id('a5'), 'admin', now()), (pg_temp.id('a7'), 'finance', null);
insert into public.staff_property_access(user_id, property_id) values
  (pg_temp.id('a1'), pg_temp.id('b1')), (pg_temp.id('a2'), pg_temp.id('b1')), (pg_temp.id('a3'), pg_temp.id('b1')),
  (pg_temp.id('a1'), pg_temp.id('b3')), (pg_temp.id('a2'), pg_temp.id('b3')), (pg_temp.id('a3'), pg_temp.id('b3')), (pg_temp.id('a4'), pg_temp.id('b3')),
  (pg_temp.id('a1'), pg_temp.id('b7')), (pg_temp.id('a2'), pg_temp.id('b7')), (pg_temp.id('a3'), pg_temp.id('b7')), (pg_temp.id('a4'), pg_temp.id('b7')),
  (pg_temp.id('a5'), pg_temp.id('b7')), (pg_temp.id('a7'), pg_temp.id('b7'));

delete from public.utility_rates;
delete from public.app_settings where key = 'bill_schedule';

-- 1. the settings row: the migration insert (copied here, same text), idempotent, contract default ---------------------------------------------------------------------
insert into public.app_settings(key, value)
select 'bill_schedule', '{"reading_day":21,"pay_day":27,"bills":{"electric":{"label":"Electricity (SOCOTECO II)","account":"","account_name":"","remind_day":27},"water":{"label":"Water (Gensan Water District)","account":"","account_name":"","remind_day":27},"internet":{"label":"Internet","amount":1500,"pay_to_name":"","pay_to_number":"","note":"","remind_day":27},"netflix":{"label":"Netflix","amount":449,"remind_day":27}}}'::jsonb
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
select ok((select bool_and(not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('service_role', f, 'execute'))
             from unnest(array['public.bill_step_v1(uuid,text,uuid,text,jsonb)', 'public.bill_due_open_v1(uuid,date,text)', 'public.bill_daily_v1(date,uuid)',
                               'public.bill_reply_v1(jsonb,uuid)', 'public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)', 'public.bill_pay_info_v1(jsonb,text,text)', 'public.bill_can_v1(uuid)',
                               'public.bill_actor_name_v1(uuid)', 'public.bill_json_v1(public.utility_bills)', 'public.bill_schedule_cfg_v1()', 'public.bill_cfg_one_v1(jsonb,text,jsonb,integer)',
                               'public.bill_cfg_day_v1(jsonb,integer)', 'public.bill_cfg_text_v1(jsonb,text)']) f),
          'the 13 internal functions (the step core, the opener, the daily job and the helpers) run for nobody: not anon, authenticated or service_role');
select ok((select bool_and(has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute') and not has_function_privilege('service_role', f, 'execute'))
             from unnest(array['public.bill_pay_open_v1(uuid)', 'public.bill_pay_settle_v1(uuid,jsonb)', 'public.bill_pay_cancel_v1(uuid)', 'public.bill_pay_skip_v1(uuid)', 'public.bill_proof_v1(uuid)',
                               'public.bill_schedule_get_v1(uuid,text)', 'public.bill_schedule_set_v1(uuid,text,jsonb)', 'public.today_bills_v1(uuid)']) f),
          'the eight Staff app functions (five pay, two schedule, today_bills_v1) run for signed-in users only: not anon, not service_role');
select ok((select count(*) = 21 and bool_and(p.proconfig = array['search_path=""']) from pg_proc p
            where p.oid in ('public.bill_cfg_text_v1(jsonb,text)'::regprocedure, 'public.bill_cfg_day_v1(jsonb,integer)'::regprocedure, 'public.bill_cfg_one_v1(jsonb,text,jsonb,integer)'::regprocedure,
                            'public.bill_schedule_cfg_v1()'::regprocedure, 'public.bill_json_v1(public.utility_bills)'::regprocedure, 'public.bill_actor_name_v1(uuid)'::regprocedure,
                            'public.bill_can_v1(uuid)'::regprocedure, 'public.bill_pay_info_v1(jsonb,text,text)'::regprocedure, 'public.bill_entry_v1(public.utility_bills,jsonb,boolean,uuid)'::regprocedure,
                            'public.bill_reply_v1(jsonb,uuid)'::regprocedure, 'public.bill_due_open_v1(uuid,date,text)'::regprocedure,
                            'public.bill_step_v1(uuid,text,uuid,text,jsonb)'::regprocedure, 'public.bill_daily_v1(date,uuid)'::regprocedure, 'public.bill_pay_open_v1(uuid)'::regprocedure,
                            'public.bill_pay_settle_v1(uuid,jsonb)'::regprocedure, 'public.bill_pay_cancel_v1(uuid)'::regprocedure, 'public.bill_pay_skip_v1(uuid)'::regprocedure,
                            'public.bill_proof_v1(uuid)'::regprocedure, 'public.bill_schedule_get_v1(uuid,text)'::regprocedure, 'public.bill_schedule_set_v1(uuid,text,jsonb)'::regprocedure,
                            'public.today_bills_v1(uuid)'::regprocedure))
          and (select count(*) = 11 and bool_and(p.prosecdef) from pg_proc p
                where p.oid in ('public.bill_due_open_v1(uuid,date,text)'::regprocedure, 'public.bill_step_v1(uuid,text,uuid,text,jsonb)'::regprocedure,
                                'public.bill_daily_v1(date,uuid)'::regprocedure, 'public.bill_pay_open_v1(uuid)'::regprocedure, 'public.bill_pay_settle_v1(uuid,jsonb)'::regprocedure,
                                'public.bill_pay_cancel_v1(uuid)'::regprocedure, 'public.bill_pay_skip_v1(uuid)'::regprocedure, 'public.bill_proof_v1(uuid)'::regprocedure,
                                'public.bill_schedule_get_v1(uuid,text)'::regprocedure, 'public.bill_schedule_set_v1(uuid,text,jsonb)'::regprocedure, 'public.today_bills_v1(uuid)'::regprocedure)),
          'all 21 functions pin search_path to empty; the 11 that act for a caller or a job are security definer');
select ok((select relrowsecurity from pg_class where oid = 'public.utility_bills'::regclass)
          and not has_table_privilege('anon', 'public.utility_bills', 'select,insert,update,delete') and not has_table_privilege('authenticated', 'public.utility_bills', 'select,insert,update,delete')
          and has_table_privilege('service_role', 'public.utility_bills', 'select,insert,update'), 'utility_bills: RLS on, no table privilege for anon or authenticated, service_role has it');
select ok(md5(replace((select p.prosrc from pg_proc p where p.oid = 'public.today_bills_v1(uuid)'::regprocedure), chr(13), '')) = '7fca3fd12b7e372010f8f20b12c491a4',
          'today_bills_v1 is exactly the body the s131 release pins (it replaced the s127 body 70302291... : adds water_since, waiting_for, can_pay_list and check_bills)');
select ok(md5(replace((select p.prosrc from pg_proc p where p.oid = 'public.staff_pay_admin_settle_v1(uuid,jsonb)'::regprocedure), chr(13), '')) = '9035d0051294fcef4ff538fd65517524'
          and has_function_privilege('authenticated', 'public.staff_pay_admin_settle_v1(uuid,jsonb)', 'execute') and not has_function_privilege('anon', 'public.staff_pay_admin_settle_v1(uuid,jsonb)', 'execute')
          and not has_function_privilege('service_role', 'public.staff_pay_admin_settle_v1(uuid,jsonb)', 'execute')
          and (select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.staff_pay_admin_settle_v1(uuid,jsonb)'::regprocedure),
          'staff_pay_admin_settle_v1 is exactly the body this release pins (the S81 body f1909b8b... plus the bill duplicate check) and keeps its grants: authenticated only, security definer, empty search_path');
select ok((select pg_get_constraintdef(oid) like '%''bill''%' and pg_get_constraintdef(oid) like '%''cleaner_fee''%' and pg_get_constraintdef(oid) like '%''refund''%' and pg_get_constraintdef(oid) like '%''telegram''%'
            from pg_constraint where conrelid = 'public.transactions'::regclass and conname = 'transactions_source_check'),
          'transactions_source_check now lists bill and still lists the older values');
insert into _t select 'badsrc', pg_temp.try($$insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
  values ('e1280000-0000-4000-8000-0000000000b1', 'expense', 'utilities', 'confirmed', 'zz128_not_a_source', 1, 'Zz', date '2020-01-01', 'zz128-badsrc', 'x', 'x') returning to_jsonb(1)$$);
select is((select v ->> 'err' from _t where k = 'badsrc'), '23514', 'the source check still refuses an unknown source (check_violation)');

-- 3. bill_schedule_cfg_v1: key by key, never raises. Hand-written expected values ------------------------------------------------------------------------------
select ok(public.bill_schedule_cfg_v1() = pg_temp.cfg_expected(21, 27, 27),
          'the stored s127 default setting reads as 21 / 27 and the four bills with empty account, pay-to and note strings (amount only for internet 1500 and netflix 449) and the stored remind_day 27 on each');
-- reading_day -3 -> held up to 1; pay_day 40 -> held down to 28 (so every bill reminds on 28); amount -5 -> default 1500; label 7 and note ["a"] -> default; netflix "no" (not an object) -> defaults
select ok(pg_temp.cfg_set('{"reading_day":-3,"pay_day":40,"bills":{"internet":{"amount":-5,"label":7,"note":["a"]},"netflix":"no"}}'::jsonb) = pg_temp.cfg_expected(1, 28, 25),
          'wrong JSON types fall back key by key and never raise; days are held to 1..28 (no stored remind_day: the default 25, s131)');
-- pay_day 10.9 -> 10; internet remind_day 3 wins; electric remind_day 40 -> 28; water has none -> the default 25 (s131; it was the pay day 10)
select ok((select c ->> 'pay_day' = '10' and c ->> 'reading_day' = '5' and c #>> '{bills,internet,amount}' = '1234.5' and c #>> '{bills,internet,label}' = 'Zz Net'
                  and c #>> '{bills,internet,pay_to_name}' = 'Zz Payee' and c #>> '{bills,internet,pay_to_number}' = '0900' and c #>> '{bills,internet,note}' = 'Zz note'
                  and c #>> '{bills,electric,account}' = 'ZZ-1' and c #>> '{bills,electric,account_name}' = 'Zz Acct' and c #>> '{bills,electric,label}' = 'Electricity (SOCOTECO II)' and c #>> '{bills,netflix,amount}' = '449'
                  and c #>> '{bills,internet,remind_day}' = '3' and c #>> '{bills,electric,remind_day}' = '28' and c #>> '{bills,water,remind_day}' = '25'
             from (select pg_temp.cfg_set('{"pay_day":10.9,"reading_day":5,"bills":{"internet":{"amount":1234.5,"label":"Zz Net","pay_to_name":"Zz Payee","pay_to_number":"0900","note":"Zz note","remind_day":3},"electric":{"account":"ZZ-1","account_name":"Zz Acct","remind_day":40}}}'::jsonb) c) x),
          'valid custom values win (pay_day 10.9 is cut to 10); a bill''s own remind_day wins and is held to 1..28; every key not set falls back to its default');
select ok(pg_temp.cfg_set('"just a string"'::jsonb) = pg_temp.cfg_expected(), 'a setting row that is not an object falls back to the defaults (s131: remind_day 25 on each bill)');
delete from public.app_settings where key = 'bill_schedule';
select ok(public.bill_schedule_cfg_v1() = pg_temp.cfg_expected()
          and (public.bill_schedule_cfg_v1() ->> 'pay_day') = '27' and (public.bill_schedule_cfg_v1() #>> '{bills,internet,amount}') = '1500',
          'no setting row at all: the defaults (pay day 27, remind day 25, internet 1500)');
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
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'pol_fin_bill', pg_temp.try($$select to_jsonb(count(*)) from public.app_settings where key = 'bill_schedule'$$);
insert into _t select 'pol_fin_pub', pg_temp.try($$select to_jsonb(count(*)) from public.app_settings where key = 'zz128_public'$$);
reset role;
select ok((select v = '0'::jsonb from _t where k = 'pol_anon_bill') and (select v = '1'::jsonb from _t where k = 'pol_anon_pub'), 'anon reads zero rows of bill_schedule but still reads another key');
select ok((select v = '0'::jsonb from _t where k = 'pol_cleaner_bill') and (select v = '1'::jsonb from _t where k = 'pol_cleaner_pub'), 'a cleaner reads zero rows of bill_schedule but still reads another key');
select ok((select v = '1'::jsonb from _t where k = 'pol_admin_bill'), 'an admin (manage_staff) reads the bill_schedule row');
select ok((select v = '0'::jsonb from _t where k = 'pol_fin_bill') and (select v = '1'::jsonb from _t where k = 'pol_fin_pub'), 'a finance-role account (no manage_staff) reads zero rows of bill_schedule but still reads another key');

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
select pg_temp.ub_open(date '2020-02-21');
-- catch-up (Addendum 3.5). b4 has no readings and no rows. 26 April is before pay_day 27, so the PREVIOUS month (2020-03) opens its four missing rows: estimates null, null (no counted reading), 1500, 449.
-- A second call the same day inserts nothing (4 rows). 27 April then opens April as usual (4 more rows, 8 in all).
insert into _t select 'c0', public.bill_due_open_v1(pg_temp.id('b4'), date '2020-04-26');
insert into _t select 'c0b', public.bill_due_open_v1(pg_temp.id('b4'), date '2020-04-26');
insert into _t select 'c1', public.bill_due_open_v1(pg_temp.id('b4'), date '2020-04-27');
select ok((select (select jsonb_agg(e ->> 'kind') from jsonb_array_elements(v -> 'new') e) = '["electric","water","internet","netflix"]'::jsonb
                  and (select bool_and(e ->> 'period' = '2020-03') from jsonb_array_elements(v -> 'new') e)
                  and (select jsonb_agg(e -> 'estimate_php') from jsonb_array_elements(v -> 'new') e) = '[null, null, 1500, 449]'::jsonb from _t where k = 'c0')
          and (select count(*) = 4 and bool_and(status = 'due') from public.utility_bills where property_id = pg_temp.id('b4') and period = '2020-03'),
          'catch-up: on the 26th (before pay_day 27) the previous month 2020-03 opens its four missing rows with their estimates');
select ok((select v = '{"new":[]}'::jsonb from _t where k = 'c0b')
          and (select jsonb_array_length(v -> 'new') = 4 and (select bool_and(e ->> 'period' = '2020-04') from jsonb_array_elements(v -> 'new') e) from _t where k = 'c1')
          and (select count(*) = 8 from public.utility_bills where property_id = pg_temp.id('b4')),
          'catch-up is idempotent (a second call the same day returns nothing), and the 27th still opens its own month');
insert into _t select 'o1', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-03-27');
select ok((select (select jsonb_agg(e ->> 'kind') from jsonb_array_elements(v -> 'new') e) = '["electric","water","internet","netflix"]'::jsonb from _t where k = 'o1')
          and (select count(*) = 4 and bool_and(status = 'due') from public.utility_bills where property_id = pg_temp.id('b1') and period = '2020-03'),
          'the 27th: four rows open (electric, water, internet, netflix, all due)');
select ok((select (select jsonb_agg(e -> 'estimate_php') from jsonb_array_elements(v -> 'new') e) = '[1938.93, 427.13, 1500, 449]'::jsonb from _t where k = 'o1')
          and (select array_agg(estimate_php order by kind) = array[1938.93, 1500, 449, 427.13]::numeric[] from public.utility_bills where property_id = pg_temp.id('b1') and period = '2020-03'),
          'estimates: electric 1938.93 and water 427.13 (the cycle that CLOSES on 21 Mar, started at open_from 21 Feb), internet 1500 and netflix 449 (the fixed amounts)');
select pg_temp.ub_open(null);
select ok((select (v -> 'new' -> 2) ?& array['id', 'ref', 'kind', 'period', 'label', 'status', 'estimate_php', 'paid_php', 'paid_at', 'paid_by_name', 'paying_by_name', 'remind_day']
                 and v -> 'new' -> 2 ->> 'kind' = 'internet' and v -> 'new' -> 2 ->> 'period' = '2020-03' and v -> 'new' -> 2 ->> 'label' = 'Internet' and v -> 'new' -> 2 ->> 'remind_day' = '27'
                 and not ((v -> 'new' -> 2) ?| array['account', 'account_name', 'pay_to_name', 'pay_to_number', 'note', 'number', 'payee_name'])
                 and (select count(*) = 12 from jsonb_object_keys(v -> 'new' -> 2))
                 and v -> 'new' -> 2 ->> 'ref' = upper(left(v -> 'new' -> 2 ->> 'id', 8))
             from _t where k = 'o1'),
          'a bill object carries exactly the twelve keys the daily job needs and none of the account, payee, number or note settings; ref is the first 8 characters of the id, upper case');
insert into _t select 'o1b', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-03-27');
select ok((select v = '{"new":[]}'::jsonb from _t where k = 'o1b') and (select count(*) = 4 from public.utility_bills where property_id = pg_temp.id('b1')),
          'a second call the same day returns nothing new and inserts nothing');
-- April: open on the 27th, then electric stays due, internet is paying, water is PAID (typed proof, a hand fix), netflix is skipped. The 28th opens nothing new.
insert into _t select 'a1', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-04-27');
update public.utility_bills set status = 'skipped' where property_id = pg_temp.id('b1') and period = '2020-04' and kind = 'netflix';
update public.utility_bills set status = 'paying', paying_by = pg_temp.id('a2'), paying_by_name = 'Zz Admin' where property_id = pg_temp.id('b1') and period = '2020-04' and kind = 'internet';
update public.utility_bills set status = 'paid', paid_php = 321.40, paid_at = now(), paid_by_name = 'Zz', proof_verdict = 'typed' where property_id = pg_temp.id('b1') and period = '2020-04' and kind = 'water';
insert into _t select 'a2', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-04-28');
select ok((select jsonb_array_length(v -> 'new') = 4 from _t where k = 'a1')
          and (select v = '{"new":[]}'::jsonb from _t where k = 'a2'),
          'April opens four rows on the 27th; the 28th, with rows due, paying, paid and skipped, opens nothing and returns only {new: []}');
-- May: first opened on the 29th (the run was missed on the 27th and 28th): it opens the four May rows
insert into _t select 'm1', public.bill_due_open_v1(pg_temp.id('b1'), date '2020-05-29');
select ok((select jsonb_array_length(v -> 'new') = 4 and (select bool_and(e ->> 'period' = '2020-05') from jsonb_array_elements(v -> 'new') e) from _t where k = 'm1'),
          'a late first run (the 29th) opens the four rows of its own month');
-- b2 has no reading: a meter bill has no estimate (null, never 0) while the fixed ones keep theirs
insert into _t select 'p1', public.bill_due_open_v1(pg_temp.id('b2'), date '2020-03-27');
select ok((select (select jsonb_agg(e -> 'estimate_php') from jsonb_array_elements(v -> 'new') e) = '[null, null, 1500, 449]'::jsonb from _t where k = 'p1'),
          'no counted reading: electric and water estimates are null; internet 1500 and netflix 449');
-- a custom schedule: pay_day 10, internet 1600, netflix 500 labelled "Zz Stream"
select pg_temp.cfg_set('{"pay_day":10,"bills":{"electric":{"remind_day":10},"water":{"remind_day":10},"internet":{"amount":1600,"remind_day":10},"netflix":{"label":"Zz Stream","amount":500,"remind_day":10}}}'::jsonb) is not null as custom;
insert into _t select 'q0', public.bill_due_open_v1(pg_temp.id('b2'), date '2020-06-09');
insert into _t select 'q1', public.bill_due_open_v1(pg_temp.id('b2'), date '2020-06-10');
select ok((select jsonb_array_length(v -> 'new') = 4 and (select bool_and(e ->> 'period' = '2020-05') from jsonb_array_elements(v -> 'new') e) from _t where k = 'q0')
          and (select jsonb_array_length(v -> 'new') = 4 and (select bool_and(e ->> 'period' = '2020-06') from jsonb_array_elements(v -> 'new') e) from _t where k = 'q1'),
          'remind_day is read from the setting (stored 10 on each bill): the 9th opens only the previous month May, the 10th opens June');
select ok((select (select jsonb_agg(e -> 'estimate_php') from jsonb_array_elements(v -> 'new') e) = '[null, null, 1600, 500]'::jsonb and v -> 'new' -> 3 ->> 'label' = 'Zz Stream' from _t where k = 'q1'),
          'fixed amounts and labels come from the setting (internet 1600, netflix 500 "Zz Stream")');
-- the floor: b5, pay_day 27. On 26 April 2020 the previous month 2020-03 would open, but the floor 2020-04 forbids it (nothing opens); on the 27th April opens
select pg_temp.cfg_set(pg_temp.cfg_default()) is not null as reset2;
insert into _t select 'f0', public.bill_due_open_v1(pg_temp.id('b5'), date '2020-04-26', '2020-04');
insert into _t select 'f1', public.bill_due_open_v1(pg_temp.id('b5'), date '2020-04-27', '2020-04');
select ok((select v = '{"new":[]}'::jsonb from _t where k = 'f0')
          and (select jsonb_array_length(v -> 'new') = 4 and (select bool_and(e ->> 'period' = '2020-04') from jsonb_array_elements(v -> 'new') e) from _t where k = 'f1')
          and (select count(*) = 4 and min(period) = '2020-04' from public.utility_bills where property_id = pg_temp.id('b5')),
          'the p_min_period floor: no row is opened for a month before it (March stays closed on the 26th); the 27th opens April');
-- a bill's own remind_day: b6, internet remind_day 5. On 6 June 2020 internet (6 >= 5) opens June; electric, water and netflix (pay_day 27) are still before their day and open the previous month May
select pg_temp.cfg_set('{"bills":{"internet":{"remind_day":5}}}'::jsonb) is not null as rd;
insert into _t select 'rd', public.bill_due_open_v1(pg_temp.id('b6'), date '2020-06-06');
select pg_temp.cfg_set(pg_temp.cfg_default()) is not null as reset3;
select ok((select (select jsonb_agg((e ->> 'kind') || ':' || (e ->> 'period')) from jsonb_array_elements(v -> 'new') e) = '["electric:2020-05","water:2020-05","internet:2020-06","netflix:2020-05"]'::jsonb from _t where k = 'rd')
          and (select (select e ->> 'remind_day' from jsonb_array_elements(v -> 'new') e where e ->> 'kind' = 'internet') = '5' from _t where k = 'rd'),
          'remind_day is a real setting: internet with remind_day 5 opens June on the 6th while the other three (default 25) open May; the bill carries its remind_day');

-- 6. bill_step_v1 (internal core) on b1, March: electric (1938.93), water (427.13), internet (1500), netflix (449). Actors: admin a2 "Zz Admin", finance a4 "Zz Finance", finance a7 "Zz Guest".
insert into _t select 'g4', pg_temp.gst(pg_temp.bid('water', 'b1', '2020-03'), 'pay');
insert into _t select 'g5', pg_temp.fin(pg_temp.bid('netflix', 'b1', '2020-03'), 'pay');
select ok((select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'paying' and v -> 'bill' ->> 'paying_by_name' = 'Zz Guest' from _t where k = 'g4')
          and (select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'paying' from _t where k = 'g5')
          and (select paying_by = pg_temp.id('a4') and paying_at is not null from public.utility_bills where id = pg_temp.bid('netflix', 'b1', '2020-03')),
          'two finance users may pay: due becomes paying and records who (the user id and the name) and when');
insert into _t select 'n0', public.bill_step_v1(pg_temp.bid('electric', 'b1', '2020-03'), 'pay', null, 'Zz Nobody');
insert into _t select 'n1', pg_temp.adm('e1280000-0000-4000-8000-0000000000ff', 'pay');
insert into _t select 'n2', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'zzz');
insert into _t select 'n3', pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'pay');
select ok((select v = '{"ok":false,"reason":"bad_step"}'::jsonb from _t where k = 'n0') and (select v = '{"ok":false,"reason":"not_found"}'::jsonb from _t where k = 'n1')
          and (select v = '{"ok":false,"reason":"bad_step"}'::jsonb from _t where k = 'n2') and (select v ->> 'reason' = 'bad_step' from _t where k = 'n3')
          and (select paying_by = pg_temp.id('a4') from public.utility_bills where id = pg_temp.bid('netflix', 'b1', '2020-03'))
          and (select status = 'due' and paying_by is null from public.utility_bills where id = pg_temp.bid('electric', 'b1', '2020-03')),
          'no actor is bad_step, an unknown id is not_found, an unknown step is bad_step, and a second person cannot take over a bill someone else is paying (bad_step; the first payer stays)');
insert into _t select 'n4', pg_temp.fin(pg_temp.bid('netflix', 'b1', '2020-03'), 'pay');
insert into _t select 'n5', pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'cancel');
insert into _t select 'n6', pg_temp.adm(pg_temp.bid('netflix', 'b1', '2020-03'), 'cancel');
select ok((select v ->> 'ok' = 'true' from _t where k = 'n4') and (select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'due' from _t where k = 'n5') and (select v ->> 'reason' = 'bad_step' from _t where k = 'n6')
          and (select paying_by is null and paying_by_name is null and paying_at is null from public.utility_bills where id = pg_temp.bid('netflix', 'b1', '2020-03')),
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
                      and t.property_id = pg_temp.id('b1') and t.transaction_date = public.manila_today() and t.logged_by = 'Staff app: Zz Admin'
                      and t.notes = 'Utility bill electric 2020-03 (Electricity (SOCOTECO II)). Bill ' || (select ref from public.utility_bills where id = pg_temp.bid('electric', 'b1', '2020-03')) || '.'
                 from public.transactions t where t.external_ref = 'bill:electric:2020-03'),
          'exactly ONE transactions row: expense, utilities, confirmed, source bill, 1960.50, payee the bill label, Manila today, logged by Staff app: Zz Admin, notes naming kind, period and ref');
select ok((select b.txn_id = (select id from public.transactions where external_ref = 'bill:electric:2020-03') and b.proof_verdict = 'read' and b.proof_sha256 = 'zz128-s1' and b.proof_file_unique_id = 'zz128-u1'
                  and b.proof_file_id = 'zz128-f1' and b.proof_amount = 1960.50 and b.proof_reference = 'ZZREF1' and b.paid_php = 1960.50 and b.paid_by = pg_temp.id('a2') and b.paid_at is not null
             from public.utility_bills b where b.id = pg_temp.bid('electric', 'b1', '2020-03')),
          'the bill row stores txn_id, the verdict read, the screenshot ids and sha256, the amount read, the reference and who paid (the user id)');
insert into _t select 'e2', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'paid', pg_temp.rp(1999));
insert into _t select 'e3', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'paid',
  '{"file_unique_id":"zz128-u1","file_id":"zz128-f1","sha256":"zz128-s1","amount":1960.5,"verdict":"read"}'::jsonb);
select ok((select v ->> 'reason' = 'already_paid' and v ->> 'ok' = 'false' and v -> 'bill' ->> 'status' = 'paid' and (v -> 'bill' ->> 'paid_php')::numeric = 1960.5 from _t where k = 'e2')
          and (select v ->> 'reason' = 'already_paid' and v -> 'bill' ->> 'status' = 'paid' from _t where k = 'e3')
          and (select count(*) = 1 from public.transactions where external_ref = 'bill:electric:2020-03')
          and (select paid_php = 1960.50 from public.utility_bills where id = pg_temp.bid('electric', 'b1', '2020-03')),
          'a repeat paid (new screenshot or the same one) is already_paid and still carries the bill: still one transaction and the amount is unchanged');
insert into _t select 'x1', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'pay');
insert into _t select 'x2', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'cancel');
insert into _t select 'x3', pg_temp.adm(pg_temp.bid('electric', 'b1', '2020-03'), 'skip');
select ok((select bool_and(v ->> 'reason' = 'already_paid') from _t where k in ('x1', 'x2', 'x3')), 'pay, cancel and skip on a paid bill are all already_paid');
-- duplicate screenshot across bills: the same sha256 with a new file id, and the same file id with a new sha256
insert into _t select 'd1', pg_temp.gst(pg_temp.bid('water', 'b1', '2020-03'), 'paid',
  '{"file_unique_id":"zz128-u2","sha256":"zz128-s1","amount":430,"verdict":"read"}'::jsonb);
insert into _t select 'd2', pg_temp.gst(pg_temp.bid('water', 'b1', '2020-03'), 'paid',
  '{"file_unique_id":"zz128-u1","sha256":"zz128-s2","amount":430,"verdict":"read"}'::jsonb);
select ok((select v ->> 'reason' = 'duplicate_proof' and v ->> 'other_ref' = (select ref from public.utility_bills where id = pg_temp.bid('electric', 'b1', '2020-03')) from _t where k = 'd1')
          and (select v ->> 'reason' = 'duplicate_proof' from _t where k = 'd2')
          and (select status = 'paying' and proof_sha256 is null from public.utility_bills where id = pg_temp.bid('water', 'b1', '2020-03'))
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:water:2020-03'),
          'the electric screenshot used on the water bill is duplicate_proof by sha256 or by file id, naming the other bill; the water bill is unchanged and nothing is written');
insert into _t select 'w1', pg_temp.gst(pg_temp.bid('water', 'b1', '2020-03'), 'paid', '{"file_unique_id":"zz128-u3","file_id":"zz128-f3","sha256":"zz128-s3","amount":430,"verdict":"read"}'::jsonb);
select ok((select v ->> 'ok' = 'true' and (v ->> 'paid_php')::numeric = 430 from _t where k = 'w1')
          and (select paying_by_name = 'Zz Guest' and paid_by_name = 'Zz Guest' and paid_by = pg_temp.id('a7') from public.utility_bills where id = pg_temp.bid('water', 'b1', '2020-03'))
          and (select count(*) = 1 from public.transactions where external_ref = 'bill:water:2020-03' and gross_amount = 430 and payee_name = 'Water (Gensan Water District)'),
          'water paid 430 (inside 213.565 .. 854.26 around the estimate 427.13): the person who tapped pay (Zz Guest) settles it and is recorded as payer and settler');
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
-- a proof with no screenshot ids is not a proof (bad_step), and a typed override is no longer one either; neither is a missing proof or one that is not an object
insert into _t select 'bs', jsonb_build_array(
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', null),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"amount":1510}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"amount":1510,"sha256":"zz-c"}'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '[1]'),
  pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', '{"typed":true,"amount":1510,"verdict":"typed"}'));
select ok((select (select jsonb_agg(e ->> 'reason') from jsonb_array_elements(v) e) = '["bad_step","bad_step","bad_step","bad_step","bad_step"]'::jsonb from _t where k = 'bs')
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:internet:2020-03'),
          'no proof, no screenshot ids, one id missing, a non-object proof and a typed override are all bad_step; nothing is written');
-- a screenshot pay: 1510 inside the fixed band 1500 .. 1550; verdict read, the screenshot ids are stored
insert into _t select 'ty', pg_temp.adm(pg_temp.bid('internet', 'b1', '2020-03'), 'paid', pg_temp.rp(1510));
select ok((select v ->> 'ok' = 'true' and (v ->> 'paid_php')::numeric = 1510 from _t where k = 'ty')
          and (select proof_verdict = 'read' and proof_sha256 is not null and proof_file_unique_id is not null and proof_amount = 1510 and paid_php = 1510 and txn_id is not null from public.utility_bills where id = pg_temp.bid('internet', 'b1', '2020-03'))
          and (select count(*) = 1 and sum(gross_amount) = 1510 from public.transactions where external_ref = 'bill:internet:2020-03'),
          'screenshot pay of 1510 inside the band: verdict read, sha256 and file id stored, one transaction of 1510');
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
-- Addendum 3.1 ledger link. b2 netflix 2021-01 .. 2021-06 (estimate 449, band 449 .. 499, so a screenshot reading 449 passes the band and reaches the ledger check).
-- The ledger already holds a row for the ref of 2021-01 (amount 400, not 449), 2021-02 (another property, b1), 2021-03 (source manual) and 2021-04 (status void; the unique index counts void rows).
-- None may be linked or doubled: each paid is a plain 55000 sentence naming the ref (and what differs), and the bill stays due. 2021-05 serves the payer test, 2021-06 the staff-pay screenshot test.
insert into public.utility_bills(property_id, kind, period, estimate_php) values
  (pg_temp.id('b2'), 'netflix', '2021-01', 449), (pg_temp.id('b2'), 'netflix', '2021-02', 449), (pg_temp.id('b2'), 'netflix', '2021-03', 449),
  (pg_temp.id('b2'), 'netflix', '2021-04', 449), (pg_temp.id('b2'), 'netflix', '2021-05', 449), (pg_temp.id('b2'), 'netflix', '2021-06', 449);
insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by) values
  (pg_temp.id('b2'), 'expense', 'utilities', 'confirmed', 'bill', 400, 'Zz Netflix', date '2021-01-27', 'bill:netflix:2021-01', 'Zz amount mismatch', 'Zz'),
  (pg_temp.id('b1'), 'expense', 'utilities', 'confirmed', 'bill', 449, 'Zz Netflix', date '2021-02-27', 'bill:netflix:2021-02', 'Zz property mismatch', 'Zz'),
  (pg_temp.id('b2'), 'expense', 'utilities', 'confirmed', 'manual', 449, 'Zz Netflix', date '2021-03-27', 'bill:netflix:2021-03', 'Zz source mismatch', 'Zz'),
  (pg_temp.id('b2'), 'expense', 'utilities', 'void', 'bill', 449, 'Zz Netflix', date '2021-04-27', 'bill:netflix:2021-04', 'Zz voided row', 'Zz');
insert into _t select 'lk', jsonb_build_array(
  pg_temp.try($$select pg_temp.adm(pg_temp.bid('netflix', 'b2', '2021-01'), 'paid', pg_temp.rp(449))$$),
  pg_temp.try($$select pg_temp.adm(pg_temp.bid('netflix', 'b2', '2021-02'), 'paid', pg_temp.rp(449))$$),
  pg_temp.try($$select pg_temp.adm(pg_temp.bid('netflix', 'b2', '2021-03'), 'paid', pg_temp.rp(449))$$));
select ok((select count(*) = 3 and bool_and(e ->> 'err' = '55000' and e ->> 'msg' like '%bill:netflix:2021-0' || i || '%'
                  and e ->> 'msg' like case i when 1 then '%amount 400%' when 2 then '%another property%' else '%source manual%' end)
             from _t, jsonb_array_elements(v) with ordinality t(e, i) where k = 'lk')
          and (select count(*) = 0 from public.utility_bills where property_id = pg_temp.id('b2') and kind = 'netflix' and period in ('2021-01', '2021-02', '2021-03')
                      and (status <> 'due' or txn_id is not null or proof_sha256 is not null))
          and (select count(*) = 3 and bool_and(notes like 'Zz %') from public.transactions where external_ref in ('bill:netflix:2021-01', 'bill:netflix:2021-02', 'bill:netflix:2021-03')),
          'an existing ledger row with another amount, another property or another source is never linked: paid raises 55000 naming the ref and what differs; the bill stays due and the row is untouched');
insert into _t select 'lv', pg_temp.try($$select pg_temp.adm(pg_temp.bid('netflix', 'b2', '2021-04'), 'paid', pg_temp.rp(449))$$);
select ok((select v ->> 'err' = '55000' and v ->> 'msg' like '%voided row%' and v ->> 'msg' like '%bill:netflix:2021-04%'
                  and v ->> 'msg' like '%' || (select id::text from public.transactions where external_ref = 'bill:netflix:2021-04') || '%' from _t where k = 'lv')
          and (select status = 'due' and txn_id is null from public.utility_bills where id = pg_temp.bid('netflix', 'b2', '2021-04'))
          and (select count(*) = 1 from public.transactions where external_ref = 'bill:netflix:2021-04'),
          'a VOID ledger row with the ref is refused with a plain 55000 message naming the ref and the row id (never a raw 23505); nothing is written');
-- Addendum 3.2 only the person who tapped pay settles or skips. Admin a2 taps pay on 2021-05; the finance users a4 and a7 cannot paid or skip it.
insert into _t select 'pp0', pg_temp.adm(pg_temp.bid('netflix', 'b2', '2021-05'), 'pay');
insert into _t select 'pp1', pg_temp.fin(pg_temp.bid('netflix', 'b2', '2021-05'), 'paid', pg_temp.rp(449));
insert into _t select 'pp2', pg_temp.fin(pg_temp.bid('netflix', 'b2', '2021-05'), 'skip');
insert into _t select 'pp3', pg_temp.gst(pg_temp.bid('netflix', 'b2', '2021-05'), 'paid', pg_temp.rp(449));
select ok((select v ->> 'ok' = 'true' from _t where k = 'pp0')
          and (select count(*) = 3 and bool_and(v ->> 'ok' = 'false' and v ->> 'reason' = 'bad_step' and v -> 'bill' ->> 'status' = 'paying') from _t where k in ('pp1', 'pp2', 'pp3'))
          and (select status = 'paying' and paying_by = pg_temp.id('a2') and paid_php is null and txn_id is null from public.utility_bills where id = pg_temp.bid('netflix', 'b2', '2021-05'))
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:netflix:2021-05'),
          'paid and skip by someone other than the payer are bad_step: the bill stays paying under the first payer and nothing is written');
insert into _t select 'pp4', pg_temp.adm(pg_temp.bid('netflix', 'b2', '2021-05'), 'skip');
select ok((select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'skipped' from _t where k = 'pp4') and (select count(*) = 0 from public.transactions where external_ref = 'bill:netflix:2021-05'),
          'the person who tapped pay may skip her own bill: skipped, no transaction');
-- Addendum 3.3 a screenshot that settled a STAFF payment cannot settle a bill: same sha256 with a new file id, and same file id with a new sha256.
insert into public.staff_pay_requests(property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount, paid_at, paid_by_name, proof_file_unique_id, proof_sha256, proof_verdict) values
  (pg_temp.id('b2'), pg_temp.id('a1'), 'Zz Cleaner', 'zz128-pay-0001', 'paid', '[{"n":1}]'::jsonb, 500, now(), 'Zz128', 'zz128-sp-u', 'zz128-sp-s', 'match');
insert into _t select 'sp1', pg_temp.adm(pg_temp.bid('netflix', 'b2', '2021-06'), 'paid', '{"file_unique_id":"zz128-sp-u2","sha256":"zz128-sp-s","amount":449,"verdict":"read"}'::jsonb);
insert into _t select 'sp2', pg_temp.adm(pg_temp.bid('netflix', 'b2', '2021-06'), 'paid', '{"file_unique_id":"zz128-sp-u","sha256":"zz128-sp-s2","amount":449,"verdict":"read"}'::jsonb);
select ok((select count(*) = 2 and bool_and(v ->> 'reason' = 'duplicate_proof' and v ->> 'other_ref' = (select ref from public.staff_pay_requests where idempotency_key = 'zz128-pay-0001')) from _t where k in ('sp1', 'sp2'))
          and (select status = 'due' and proof_sha256 is null and txn_id is null from public.utility_bills where id = pg_temp.bid('netflix', 'b2', '2021-06'))
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:netflix:2021-06'),
          'a screenshot already used on a staff payment is duplicate_proof for a bill (by sha256 or by file id), naming the staff request; nothing is written');
-- table checks. b2 netflix 2020-06 is skipped (never paid): status paid alone has no amount, time, name or proof
insert into _t select 'ck1', pg_temp.try($$update public.utility_bills set status = 'paid' where id = (select id from public.utility_bills where property_id = 'e1280000-0000-4000-8000-0000000000b2' and kind = 'netflix' and period = '2020-06') returning to_jsonb(1)$$);
insert into _t select 'ck2', pg_temp.try($$update public.utility_bills set status = 'paid', paid_php = 5, paid_at = now(), paid_by_name = 'Zz', proof_verdict = 'read' where id = (select id from public.utility_bills where property_id = 'e1280000-0000-4000-8000-0000000000b2' and kind = 'netflix' and period = '2020-06') returning to_jsonb(1)$$);
insert into _t select 'ck3', pg_temp.try($$update public.utility_bills set proof_sha256 = 'zz128-s1' where id = (select id from public.utility_bills where property_id = 'e1280000-0000-4000-8000-0000000000b2' and kind = 'netflix' and period = '2020-06') returning to_jsonb(1)$$);
select ok((select v ->> 'err' = '23514' from _t where k = 'ck1'), 'the table itself refuses status paid with no amount, time, name or proof (check_violation)');
select ok((select v ->> 'err' = '23514' from _t where k = 'ck2'), 'the table itself refuses PAID with a read verdict and no sha256 (check_violation)');
select ok((select v ->> 'err' = '23505' from _t where k = 'ck3'), 'the table itself refuses a second row with an already used screenshot sha256 (unique violation)');

-- 6b. the Staff app functions, called as real roles. Property b7. Admin a2 "Zz Admin" (approve_payment + manage_staff), finance a4 "Zz Finance" (approve_payment only), cleaner a1, laundry a3, disabled admin a5, a user with no profile a6.
-- Bills (all estimate fixtures): electric 2020-10 est 1000 (band 500 .. 2000), internet 2020-10 est 1500 (band 1500 .. 1550), netflix 2020-10 est 449, netflix 2020-11 est 449, netflix 2020-12 est 449,
-- internet 2020-11 est 1500, internet 2020-12 est 1500, internet 2021-01 est 1500. Settings: electric pay-to account ZZ-ACCT-1 / "Zz Power" / note "Zz {month} bill"; internet GCash "Zz Net" / 0900-000-0000.
select pg_temp.cfg_set('{"bills":{"electric":{"account":"ZZ-ACCT-1","account_name":"Zz Power","note":"Zz {month} bill"},"internet":{"pay_to_name":"Zz Net","pay_to_number":"0900-000-0000"}}}'::jsonb) is not null as appcfg;
insert into public.utility_bills(property_id, kind, period, estimate_php) values
  (pg_temp.id('b7'), 'electric', '2020-10', 1000), (pg_temp.id('b7'), 'internet', '2020-10', 1500), (pg_temp.id('b7'), 'netflix', '2020-10', 449), (pg_temp.id('b7'), 'netflix', '2020-11', 449),
  (pg_temp.id('b7'), 'netflix', '2020-12', 449), (pg_temp.id('b7'), 'internet', '2020-11', 1500), (pg_temp.id('b7'), 'internet', '2020-12', 1500), (pg_temp.id('b7'), 'internet', '2021-01', 1500);
select pg_temp.reg('el10', 'electric', 'b7', '2020-10'), pg_temp.reg('in10', 'internet', 'b7', '2020-10'), pg_temp.reg('nf10', 'netflix', 'b7', '2020-10'), pg_temp.reg('nf11', 'netflix', 'b7', '2020-11'),
       pg_temp.reg('nf12', 'netflix', 'b7', '2020-12'), pg_temp.reg('in11', 'internet', 'b7', '2020-11'), pg_temp.reg('in12', 'internet', 'b7', '2020-12'), pg_temp.reg('in13', 'internet', 'b7', '2021-01');
-- stored screenshots (object in the private bucket + the sha256 upload-photo recorded). p_el: admin's folder, hash aaaa; p_mis: the finance user's folder; p_dup: finance folder with the SAME hash as p_el;
-- p_sp: finance folder, hash eeee (also on a staff payment); p_in: finance folder, hash cccc; p_nohash: an object whose hash was never recorded is simply absent here
insert into _t select 'p_el', to_jsonb(pg_temp.ph('b7', 'a2', 'zz-electric-proof-0001.jpg', 'a'));
insert into _t select 'p_mis', to_jsonb(pg_temp.ph('b7', 'a4', 'zz-other-folder-proof-01.jpg', 'b'));
insert into _t select 'p_dup', to_jsonb(pg_temp.ph('b7', 'a4', 'zz-same-hash-as-electric1.jpg', 'a'));
insert into _t select 'p_sp', to_jsonb(pg_temp.ph('b7', 'a4', 'zz-staff-pay-screenshot-1.jpg', 'e'));
insert into _t select 'p_in', to_jsonb(pg_temp.ph('b7', 'a4', 'zz-internet-proof-0000001.jpg', 'c'));
insert into public.staff_pay_requests(property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount, paid_at, paid_by_name, proof_file_unique_id, proof_sha256, proof_verdict) values
  (pg_temp.id('b7'), pg_temp.id('a1'), 'Zz Cleaner', 'zz128-pay-0002', 'paid', '[{"n":1}]'::jsonb, 500, now(), 'Zz128', 'zz128-sp-u3', repeat('e', 64), 'match');

-- every refusal. anon: the grant is missing (42501). Signed-in users with no right get {ok:false, reason:not_authorized}, never not_found, and nothing changes.
select pg_temp.as_anon();
insert into _t select 'ra', jsonb_build_array(
  pg_temp.c1('bill_pay_open_v1', pg_temp.bi('nf10')), pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('nf10'), '{}'::jsonb), pg_temp.c1('bill_pay_cancel_v1', pg_temp.bi('nf10')), pg_temp.c1('bill_pay_skip_v1', pg_temp.bi('nf10')),
  pg_temp.c1('bill_proof_v1', pg_temp.bi('nf10')), pg_temp.cs('bill_schedule_get_v1', pg_temp.id('b7'), 'internet'), pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"note":"x"}'::jsonb),
  pg_temp.c1('today_bills_v1', pg_temp.id('b7')));
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'rc', jsonb_build_array(
  pg_temp.c1('bill_pay_open_v1', pg_temp.bi('nf10')), pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('nf10'), '{}'::jsonb), pg_temp.c1('bill_pay_cancel_v1', pg_temp.bi('nf10')), pg_temp.c1('bill_pay_skip_v1', pg_temp.bi('nf10')),
  pg_temp.c1('bill_proof_v1', pg_temp.bi('nf10')), pg_temp.cs('bill_schedule_get_v1', pg_temp.id('b7'), 'internet'), pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"note":"x"}'::jsonb));
insert into _t select 'rm', pg_temp.c1('bill_pay_open_v1', 'e1280000-0000-4000-8000-0000000000ee');
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'rl', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('nf10'));
select pg_temp.as_user(pg_temp.id('a6'));
insert into _t select 'rn', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('nf10'));
select pg_temp.as_user(pg_temp.id('a5'));
insert into _t select 'rdz', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('nf10'));
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'rf', jsonb_build_array(pg_temp.cs('bill_schedule_get_v1', pg_temp.id('b7'), 'internet'), pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"note":"x"}'::jsonb));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'rx', pg_temp.c1('bill_pay_open_v1', 'e1280000-0000-4000-8000-0000000000ee');
reset role;
select ok((select jsonb_array_length(v) = 8 and (select bool_and(e ->> 'err' = '42501') from jsonb_array_elements(v) e) from _t where k = 'ra'),
          'anon cannot run any of the eight Staff app functions (permission denied, called as anon)');
select ok((select jsonb_array_length(v) = 7 and (select bool_and(e = '{"ok":false,"reason":"not_authorized"}'::jsonb) from jsonb_array_elements(v) e) from _t where k = 'rc')
          and (select status = 'due' and paying_by is null from public.utility_bills where id = pg_temp.bi('nf10'))
          and (select count(*) = 0 from public.transactions where source = 'bill' and property_id = pg_temp.id('b7')),
          'a signed-in cleaner is not_authorized on open, settle, cancel, skip, proof, schedule get and schedule set; the bill is unchanged and nothing is written');
select ok((select v = '{"ok":false,"reason":"not_authorized"}'::jsonb from _t where k = 'rl') and (select v = '{"ok":false,"reason":"not_authorized"}'::jsonb from _t where k = 'rn')
          and (select v = '{"ok":false,"reason":"not_authorized"}'::jsonb from _t where k = 'rdz'),
          'laundry, a user with no staff profile and a disabled admin are not_authorized on pay open');
select ok((select v = '[{"ok":false,"reason":"not_authorized"},{"ok":false,"reason":"not_authorized"}]'::jsonb from _t where k = 'rf')
          and (select value = pg_temp.cfg_expected() is not null from public.app_settings where key = 'bill_schedule')
          and (select value #>> '{bills,internet,pay_to_name}' = 'Zz Net' and not (value #> '{bills,internet}' ? 'zz') from public.app_settings where key = 'bill_schedule'),
          'a finance user (approve_payment, no manage_staff) is not_authorized on schedule get and set, and the setting is unchanged');
select ok((select v = '{"ok":false,"reason":"not_authorized"}'::jsonb from _t where k = 'rm') and (select v = '{"ok":false,"reason":"not_found"}'::jsonb from _t where k = 'rx'),
          'a bill id that does not exist is not_authorized for a cleaner (never not_found, so nothing leaks) and not_found for an admin');

-- pay open. Admin a2 opens electric 2020-10: marks it paying by a2 and returns where to pay. The note "Zz {month} bill" gets the month (October 2020). Amount editable (estimate bill). can_edit true (admin).
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'op1', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('el10'));
insert into _t select 'op2', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('el10'));
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'op3', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('el10'));
insert into _t select 'op4', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('in10'));
reset role;
select ok((select v = jsonb_build_object('ok', true,
              'bill', jsonb_build_object('id', pg_temp.bi('el10'), 'kind', 'electric', 'label', 'Electricity (SOCOTECO II)', 'period', '2020-10', 'status', 'paying', 'estimate_php', 1000, 'paid_php', null,
                                         'is_estimate', true, 'due_day', 27, 'paying_by_name', 'Zz Admin', 'paid_by_name', null, 'paid_at', null, 'can_pay', true),
              'pay', jsonb_build_object('payee_name', 'Zz Power', 'number_label', 'Account number', 'number', 'ZZ-ACCT-1', 'note', 'Zz October 2020 bill', 'amount_php', 1000, 'amount_editable', true),
              'can_edit', true) from _t where k = 'op1')
          and (select status = 'paying' and paying_by = pg_temp.id('a2') and paying_by_name = 'Zz Admin' from public.utility_bills where id = pg_temp.bi('el10')),
          'bill_pay_open_v1 as admin: the exact answer (bill entry, pay details with the month filled in, amount_editable true, can_edit true) and the bill is paying by the caller');
select ok((select (select v from _t where k = 'op2') = (select v from _t where k = 'op1')), 'calling pay open again as the same payer returns the same answer');
select ok((select v = '{"ok":false,"reason":"paying_by_other","name":"Zz Admin"}'::jsonb from _t where k = 'op3'), 'another finance user opening a bill someone else is paying gets paying_by_other with the payer''s name');
-- internet: payee and number come from the pay-to settings, number_label "GCash number", the default note is the label and the month, the amount is fixed, a finance user cannot edit
select ok((select v -> 'pay' = jsonb_build_object('payee_name', 'Zz Net', 'number_label', 'GCash number', 'number', '0900-000-0000', 'note', 'Internet October 2020', 'amount_php', 1500, 'amount_editable', false)
                  and v -> 'bill' ->> 'status' = 'paying' and v -> 'bill' ->> 'paying_by_name' = 'Zz Finance' and v -> 'bill' ->> 'can_pay' = 'true' and v -> 'bill' ->> 'is_estimate' = 'false'
                  and v ->> 'can_edit' = 'false' from _t where k = 'op4'),
          'internet pay open as finance: GCash number label, the default note names the month, the amount is fixed, can_edit false (no manage_staff)');

-- settle. el10 is paying by a2. s131: an electric bill needs the reading date printed on it; the cycle of b7 starts at open_from 2020-09-21 here, so 25 Oct 2020 is a valid date (after it, in the month before the billed one or later, not in the future).
select pg_temp.ub_open(date '2020-09-21');
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'st1', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el10'), jsonb_build_object('reading_date', '2020-10-25', 'path', (select v #>> '{}' from _t where k = 'p_el'), 'amount', 1200));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'st2', jsonb_build_array(
  pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el10'), jsonb_build_object('reading_date', '2020-10-25', 'path', (select v #>> '{}' from _t where k = 'p_mis'), 'amount', 1200)),
  pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el10'), jsonb_build_object('reading_date', '2020-10-25', 'path', (select v #>> '{}' from _t where k = 'p_el') || '/../x', 'amount', 1200)),
  pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el10'), jsonb_build_object('reading_date', '2020-10-25', 'path', 'e1280000-0000-4000-8000-0000000000b7/e1280000-0000-4000-8000-0000000000a2/zz-never-stored-000001.jpg', 'amount', 1200)),
  pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el10'), jsonb_build_object('reading_date', '2020-10-25', 'path', (select v #>> '{}' from _t where k = 'p_el'), 'sha256', repeat('b', 64), 'amount', 1200)),
  pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el10'), jsonb_build_object('reading_date', '2020-10-25', 'path', (select v #>> '{}' from _t where k = 'p_el'))));
insert into _t select 'st3', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el10'), jsonb_build_object('reading_date', '2020-10-25', 'path', (select v #>> '{}' from _t where k = 'p_el'), 'amount', 3000));
-- snapshot of the bill after the refusals, before st4 pays it (superuser reads; the table is closed to the API roles)
reset role;
insert into _t select 'sb', jsonb_build_object('paying', b.status = 'paying', 'no_txn', b.txn_id is null, 'no_sha', b.proof_sha256 is null,
  'n_txn', (select count(*) from public.transactions where external_ref = 'bill:electric:2020-10')) from public.utility_bills b where b.id = pg_temp.bi('el10');
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'st4', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el10'), jsonb_build_object('reading_date', '2020-10-25', 'path', (select v #>> '{}' from _t where k = 'p_el'), 'amount', 3000, 'confirmed', true));
insert into _t select 'st5', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('el10'), jsonb_build_object('reading_date', '2020-10-25', 'path', (select v #>> '{}' from _t where k = 'p_el'), 'amount', 3000, 'confirmed', true));
reset role;
select pg_temp.ub_open(null);
select pg_temp.as_user(pg_temp.id('a2'));
reset role;
select ok((select v = '{"ok":false,"reason":"not_payer","name":"Zz Admin"}'::jsonb from _t where k = 'st1') and (select v = '{"paying":true,"no_txn":true,"no_sha":true,"n_txn":0}'::jsonb from _t where k = 'sb'),
          'settle by a finance user who did not tap pay is not_payer (naming the payer) and the bill is unchanged');
select ok((select (select jsonb_agg(e ->> 'reason') from jsonb_array_elements(v) e) = '["bad_proof","bad_proof","no_stored_proof","sha_mismatch","bad_amount"]'::jsonb from _t where k = 'st2')
          and (select v = '{"paying":true,"no_txn":true,"no_sha":true,"n_txn":0}'::jsonb from _t where k = 'sb'),
          'a path in another user''s folder, a path with .., an object never stored, a client sha256 that differs from the recorded one, and a missing amount are all refused (bad_proof, bad_proof, no_stored_proof, sha_mismatch, bad_amount); nothing is written');
select ok((select v = '{"ok":false,"reason":"confirm_amount","read":3000,"estimate_php":1000}'::jsonb from _t where k = 'st3') and (select v = '{"paying":true,"no_txn":true,"no_sha":true,"n_txn":0}'::jsonb from _t where k = 'sb'),
          '3000 is above the band 500 .. 2000 around the estimate 1000: confirm_amount with read 3000 and estimate_php 1000; the bill is unchanged');
select ok((select v ->> 'ok' = 'true' and (v ->> 'paid_php')::numeric = 3000 and v -> 'bill' ->> 'status' = 'paid' and v -> 'bill' ->> 'paid_by_name' = 'Zz Admin' and v -> 'bill' ->> 'can_pay' = 'false'
                  and (v -> 'bill' ->> 'paid_php')::numeric = 3000 from _t where k = 'st4'),
          'the same call with confirmed true logs it: ok, paid_php 3000, the bill entry is paid by Zz Admin and can_pay is false');
select ok((select count(*) = 1 from public.transactions where external_ref = 'bill:electric:2020-10')
          and (select t.txn_type = 'expense' and t.category = 'utilities' and t.source = 'bill' and t.status = 'confirmed' and t.gross_amount = 3000 and t.property_id = pg_temp.id('b7') and t.logged_by = 'Staff app: Zz Admin'
                 from public.transactions t where t.external_ref = 'bill:electric:2020-10')
          and (select b.proof_path = (select v #>> '{}' from _t where k = 'p_el') and b.proof_sha256 = repeat('a', 64) and b.proof_file_unique_id = 'web:' || (select v #>> '{}' from _t where k = 'p_el')
                      and b.proof_verdict = 'read' and b.paid_by = pg_temp.id('a2') and b.paid_php = 3000 and b.txn_id is not null
                 from public.utility_bills b where b.id = pg_temp.bi('el10')),
          'one expense row (utilities, source bill, 3000, logged by Staff app: Zz Admin) and the bill row keeps the stored path, the server-side sha256 (not a client value), the paid_by user id and the verdict read');
select ok((select v ->> 'reason' = 'already_paid' and v ->> 'ok' = 'false' and v -> 'bill' ->> 'status' = 'paid' from _t where k = 'st5')
          and (select count(*) = 1 from public.transactions where external_ref = 'bill:electric:2020-10'),
          'settling a paid bill again is already_paid with the bill, and still one transaction');
-- duplicate proof: internet 2020-12 opened by a4, settled with a NEW path whose recorded hash equals the electric bill''s (aaaa): duplicate_proof naming the electric bill.
-- internet 2021-01 settled with a path whose hash (eeee) is on a staff payment: duplicate_proof naming that request. Neither writes anything.
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'du0', jsonb_build_array(pg_temp.c1('bill_pay_open_v1', pg_temp.bi('in12')), pg_temp.c1('bill_pay_open_v1', pg_temp.bi('in13')));
insert into _t select 'du1', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('in12'), jsonb_build_object('path', (select v #>> '{}' from _t where k = 'p_dup'), 'amount', 1510));
insert into _t select 'du2', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('in13'), jsonb_build_object('path', (select v #>> '{}' from _t where k = 'p_sp'), 'amount', 1510));
reset role;
select ok((select v ->> 'reason' = 'duplicate_proof' and v ->> 'other_ref' = (select ref from public.utility_bills where id = pg_temp.bi('el10')) from _t where k = 'du1')
          and (select v ->> 'reason' = 'duplicate_proof' and v ->> 'other_ref' = (select ref from public.staff_pay_requests where idempotency_key = 'zz128-pay-0002') from _t where k = 'du2')
          and (select count(*) = 2 and bool_and(status = 'paying' and proof_sha256 is null and txn_id is null) from public.utility_bills where id in (pg_temp.bi('in12'), pg_temp.bi('in13')))
          and (select count(*) = 0 from public.transactions where external_ref in ('bill:internet:2020-12', 'bill:internet:2021-01')),
          'a screenshot already used on another bill, or on a staff payment, is duplicate_proof (naming that bill or request, found by the server-side hash); nothing is written');
-- success for the finance user: internet 2020-10 (paying by a4) settled with 1510, inside the fixed band 1500 .. 1550
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'si1', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('in10'), jsonb_build_object('path', (select v #>> '{}' from _t where k = 'p_in'), 'amount', 1510));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'si2', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('in10'));
reset role;
select ok((select v ->> 'ok' = 'true' and (v ->> 'paid_php')::numeric = 1510 and v -> 'bill' ->> 'paid_by_name' = 'Zz Finance' from _t where k = 'si1')
          and (select count(*) = 1 and sum(gross_amount) = 1510 and bool_and(logged_by = 'Staff app: Zz Finance') from public.transactions where external_ref = 'bill:internet:2020-10'),
          'a finance user settles internet 1510 inside the fixed band: ok, one expense row logged by Staff app: Zz Finance');
select ok((select v ->> 'reason' = 'already_paid' and v -> 'bill' ->> 'status' = 'paid' and v -> 'bill' ->> 'paid_by_name' = 'Zz Finance' and v -> 'bill' ->> 'can_pay' = 'false' from _t where k = 'si2'),
          'pay open on a paid bill is already_paid with the bill entry (paid by Zz Finance, can_pay false)');

-- cancel. nf10 (due): admin opens it; finance cannot cancel (not_payer, still paying); admin cancels -> due again with the payer cleared; cancelling a due bill is ok.
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'ca0', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('nf10'));
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'ca1', pg_temp.c1('bill_pay_cancel_v1', pg_temp.bi('nf10'));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'ca2', pg_temp.c1('bill_pay_cancel_v1', pg_temp.bi('nf10'));
insert into _t select 'ca3', pg_temp.c1('bill_pay_cancel_v1', pg_temp.bi('nf10'));
reset role;
select ok((select v = '{"ok":false,"reason":"not_payer","name":"Zz Admin"}'::jsonb from _t where k = 'ca1'),
          'cancel by a finance user who did not tap pay is not_payer, naming the payer');
select ok((select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'due' and v -> 'bill' ->> 'paying_by_name' is null and v -> 'bill' ->> 'can_pay' = 'true' from _t where k = 'ca2')
          and (select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'due' from _t where k = 'ca3')
          and (select status = 'due' and paying_by is null and paying_by_name is null and paying_at is null from public.utility_bills where id = pg_temp.bi('nf10')),
          'the payer cancels: the bill is due again with nobody paying and can_pay true; cancelling a bill that is already due is ok');

-- skip. nf11 (due): finance skips it, again is ok, open and settle then say not_found, no ledger row. nf12: admin opens it, finance cannot skip it (not_payer), admin skips. A paid bill (el10) cannot be skipped.
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'sk1', pg_temp.c1('bill_pay_skip_v1', pg_temp.bi('nf11'));
insert into _t select 'sk2', pg_temp.c1('bill_pay_skip_v1', pg_temp.bi('nf11'));
insert into _t select 'sk3', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('nf11'));
insert into _t select 'sk4', pg_temp.c2('bill_pay_settle_v1', pg_temp.bi('nf11'), jsonb_build_object('path', (select v #>> '{}' from _t where k = 'p_in'), 'amount', 449));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'sk5', pg_temp.c1('bill_pay_open_v1', pg_temp.bi('nf12'));
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'sk6', pg_temp.c1('bill_pay_skip_v1', pg_temp.bi('nf12'));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'sk7', pg_temp.c1('bill_pay_skip_v1', pg_temp.bi('nf12'));
insert into _t select 'sk8', pg_temp.c1('bill_pay_skip_v1', pg_temp.bi('el10'));
reset role;
select ok((select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'skipped' from _t where k = 'sk1') and (select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'skipped' from _t where k = 'sk2')
          and (select v = '{"ok":false,"reason":"not_found"}'::jsonb from _t where k = 'sk3') and (select v = '{"ok":false,"reason":"not_found"}'::jsonb from _t where k = 'sk4')
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:netflix:2020-11'),
          'skip on a due bill: ok and skipped (twice is fine); open and settle on a skipped bill are not_found; no ledger row');
select ok((select v ->> 'ok' = 'true' from _t where k = 'sk5') and (select v = '{"ok":false,"reason":"not_payer","name":"Zz Admin"}'::jsonb from _t where k = 'sk6')
          and (select v ->> 'ok' = 'true' and v -> 'bill' ->> 'status' = 'skipped' from _t where k = 'sk7')
          and (select count(*) = 0 from public.transactions where external_ref = 'bill:netflix:2020-12'),
          'a bill someone else is paying cannot be skipped (not_payer); the payer may skip it; no ledger row');
select ok((select v ->> 'reason' = 'already_paid' and v -> 'bill' ->> 'status' = 'paid' from _t where k = 'sk8') and (select status = 'paid' from public.utility_bills where id = pg_temp.bi('el10')),
          'a paid bill cannot be skipped (already_paid)');

-- proof: the path of a paid bill, for approve_payment callers only (cleaner refused above); a bill that is not paid has no proof; an unknown id is not_found
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'pr1', jsonb_build_array(pg_temp.c1('bill_proof_v1', pg_temp.bi('el10')), pg_temp.c1('bill_proof_v1', pg_temp.bi('nf10')), pg_temp.c1('bill_proof_v1', 'e1280000-0000-4000-8000-0000000000ee'));
reset role;
select ok((select v = jsonb_build_array(jsonb_build_object('ok', true, 'path', (select v #>> '{}' from _t where k = 'p_el')), '{"ok":false,"reason":"no_proof"}'::jsonb, '{"ok":false,"reason":"not_found"}'::jsonb) from _t where k = 'pr1'),
          'bill_proof_v1: the stored path of the paid bill; no_proof for a bill that is not paid; not_found for an id that does not exist when the caller may pay (a cleaner gets not_authorized, tested above)');

-- schedule get / set as admin a2 (manage_staff). Settings now: electric ZZ-ACCT-1 / Zz Power / note "Zz {month} bill"; internet Zz Net / 0900-000-0000 / note "" / amount 1500 / remind_day = the s131 default 25 (none stored).
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'sg1', pg_temp.cs('bill_schedule_get_v1', pg_temp.id('b7'), 'internet');
insert into _t select 'sg2', pg_temp.cs('bill_schedule_get_v1', pg_temp.id('b7'), 'electric');
reset role;
select ok((select v = '{"ok":true,"kind":"internet","label":"Internet","payee_name":"Zz Net","number_label":"GCash number","number":"0900-000-0000","note":"","amount_php":1500,"remind_day":25,"amount_fixed":true}'::jsonb from _t where k = 'sg1'),
          'bill_schedule_get_v1 internet: the exact shape (GCash number label, fixed amount 1500, remind_day 25, the s131 default)');
select ok((select v = '{"ok":true,"kind":"electric","label":"Electricity (SOCOTECO II)","payee_name":"Zz Power","number_label":"Account number","number":"ZZ-ACCT-1","note":"Zz {month} bill","amount_php":null,"remind_day":25,"amount_fixed":false}'::jsonb from _t where k = 'sg2'),
          'bill_schedule_get_v1 electric: Account number label, no amount (amount_php null, amount_fixed false), the raw note with its {month} placeholder');
insert into _t select 'snap0', value from public.app_settings where key = 'bill_schedule';
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'ss0', jsonb_build_array(
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"bogus":1}'::jsonb),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"remind_day":0}'::jsonb),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"remind_day":29}'::jsonb),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"remind_day":3.5}'::jsonb),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"remind_day":"5"}'::jsonb),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"amount_php":0}'::jsonb),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"amount_php":"x"}'::jsonb),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', jsonb_build_object('note', repeat('x', 81))),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"note":5}'::jsonb),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'electric', '{"amount_php":5}'::jsonb),
  pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '[]'::jsonb));
insert into _t select 'ss1', pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"note":"zz partial","bogus":1}'::jsonb);
insert into _t select 'ss2', jsonb_build_array(pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'zzz', '{"note":"x"}'::jsonb), pg_temp.cs('bill_schedule_get_v1', pg_temp.id('b7'), 'zzz'));
reset role;
select ok((select (select jsonb_agg(e ->> 'reason') from jsonb_array_elements(v) e)
                  = '["bad_key","bad_value","bad_value","bad_value","bad_value","bad_value","bad_value","bad_value","bad_value","bad_key","bad_patch"]'::jsonb and v -> 0 ->> 'key' = 'bogus' and v -> 1 ->> 'key' = 'remind_day' and v -> 9 ->> 'key' = 'amount_php'
             from _t where k = 'ss0')
          and (select value = (select v from _t where k = 'snap0') from public.app_settings where key = 'bill_schedule'),
          'set refuses an unknown key (bad_key), remind_day 0, 29, 3.5 and "5", amount_php 0 and "x", a note of 81 characters and a number note (bad_value), amount_php on a meter bill (bad_key) and a non-object patch (bad_patch); the setting is unchanged');
select ok((select v ->> 'reason' = 'bad_key' and v ->> 'key' = 'bogus' from _t where k = 'ss1') and (select value = (select v from _t where k = 'snap0') from public.app_settings where key = 'bill_schedule'),
          'a patch with one valid and one unknown key writes nothing: the valid key is not applied either');
select ok((select v = '[{"ok":false,"reason":"bad_kind"},{"ok":false,"reason":"bad_kind"}]'::jsonb from _t where k = 'ss2'), 'an unknown bill kind is bad_kind on get and on set');
-- set: internet gets payee "  Zz New  " (trimmed), number ZZ-9, note "zz note", amount 1600, remind_day 5. The unpaid internet bills of b7 (2020-11 due, 2020-12 paying) show 1600; the paid 2020-10 (paid 1510, estimate 1500) is untouched.
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'sx1', pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"payee_name":"  Zz New  ","number":"ZZ-9","note":"zz note","amount_php":1600,"remind_day":5}'::jsonb);
insert into _t select 'sx2', pg_temp.cs('bill_schedule_get_v1', pg_temp.id('b7'), 'internet');
insert into _t select 'sx3', pg_temp.cs('bill_schedule_set_v1', pg_temp.id('b7'), 'internet', '{"note":"zz note"}'::jsonb);
reset role;
select ok((select v ->> 'ok' = 'true' and v ->> 'kind' = 'internet' and (select jsonb_agg(x order by x) from jsonb_array_elements_text(v -> 'changed') x) = '["amount_php","note","number","payee_name","remind_day"]'::jsonb from _t where k = 'sx1'),
          'set as admin: ok, kind internet, and the five changed keys are reported');
select ok((select v = '{"ok":true,"kind":"internet","label":"Internet","payee_name":"Zz New","number_label":"GCash number","number":"ZZ-9","note":"zz note","amount_php":1600,"remind_day":5,"amount_fixed":true}'::jsonb from _t where k = 'sx2'),
          'get after set: the payee is trimmed, and number, note, amount 1600 and remind_day 5 are stored');
select ok((select estimate_php = 1600 from public.utility_bills where id = pg_temp.bi('in11')) and (select estimate_php = 1600 and status = 'paying' from public.utility_bills where id = pg_temp.bi('in12'))
          and (select estimate_php = 1500 and paid_php = 1510 and status = 'paid' from public.utility_bills where id = pg_temp.bi('in10')),
          'a fixed bill not yet paid shows the new amount (due and paying rows 1600); a paid bill is untouched');
select ok((select count(*) = 1 from public.admin_audit_log a where a.entity_table = 'bill_schedule' and a.property_id = pg_temp.id('b7'))
          and (select a.action = 'update' and a.actor_user_id = pg_temp.id('a2') and a.reason like 'bill schedule internet edited:%' and a.after_state ->> 'kind' = 'internet' and jsonb_array_length(a.after_state -> 'keys') = 5
                      and (a.after_state::text || a.reason) !~ 'ZZ-9|Zz New|zz note|0900'
                 from public.admin_audit_log a where a.entity_table = 'bill_schedule' and a.property_id = pg_temp.id('b7')),
          'one audit row (who, kind, the five keys changed) and no value of the number, payee or note appears in it');
select ok((select v = '{"ok":true,"kind":"internet","changed":[]}'::jsonb from _t where k = 'sx3')
          and (select count(*) = 1 from public.admin_audit_log a where a.entity_table = 'bill_schedule' and a.property_id = pg_temp.id('b7')),
          'a patch that changes nothing is ok with changed [] and writes no audit row');

-- 7. today_bills_v1 "due": every unpaid (due or paying) row of any period, oldest period first, then the PAID rows of this Manila month; skipped rows are left out.
-- Property b3, the Manila month of today (cur) and the month before it (prev). Rows: electric cur due 1000.55; water cur paid 321.40 by Zz Admin (estimate 300); internet cur due 1500; netflix cur skipped 449;
-- electric 2020-01 due 999; netflix prev PAYING by Zz Admin (a2) 449; water 2020-02 paid (older and paid: it does not show). Expected order: electric 2020-01, netflix prev, electric cur, internet cur, water cur (paid).
-- can_pay: false for everyone without approve_payment (cleaner, laundry); for admin a2: true, true, true, true, false (the paid row); for finance a4 (not the payer of netflix prev): true, false, true, true, false.
-- Settings carry an account number and a payee number that must never appear in the payload.
select pg_temp.cfg_set('{"bills":{"electric":{"account":"ZZACCT123"},"internet":{"pay_to_number":"09990000000","pay_to_name":"ZzPayeeName"}}}'::jsonb) is not null as acct;
insert into public.utility_bills(property_id, kind, period, estimate_php, status, paid_php, paid_at, paid_by_name, proof_verdict, paying_by, paying_by_name) values
  (pg_temp.id('b3'), 'electric', to_char(public.manila_today(), 'YYYY-MM'), 1000.55, 'due', null, null, null, null, null, null),
  (pg_temp.id('b3'), 'water', to_char(public.manila_today(), 'YYYY-MM'), 300, 'paid', 321.40, now(), 'Zz Admin', 'typed', null, null),
  (pg_temp.id('b3'), 'internet', to_char(public.manila_today(), 'YYYY-MM'), 1500, 'due', null, null, null, null, null, null),
  (pg_temp.id('b3'), 'netflix', to_char(public.manila_today(), 'YYYY-MM'), 449, 'skipped', null, null, null, null, null, null),
  (pg_temp.id('b3'), 'electric', '2020-01', 999, 'due', null, null, null, null, null, null),
  (pg_temp.id('b3'), 'netflix', to_char(public.manila_today() - interval '1 month', 'YYYY-MM'), 449, 'paying', null, null, null, null, pg_temp.id('a2'), 'Zz Admin'),
  (pg_temp.id('b3'), 'water', '2020-02', 300, 'paid', 310, now(), 'Zz Admin', 'typed', null, null);
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'tb_cleaner', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'tb_b1', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b1')$$);
insert into _t select 'tb_admin', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_user(pg_temp.id('a4'));
insert into _t select 'tb_fin', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'tb_laundry', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_user(pg_temp.id('a6'));
insert into _t select 'tb_nostaff', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
select pg_temp.as_anon();
insert into _t select 'tb_anon', pg_temp.try($$select public.today_bills_v1('e1280000-0000-4000-8000-0000000000b3')$$);
reset role;
select ok((select (select jsonb_agg(e - 'id' - 'paid_at' order by o) from jsonb_array_elements(v -> 'due') with ordinality t(e, o)) = jsonb_build_array(
             jsonb_build_object('kind', 'electric', 'label', 'Electricity (SOCOTECO II)', 'period', '2020-01', 'status', 'due', 'estimate_php', 999, 'paid_php', null, 'is_estimate', true, 'due_day', 27,
                                'paying_by_name', null, 'paid_by_name', null, 'can_pay', true),
             jsonb_build_object('kind', 'netflix', 'label', 'Netflix', 'period', to_char(public.manila_today() - interval '1 month', 'YYYY-MM'), 'status', 'paying', 'estimate_php', 449, 'paid_php', null, 'is_estimate', false, 'due_day', 27,
                                'paying_by_name', 'Zz Admin', 'paid_by_name', null, 'can_pay', true),
             jsonb_build_object('kind', 'electric', 'label', 'Electricity (SOCOTECO II)', 'period', to_char(public.manila_today(), 'YYYY-MM'), 'status', 'due', 'estimate_php', 1000.55, 'paid_php', null, 'is_estimate', true, 'due_day', 27,
                                'paying_by_name', null, 'paid_by_name', null, 'can_pay', true),
             jsonb_build_object('kind', 'internet', 'label', 'Internet', 'period', to_char(public.manila_today(), 'YYYY-MM'), 'status', 'due', 'estimate_php', 1500, 'paid_php', null, 'is_estimate', false, 'due_day', 27,
                                'paying_by_name', null, 'paid_by_name', null, 'can_pay', true),
             jsonb_build_object('kind', 'water', 'label', 'Water (Gensan Water District)', 'period', to_char(public.manila_today(), 'YYYY-MM'), 'status', 'paid', 'estimate_php', 300, 'paid_php', 321.4, 'is_estimate', true, 'due_day', 27,
                                'paying_by_name', null, 'paid_by_name', 'Zz Admin', 'can_pay', false))
           and (select count(*) = 5 and count(*) filter (where e ->> 'id' is not null) = 5 and count(*) filter (where e ->> 'status' = 'paid' and e ->> 'paid_at' is not null) = 1 from jsonb_array_elements(v -> 'due') e)
           from _t where k = 'tb_admin'),
          'an admin (who can pay) sees, in the contract order, every unpaid bill (older first) then this month''s paid one, each with exactly the fourteen entry keys, can_pay true on the unpaid ones and false on the paid one; skipped and older paid rows are left out');
select ok((select (select jsonb_agg(e -> 'can_pay' order by o) from jsonb_array_elements(v -> 'due') with ordinality t(e, o)) = '[true, true, true, true, false]'::jsonb from _t where k = 'tb_admin')
          and (select (select jsonb_agg(e -> 'can_pay' order by o) from jsonb_array_elements(v -> 'due') with ordinality t(e, o)) = '[true, false, true, true, false]'::jsonb from _t where k = 'tb_fin')
          and (select v -> 'due' = '[]'::jsonb and (v ->> 'can_pay_list')::boolean is false from _t where k = 'tb_laundry')
          and (select v -> 'due' = '[]'::jsonb and (v ->> 'can_pay_list')::boolean is false from _t where k = 'tb_cleaner'),
          'can_pay: admin true for due rows and for the bill it is paying, false once paid; a finance user is false on a bill another person is paying; laundry and a cleaner get no list at all (s131: due = [], can_pay_list false)');
select ok((select v::text !~ '"(number|payee_name|note|account|account_name|pay_to_name|pay_to_number)"' and v::text !~ 'ZZACCT123|09990000000|ZzPayeeName' from _t where k = 'tb_admin')
          and (select v::text !~ '"(number|payee_name|note|account|account_name|pay_to_name|pay_to_number)"' and v::text !~ 'ZZACCT123|09990000000|ZzPayeeName' from _t where k = 'tb_cleaner'),
          'no key named number, payee_name, note or account (nor any account or payee value from the settings) is in the Today payload');
select ok((select jsonb_array_length(v -> 'due') = 5 from _t where k = 'tb_fin') and (select jsonb_array_length(v -> 'due') = 0 from _t where k = 'tb_laundry'), 'finance sees the same five rows; laundry sees none (s131: only a role that can pay gets the list)');
-- b1 has no row in the current month; its March rows are all paid; April electric is due and April internet is paying; May has four rows, all due (set up in section 5)
select ok((select (select jsonb_agg(jsonb_build_object('k', e ->> 'kind', 'p', e ->> 'period', 's', e ->> 'status') order by o) from jsonb_array_elements(v -> 'due') with ordinality t(e, o))
                  = '[{"k":"electric","p":"2020-04","s":"due"},{"k":"internet","p":"2020-04","s":"paying"},{"k":"electric","p":"2020-05","s":"due"},{"k":"water","p":"2020-05","s":"due"},{"k":"internet","p":"2020-05","s":"due"},{"k":"netflix","p":"2020-05","s":"due"}]'::jsonb
                  and v ?& array['due', 'electric', 'last_reading_at', 'since', 'water'] and (select count(*) = 10 from jsonb_object_keys(v)) from _t where k = 'tb_b1'),
          'a property with no bill row this month still lists its unpaid bills of earlier months (paid and skipped ones do not show), oldest first (read as an admin), and the four lane A keys are all still there among the ten keys of the s131 body');
select ok((select v ->> 'err' = '42501' from _t where k = 'tb_nostaff') and (select v ->> 'err' = '42501' from _t where k = 'tb_anon'), 'a user with no staff profile and anon are still refused (42501)');
select pg_temp.cfg_set(pg_temp.cfg_default()) is not null as reset4;

-- 8. the daily job. Property b9, default settings (reading day 21, pay day 27), floor 2026-11. Dates are fixed.
-- 10 Nov 2026: not the reading day; the previous month (2026-10) is before the floor, so NOTHING opens (October stays closed): {on, bills_opened 0, notices_written 0}, no bill row, no notice.
-- 21 Dec 2026: the reading day: one meter notice; before the 27th the previous month 2026-11 opens four bills (floor ok), four notices: 5 written.
-- the same day again: nothing new. 22 Dec: the four unpaid notices are dated 22 Dec (the meter-reading notice stays on 21 Dec); 5 notices in all.
-- Internet is paid and netflix skipped (their notices close); on 23 Dec only electric and water are re-dated. 27 Dec opens December: four more bills and notices.
insert into _t select 'dj0', public.bill_daily_v1(date '2026-11-10', pg_temp.id('b9'));
select ok((select v = '{"on":"2026-11-10","bills_opened":0,"notices_written":0}'::jsonb from _t where k = 'dj0')
          and (select count(*) = 0 from public.utility_bills where property_id = pg_temp.id('b9')) and (select count(*) = 0 from public.ops_notices where property_id = pg_temp.id('b9')),
          'before the floor: a run on 10 Nov 2026 opens nothing (October 2026 stays closed) and writes no notice');
insert into _t select 'dj1', public.bill_daily_v1(date '2026-12-21', pg_temp.id('b9'));
select ok((select v = '{"on":"2026-12-21","bills_opened":4,"notices_written":5}'::jsonb from _t where k = 'dj1')
          and (select count(*) = 4 and min(period) = '2026-11' and max(period) = '2026-11' and count(distinct notice_id) = 4 and count(notice_id) = 4 from public.utility_bills where property_id = pg_temp.id('b9')),
          'the reading day: four bills open for 2026-11 (the previous month, above the floor), each linked to its own notice, five notices written in all');
select ok((select array_agg(title order by title) = array['Electricity (SOCOTECO II) is overdue.', 'Internet is overdue.', 'Meter reading due today (21st)', 'Netflix is overdue.', 'Water (Gensan Water District) is overdue.']
                  and bool_and(notice_type = 'reminder' and source = 'system' and audience = 'staff' and is_active and effective_date = date '2026-12-21')
                  and bool_and(title !~ '[0-9]{3}' and title !~ '₱')
                  and bool_and(description = case when title like 'Meter reading%' then 'Read the electricity and water meters.' else '' end)
             from public.ops_notices where property_id = pg_temp.id('b9')),
          'the five notices: the exact titles (a bill of an earlier month reads is overdue; no amount in any), type reminder, source system, audience staff, dated 21 Dec 2026, the exact descriptions (s131: a bill notice has none, no pointer to a To pay list)');
insert into _t select 'dj2', public.bill_daily_v1(date '2026-12-21', pg_temp.id('b9'));
select ok((select v = '{"on":"2026-12-21","bills_opened":0,"notices_written":0}'::jsonb from _t where k = 'dj2') and (select count(*) = 5 from public.ops_notices where property_id = pg_temp.id('b9'))
          and (select count(*) = 4 from public.utility_bills where property_id = pg_temp.id('b9')),
          'the job twice in one day writes one notice per bill and one meter notice: the second run writes nothing');
insert into _t select 'dj3', public.bill_daily_v1(date '2026-12-22', pg_temp.id('b9'));
select ok((select v = '{"on":"2026-12-22","bills_opened":0,"notices_written":0}'::jsonb from _t where k = 'dj3') and (select count(*) = 5 from public.ops_notices where property_id = pg_temp.id('b9'))
          and (select count(*) = 4 and bool_and(title like '% is overdue.') from public.ops_notices where property_id = pg_temp.id('b9') and effective_date = date '2026-12-22')
          and (select count(*) = 1 and bool_and(title like 'Meter reading%') from public.ops_notices where property_id = pg_temp.id('b9') and effective_date = date '2026-12-21'),
          'the next day: no new notice; the four unpaid bills keep their one notice, re-dated to 22 Dec so they stay on Today; the meter notice stays on its day');
-- pay internet through the core (finance a4) and skip netflix: their notices close
insert into _t select 'dj4a', pg_temp.fin(pg_temp.bid('internet', 'b9', '2026-11'), 'pay');
insert into _t select 'dj4b', pg_temp.fin(pg_temp.bid('internet', 'b9', '2026-11'), 'paid', pg_temp.rp(1500));
insert into _t select 'dj4c', pg_temp.fin(pg_temp.bid('netflix', 'b9', '2026-11'), 'skip');
insert into _t select 'dj5', public.bill_daily_v1(date '2026-12-23', pg_temp.id('b9'));
select ok((select v ->> 'ok' = 'true' from _t where k = 'dj4b') and (select v ->> 'ok' = 'true' from _t where k = 'dj4c')
          and (select count(*) = 2 and bool_and(not is_active) and bool_and(effective_date = date '2026-12-22' and (title like 'Internet%' or title like 'Netflix%')) from public.ops_notices n
                where n.id in (select notice_id from public.utility_bills where property_id = pg_temp.id('b9') and kind in ('internet', 'netflix')))
          and (select count(*) = 2 and bool_and(is_active and effective_date = date '2026-12-23' and (title like 'Electricity%' or title like 'Water%')) from public.ops_notices n
                where n.id in (select notice_id from public.utility_bills where property_id = pg_temp.id('b9') and kind in ('electric', 'water'))),
          'a paid or skipped bill closes its notice (inactive, no longer re-dated); only the unpaid electric and water notices move to 23 Dec');
insert into _t select 'dj6', public.bill_daily_v1(date '2026-12-27', pg_temp.id('b9'));
select ok((select v = '{"on":"2026-12-27","bills_opened":4,"notices_written":4}'::jsonb from _t where k = 'dj6')
          and (select count(*) = 4 and min(period) = '2026-12' and count(distinct notice_id) = 4 from public.utility_bills where property_id = pg_temp.id('b9') and period = '2026-12')
          and (select count(*) = 9 from public.ops_notices where property_id = pg_temp.id('b9'))
          and (select count(*) = 4 and bool_and(title like '% bill: due by the 27th.' and effective_date = date '2026-12-27') from public.ops_notices n
                where n.id in (select notice_id from public.utility_bills where property_id = pg_temp.id('b9') and period = '2026-12')),
          'the 27th opens December: four more bills with four new notices (nine in all) that read "<Label> bill: due by the 27th." (s131); one notice per bill per period');
-- 8b. staff_pay_admin_settle_v1 refuses a screenshot that already paid a bill (the reverse of the bill duplicate check). The real Cascade property, admin a2.
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S128 Cascade stand-in', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) values (pg_temp.id('a2'), '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd') on conflict do nothing;
insert into public.staff_pay_requests(id, property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount, paying_by_user_id, paying_by_name, paying_at) values
  (pg_temp.id('d1'), '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', pg_temp.id('a1'), 'Zz Cleaner', 'zz128-rev-0001', 'paying', '[{"kind":"advance","amount":500,"checkout_date":"2020-01-05"}]'::jsonb, 500, pg_temp.id('a2'), 'Zz Admin', now());
insert into public.utility_bills(property_id, kind, period, estimate_php) values (pg_temp.id('b2'), 'netflix', '2021-09', 449);
insert into _t select 'rv0', pg_temp.adm(pg_temp.bid('netflix', 'b2', '2021-09'), 'paid', jsonb_build_object('file_unique_id', 'zz128-rev-u', 'file_id', 'zz128-rev-f', 'sha256', repeat('f', 64), 'amount', 449, 'reference', 'ZZREVBILL1', 'read', jsonb_build_object('amount', 449), 'verdict', 'read'));
insert into storage.objects(bucket_id, name) values ('cleaning-photos', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/' || pg_temp.id('a2')::text || '/zz-reverse-duplicate-0001.jpg');
insert into public.staff_upload_hashes(path, sha256) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/' || pg_temp.id('a2')::text || '/zz-reverse-duplicate-0001.jpg', repeat('f', 64));
insert into storage.objects(bucket_id, name) values ('cleaning-photos', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/' || pg_temp.id('a2')::text || '/zz-reverse-fresh-000002.jpg');
insert into public.staff_upload_hashes(path, sha256) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/' || pg_temp.id('a2')::text || '/zz-reverse-fresh-000002.jpg', repeat('9', 64));
insert into _t select 'rv_txn0', to_jsonb(count(*)) from public.transactions;
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'rv1', pg_temp.c2('staff_pay_admin_settle_v1', pg_temp.id('d1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/' || pg_temp.id('a2')::text || '/zz-reverse-duplicate-0001.jpg', 'sha256', repeat('f', 64), 'reference', 'ZZREV0001', 'amount', 500));
reset role;
insert into _t select 'rv1n', to_jsonb((select count(*) from public.transactions));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'rv2', pg_temp.c2('staff_pay_admin_settle_v1', pg_temp.id('d1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/' || pg_temp.id('a2')::text || '/zz-reverse-fresh-000002.jpg', 'sha256', repeat('9', 64), 'reference', 'ZZREV0002', 'amount', 500));
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'duplicate_proof' and v ->> 'other_ref' = (select ref from public.utility_bills where id = pg_temp.bid('netflix', 'b2', '2021-09'))
                  and v ->> 'ref' = (select ref from public.staff_pay_requests where id = pg_temp.id('d1')) from _t where k = 'rv1')
          and (select v ->> 'ok' = 'true' from _t where k = 'rv0')
          and (select (a.v #>> '{}')::int = (b.v #>> '{}')::int from _t a, _t b where a.k = 'rv_txn0' and b.k = 'rv1n'),
          'a screenshot that already paid a bill cannot settle a staff payment: duplicate_proof naming the bill and the request, and no transaction is written');
select ok((select v ->> 'ok' = 'true' from _t where k = 'rv2')
          and (select status = 'paid' and proof_sha256 = repeat('9', 64) from public.staff_pay_requests where id = pg_temp.id('d1'))
          and (select (a.v #>> '{}')::int + 1 = (select count(*) from public.transactions) from _t a where a.k = 'rv_txn0'),
          'the same request with a fresh screenshot settles: paid, its own sha256 stored, exactly one new transaction');

-- 8c. a job that raises for one property does not stop the others, and an inactive property gets nothing. Only b9 (fine), ba (its notice insert raises) and b8 (inactive) are active or tested: every other property is switched off here.
create temp table _act as select id, is_active from public.properties;
update public.properties set is_active = (id in (pg_temp.id('b9'), pg_temp.id('ba')));
create function public.zz128_boom() returns trigger language plpgsql as $f$
begin
  if new.property_id = 'e1280000-0000-4000-8000-0000000000ba' then raise exception 'zz128 boom'; end if;
  return new;
end $f$;
create trigger zz128_boom before insert on public.ops_notices for each row execute function public.zz128_boom();
insert into _t select 'nj1', public.bill_daily_v1(date '2027-03-27', null);
select ok((select v = '{"on":"2027-03-27","bills_opened":4,"notices_written":4}'::jsonb from _t where k = 'nj1')
          and (select count(*) = 4 from public.utility_bills where property_id = pg_temp.id('b9') and period = '2027-03')
          and (select count(*) = 4 and bool_and(n.title like '% bill: due by the 27th.') from public.ops_notices n where n.id in (select notice_id from public.utility_bills where property_id = pg_temp.id('b9') and period = '2027-03')),
          'the job on 27 Mar 2027 opens four bills and writes four notices for the property that works (the totals count only what was kept)');
select ok((select count(*) = 0 from public.utility_bills where property_id = pg_temp.id('ba')) and (select count(*) = 0 from public.ops_notices where property_id = pg_temp.id('ba')),
          'the property whose notice insert raised keeps no bill and no notice (its work was rolled back) and the job still finished');
select ok((select count(*) = 0 from public.utility_bills where property_id = pg_temp.id('b8')) and (select count(*) = 0 from public.ops_notices where property_id = pg_temp.id('b8')),
          'an inactive property gets no bills and no notices');
drop trigger zz128_boom on public.ops_notices;
update public.properties p set is_active = x.is_active from _act x where x.id = p.id;

-- 8d. no account number, GCash number, payee name, note or account key in any reply of settle, cancel, skip, proof (the settings of section 6b carried ZZ-ACCT-1 / Zz Power / 0900-000-0000 / Zz Net)
select ok((select count(*) = 16 and bool_and(v::text !~ '"(number|payee_name|note|account|account_name|pay_to_name|pay_to_number)"' and v::text !~ 'ZZ-ACCT-1|Zz Power|0900-000-0000|Zz Net|Zz [{]month[}] bill')
             from _t where k in ('st1', 'st3', 'st4', 'st5', 'du1', 'du2', 'si1', 'ca2', 'ca3', 'sk1', 'sk2', 'sk4', 'sk6', 'sk7', 'sk8', 'pr1')),
          'no key named number, payee_name, note or account (nor any account or payee value from the settings) in the stored replies of settle, cancel, skip and proof');

-- the internal functions refuse every API role (called as those roles) and utility_bills is unreadable
select pg_temp.as_anon();
insert into _t select 'ia', jsonb_build_array(
  pg_temp.try($$select public.bill_step_v1('e1280000-0000-4000-8000-0000000000ff'::uuid, 'pay', 'e1280000-0000-4000-8000-0000000000a2'::uuid, 'x')$$),
  pg_temp.try($$select public.bill_due_open_v1('e1280000-0000-4000-8000-0000000000b9'::uuid, date '2026-12-27')$$), pg_temp.try($$select public.bill_daily_v1()$$),
  pg_temp.try($$select public.bill_schedule_cfg_v1()$$), pg_temp.try($$select to_jsonb(count(*)) from public.utility_bills$$));
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'ib', jsonb_build_array(
  pg_temp.try($$select public.bill_step_v1('e1280000-0000-4000-8000-0000000000ff'::uuid, 'pay', 'e1280000-0000-4000-8000-0000000000a2'::uuid, 'x')$$),
  pg_temp.try($$select public.bill_due_open_v1('e1280000-0000-4000-8000-0000000000b9'::uuid, date '2026-12-27')$$), pg_temp.try($$select public.bill_daily_v1()$$),
  pg_temp.try($$select public.bill_schedule_cfg_v1()$$), pg_temp.try($$select to_jsonb(count(*)) from public.utility_bills$$));
select pg_temp.as_service();
insert into _t select 'ic', jsonb_build_array(
  pg_temp.try($$select public.bill_step_v1('e1280000-0000-4000-8000-0000000000ff'::uuid, 'pay', 'e1280000-0000-4000-8000-0000000000a2'::uuid, 'x')$$),
  pg_temp.try($$select public.bill_due_open_v1('e1280000-0000-4000-8000-0000000000b9'::uuid, date '2026-12-27')$$), pg_temp.try($$select public.bill_daily_v1()$$),
  pg_temp.try($$select public.bill_schedule_cfg_v1()$$));
reset role;
select ok((select bool_and(e ->> 'err' = '42501') and count(*) = 5 from _t, jsonb_array_elements(v) e where k = 'ia')
          and (select bool_and(e ->> 'err' = '42501') and count(*) = 5 from _t, jsonb_array_elements(v) e where k = 'ib')
          and (select bool_and(e ->> 'err' = '42501') and count(*) = 4 from _t, jsonb_array_elements(v) e where k = 'ic'),
          'anon, a signed-in admin and service_role cannot call the step core, the opener, the daily job or the config helper (permission denied, called as those roles); anon and admin cannot read utility_bills');
select ok(to_regclass('cron.job') is null or (xpath('/row/c/text()', query_to_xml('select count(*) as c from cron.job where jobname = ''bill-daily-0800-manila'' and schedule = ''0 0 * * *'' and command = ''select public.bill_daily_v1()''', false, true, '')))[1]::text::int = 1,
          'the daily job is scheduled at 00:00 UTC (08:00 Manila) calling bill_daily_v1() (skipped where pg_cron is absent)');

-- 9. notices_v1: an ops_notices row of type reminder (what the daily job writes) reaches every role on Today as type note. Dated today, audience staff.
insert into public.ops_notices(property_id, notice_type, title, description, effective_date, source, audience) values
  (pg_temp.id('b1'), 'reminder', 'Zz meter reading', 'Please send today''s electricity and water reading.', public.manila_today(), 'system', 'staff');
select pg_temp.as_user(pg_temp.id('a1'));
insert into _t select 'nt_cleaner', pg_temp.try($$select public.notices_v1('e1280000-0000-4000-8000-0000000000b1')$$);
select pg_temp.as_user(pg_temp.id('a3'));
insert into _t select 'nt_laundry', pg_temp.try($$select public.notices_v1('e1280000-0000-4000-8000-0000000000b1')$$);
select pg_temp.as_user(pg_temp.id('a2'));
insert into _t select 'nt_admin', pg_temp.try($$select public.notices_v1('e1280000-0000-4000-8000-0000000000b1')$$);
select pg_temp.as_user(pg_temp.id('a6'));
insert into _t select 'nt_nostaff', pg_temp.try($$select public.notices_v1('e1280000-0000-4000-8000-0000000000b1')$$);
reset role;
select ok((select count(*) = 1 from _t, jsonb_array_elements(v -> 'notices') e where k = 'nt_cleaner' and e ->> 'title' = 'Zz meter reading' and e ->> 'type' = 'note'), 'notices_v1 returns the system reminder to a cleaner (type note)');
select ok((select count(*) = 1 from _t, jsonb_array_elements(v -> 'notices') e where k = 'nt_laundry' and e ->> 'title' = 'Zz meter reading' and e ->> 'type' = 'note'), 'notices_v1 returns the system reminder to laundry');
select ok((select count(*) = 1 from _t, jsonb_array_elements(v -> 'notices') e where k = 'nt_admin' and e ->> 'title' = 'Zz meter reading' and e ->> 'type' = 'note'), 'notices_v1 returns the system reminder to an admin');
select ok((select v ->> 'err' = '42501' from _t where k = 'nt_nostaff'), 'a user with no staff profile gets no notices (42501)');

select * from finish();
rollback;
