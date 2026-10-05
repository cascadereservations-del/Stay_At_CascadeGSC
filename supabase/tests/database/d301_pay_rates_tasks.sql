-- Session 72, lane L4 (D-301): pay rates (append-only, effective-dated, owner/admin) and the one task list.
-- Synthetic property and users (e8400000-...), plus the production property id only for the rate-in-force-by-date reads (the rows
-- are inserted guarded, as staff_pay_requests.sql does). Everything is inside begin/rollback; the roles are impersonated with
-- request.jwt.claims. Fixtures insert as the owner role.
begin;
select plan(98);

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true),
         set_config('role', 'authenticated', true)
$$;
grant execute on function pg_temp.as_user(uuid) to public;
-- The rehearsal restore is --no-acl; the audit read below needs a grant that production has.
grant select on public.admin_audit_log to authenticated;

-- structure ------------------------------------------------------------------------------------------------------------------
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""'])
             from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('admin_pay_rates_v1','admin_add_pay_rate_v1','tasks_rows_v1','tasks_list_v1','task_set_done_v1','task_add_reminder_v1','task_assignees_v1')),
  'every new RPC is security definer with an empty search_path');
select ok(not has_function_privilege('anon', 'public.admin_pay_rates_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.admin_add_pay_rate_v1(uuid,date,numeric,numeric,numeric,text)', 'execute')
      and not has_function_privilege('anon', 'public.tasks_list_v1(uuid,boolean)', 'execute')
      and not has_function_privilege('anon', 'public.task_set_done_v1(uuid,text,uuid,boolean,text)', 'execute')
      and not has_function_privilege('anon', 'public.task_add_reminder_v1(uuid,text,timestamptz,uuid,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.task_assignees_v1(uuid)', 'execute'),
  'anon can call none of them');
select ok(has_function_privilege('authenticated', 'public.admin_pay_rates_v1(uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.admin_add_pay_rate_v1(uuid,date,numeric,numeric,numeric,text)', 'execute')
      and has_function_privilege('authenticated', 'public.tasks_list_v1(uuid,boolean)', 'execute')
      and has_function_privilege('authenticated', 'public.task_set_done_v1(uuid,text,uuid,boolean,text)', 'execute')
      and has_function_privilege('authenticated', 'public.task_add_reminder_v1(uuid,text,timestamptz,uuid,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.task_assignees_v1(uuid)', 'execute'),
  'authenticated can call the six public ones');
select ok(not has_function_privilege('authenticated', 'public.tasks_rows_v1(uuid,uuid,boolean,boolean)', 'execute')
      and not has_function_privilege('anon', 'public.tasks_rows_v1(uuid,uuid,boolean,boolean)', 'execute')
      and not has_function_privilege('service_role', 'public.tasks_rows_v1(uuid,uuid,boolean,boolean)', 'execute'),
  'the internal row function is callable by no API role');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                         and p.proname in ('admin_pay_rates_v1','admin_add_pay_rate_v1','tasks_rows_v1','tasks_list_v1','task_set_done_v1','task_add_reminder_v1','task_assignees_v1')),
  'PUBLIC has no execute grant on any of them');
select is((select count(*)::int from pg_trigger where tgrelid = 'public.cleaner_rate_schedule'::regclass and not tgisinternal
            and tgname in ('cleaner_rate_schedule_append_only', 'admin_audit_row')), 2,
  'the rate table has the append-only and audit triggers');

-- Fixtures -----------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e8400000-0000-4000-8000-0000000000b0', 'Synthetic D301', true);
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into auth.users(id) values ('e8400000-0000-4000-8000-0000000000a1'), ('e8400000-0000-4000-8000-0000000000a2'), ('e8400000-0000-4000-8000-0000000000a3'),
  ('e8400000-0000-4000-8000-0000000000a4'), ('e8400000-0000-4000-8000-0000000000a5'), ('e8400000-0000-4000-8000-0000000000a6'), ('e8400000-0000-4000-8000-0000000000a7');
-- a1 owner, a2 admin, a3 cleaner C, a4 cleaner D, a5 maintenance, a6 finance, a7 cleaner with no property access
insert into public.staff_access_profiles(user_id, role) values
  ('e8400000-0000-4000-8000-0000000000a1', 'owner'), ('e8400000-0000-4000-8000-0000000000a2', 'admin'), ('e8400000-0000-4000-8000-0000000000a3', 'cleaner'),
  ('e8400000-0000-4000-8000-0000000000a4', 'cleaner'), ('e8400000-0000-4000-8000-0000000000a5', 'maintenance'), ('e8400000-0000-4000-8000-0000000000a6', 'finance'),
  ('e8400000-0000-4000-8000-0000000000a7', 'cleaner');
insert into public.staff_property_access(user_id, property_id)
select u, p from (values ('e8400000-0000-4000-8000-0000000000a2'::uuid), ('e8400000-0000-4000-8000-0000000000a3'), ('e8400000-0000-4000-8000-0000000000a4'),
                         ('e8400000-0000-4000-8000-0000000000a5'), ('e8400000-0000-4000-8000-0000000000a6')) x(u),
     (values ('e8400000-0000-4000-8000-0000000000b0'::uuid), ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)) y(p);

-- The production-property rates (guarded: a restored backup already has the same four rows).
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-01-02', 500, 1000, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-01-02');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-05-07', 650, 1000, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-05-07');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');
-- The synthetic property starts with one old rate row.
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
values ('e8400000-0000-4000-8000-0000000000b0', date '2026-01-01', 400, 800, 'zz synthetic start');

-- the rate in force by date (the payment-request RPCs read it through staff_pay_rate_v1) ---------------------------------------
select ok((select regular = 500 and general = 1000 and transport is null from public.staff_pay_rate_v1(date '2026-04-01')), 'on 2026-04-01 the rate in force is 500 / 1000, no transport');
select ok((select regular = 650 and general = 1000 and transport is null from public.staff_pay_rate_v1(date '2026-06-01')), 'on 2026-06-01 it is the 650 era with no transport toggle');
select ok((select regular = 500 and general = 1000 and transport = 150 from public.staff_pay_rate_v1(date '2026-10-01')), 'on 2026-10-01 it is 500 / 1000 with a 150 transport');
select ok((select regular = 650 from public.staff_pay_rate_v1(date '2026-09-29')), 'the day before a new row starts the old rate still applies');

-- who can read the rates -----------------------------------------------------------------------------------------------------
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a1');
insert into _t select 'rates_owner', public.admin_pay_rates_v1('e8400000-0000-4000-8000-0000000000b0');
reset role;
select ok((select (v->>'ok')::boolean and (v->'in_force'->>'regular_rate')::numeric = 400 and jsonb_array_length(v->'history') = 1 and v->'next' = 'null'::jsonb from _t where k = 'rates_owner'),
  'the owner reads the rate in force (400) and a one-row history, with no next rate');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a2');
select lives_ok($$select public.admin_pay_rates_v1('e8400000-0000-4000-8000-0000000000b0')$$, 'an admin can read the rates');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a3');
select throws_ok($$select public.admin_pay_rates_v1('e8400000-0000-4000-8000-0000000000b0')$$, '42501', 'manage_staff denied', 'a cleaner cannot read the rates');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a6');
select throws_ok($$select public.admin_pay_rates_v1('e8400000-0000-4000-8000-0000000000b0')$$, '42501', 'manage_staff denied', 'finance cannot read the rates (owner/admin only)');
reset role;

-- adding a rate ----------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a3');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 1, 600, 1100, 150, 'cleaner tries')$$, '42501', 'manage_staff denied', 'a cleaner cannot add a rate');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a6');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 1, 600, 1100, 150, 'finance tries')$$, '42501', 'manage_staff denied', 'finance cannot add a rate');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a2');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', date '2026-01-01', 600, 1100, 150, 'same day as the old row')$$, '22023', 'a rate already starts on that date; history is never changed, pick a later date', 'a date that already has a rate is refused');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', date '2025-12-31', 600, 1100, 150, 'before the latest')$$, '22023', null, 'a date before the latest rate is refused');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 1, 0, 1100, 150, 'zero fee')$$, '22023', 'the cleaning fee must be between 1 and 10,000', 'a zero cleaning fee is refused');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 1, 600, 10001, 150, 'huge fee')$$, '22023', 'the deep clean fee must be between 1 and 10,000', 'a deep clean fee over 10,000 is refused');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 1, 600, 1100, -5, 'negative transport')$$, '22023', null, 'a negative transport fee is refused');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 1, 600, 1100, 150, 'ab')$$, '22023', 'a note of 3 to 500 characters is required', 'a note shorter than 3 characters is refused');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', null, 600, 1100, 150, 'no date')$$, '22023', 'a start date is required', 'a missing start date is refused');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 400, 600, 1100, 150, 'too far')$$, '22023', 'the start date is more than a year away', 'a start date more than a year away is refused');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 1, 600.555, 1100, 150, 'three decimals')$$, '22023', null, 'a fee with more than 2 decimals is refused');
select throws_ok($$select public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000ff', current_date + 1, 600, 1100, 150, 'unknown property')$$, 'P0002', 'property not found', 'an unknown property is refused');
reset role;
select is((select count(*)::int from public.cleaner_rate_schedule where property_id = 'e8400000-0000-4000-8000-0000000000b0'), 1, 'every refused call left the history at one row');

select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a2');
insert into _t select 'add1', public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 10, 520, 1050, 160, 'Honey agreed a raise');
insert into _t select 'add_replay', public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 10, 520, 1050, 160, 'Honey agreed a raise');
insert into _t select 'add_notransport', public.admin_add_pay_rate_v1('e8400000-0000-4000-8000-0000000000b0', current_date + 20, 700, 1200, 0, 'Fee now includes transport');
insert into _t select 'rates_after', public.admin_pay_rates_v1('e8400000-0000-4000-8000-0000000000b0');
reset role;
select ok((select (v->>'ok')::boolean and (v->>'replayed')::boolean = false and (v->>'regular_rate')::numeric = 520 and (v->>'transport_rate')::numeric = 160 from _t where k = 'add1'), 'an admin adds a future-dated rate');
select ok((select (v->>'replayed')::boolean and v->>'id' = (select v->>'id' from _t where k = 'add1') from _t where k = 'add_replay'), 'the same numbers on the same date are a replay, not a second row');
select is((select transport_rate from public.cleaner_rate_schedule where id = (select (v->>'id')::uuid from _t where k = 'add_notransport')), null::numeric, 'a transport of 0 is stored as null (the fee already includes transport)');
select is((select jsonb_array_length(v->'history') from _t where k = 'rates_after'), 3, 'the history now lists three rows');
select ok((select (v->'in_force'->>'regular_rate')::numeric = 400 and (v->'next'->>'regular_rate')::numeric = 520 from _t where k = 'rates_after'),
  'the rate in force today is still the old one; the next rate is the one starting in 10 days');
select is((select regular_rate from public.cleaner_rate_schedule where property_id = 'e8400000-0000-4000-8000-0000000000b0' and effective_from = date '2026-01-01'), 400::numeric, 'adding rates never changed the old row');
select ok((select count(*) = 1 from public.admin_audit_log where entity_table = 'cleaner_rate_schedule' and entity_id = (select (v->>'id')::uuid from _t where k = 'add1')
            and action = 'insert' and reason = 'Honey agreed a raise' and actor_user_id = 'e8400000-0000-4000-8000-0000000000a2'),
  'the new rate is in the audit log with its reason and the admin as actor');

-- Rate in force by date on the production property after an owner adds one: a payment request reads this row (staff_pay_rate_v1).
insert into _t select 'prod_date', to_jsonb((select greatest(max(effective_from), current_date) + 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'));
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a1');
insert into _t select 'add_prod', public.admin_add_pay_rate_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', (select (v #>> '{}')::date from _t where k = 'prod_date'), 540, 1040, 170, 'zz owner adds a rate');
reset role;
select ok((select regular = 540 and general = 1040 and transport = 170 from public.staff_pay_rate_v1((select (v #>> '{}')::date from _t where k = 'prod_date'))), 'a payment request on or after the new date reads the new rate');
select ok((select regular = 500 and general = 1000 and transport = 150 from public.staff_pay_rate_v1(date '2026-10-01')), 'a clean dated before the new rate still reads the old one');

-- append-only -------------------------------------------------------------------------------------------------------------------
select throws_ok($$update public.cleaner_rate_schedule set regular_rate = 1 where property_id = 'e8400000-0000-4000-8000-0000000000b0'$$, '55000', null, 'a rate row cannot be updated, even by the table owner');
select throws_ok($$delete from public.cleaner_rate_schedule where property_id = 'e8400000-0000-4000-8000-0000000000b0'$$, '55000', null, 'a rate row cannot be deleted');

-- Tasks: fixtures --------------------------------------------------------------------------------------------------------------------
insert into public.guests(id, property_id, name) values ('e8400000-0000-4000-8000-0000000000c1', 'e8400000-0000-4000-8000-0000000000b0', 'Zz Synthetic Guest');
insert into public.follow_up_tasks(id, property_id, guest_id, purpose, title, detail, assignee_user_id, status, source_kind, idempotency_key, completed_at, updated_at) values
  ('e8400000-0000-4000-8000-0000000000f1', 'e8400000-0000-4000-8000-0000000000b0', null, 'other', 'Buy trash bags', 'Ask for PHP 4,550 receipt and the 2,800 pesos change', null, 'open', 'manual', null, null, now()),
  ('e8400000-0000-4000-8000-0000000000f2', 'e8400000-0000-4000-8000-0000000000b0', null, 'other', 'Check gate latch', null, 'e8400000-0000-4000-8000-0000000000a4', 'open', 'manual', null, null, now()),
  ('e8400000-0000-4000-8000-0000000000f3', 'e8400000-0000-4000-8000-0000000000b0', null, 'other', 'Water plants P1,500 ring 0917 123 4567', 'mail x@y.org', 'e8400000-0000-4000-8000-0000000000a3', 'open', 'manual', null, null, now()),
  ('e8400000-0000-4000-8000-0000000000f4', 'e8400000-0000-4000-8000-0000000000b0', 'e8400000-0000-4000-8000-0000000000c1', 'post_stay_follow_up', 'Guest wants a late checkout', null, null, 'open', null, null, null, now()),
  ('e8400000-0000-4000-8000-0000000000f5', 'e8400000-0000-4000-8000-0000000000b0', null, 'other', 'Cleaning report missing', null, null, 'open', 'missed_cleaning', 'system:missed_cleaning:zz-l4-1', null, now()),
  ('e8400000-0000-4000-8000-0000000000f6', 'e8400000-0000-4000-8000-0000000000b0', null, 'other', 'Done two days ago', null, null, 'done', 'manual', null, now() - interval '2 days', now() - interval '2 days'),
  ('e8400000-0000-4000-8000-0000000000f7', 'e8400000-0000-4000-8000-0000000000b0', null, 'other', 'Done long ago', null, null, 'done', 'manual', null, now() - interval '30 days', now() - interval '30 days'),
  ('e8400000-0000-4000-8000-0000000000f8', 'e8400000-0000-4000-8000-0000000000b0', null, 'other', 'Cancelled reminder', null, null, 'cancelled', 'manual', null, null, now());
insert into public.work_orders(id, property_id, source_kind, title, description, assignee_user_id, status, resolved_at, updated_at) values
  ('e8400000-0000-4000-8000-0000000000e1', 'e8400000-0000-4000-8000-0000000000b0', 'cleaning_issue', 'Leaking tap in the bathroom', 'cleaner note', null, 'open', null, now()),
  ('e8400000-0000-4000-8000-0000000000e2', 'e8400000-0000-4000-8000-0000000000b0', 'guest_report', 'Guest reported a stain', null, null, 'open', null, now()),
  ('e8400000-0000-4000-8000-0000000000e3', 'e8400000-0000-4000-8000-0000000000b0', 'manual', 'Repaint the fence', null, 'e8400000-0000-4000-8000-0000000000a4', 'in_progress', null, now()),
  ('e8400000-0000-4000-8000-0000000000e4', 'e8400000-0000-4000-8000-0000000000b0', 'cleaning_issue', 'Resolved scratch', null, null, 'resolved', now() - interval '1 day', now() - interval '1 day'),
  ('e8400000-0000-4000-8000-0000000000e5', 'e8400000-0000-4000-8000-0000000000b0', 'manual', 'Cancelled work', null, null, 'cancelled', null, now());
insert into public.verifier_findings(key, check_id, severity, title, status, acknowledged_at) values
  ('zz-l4-v1', 'V99', 'red', 'Zz open finding', 'open', null),
  ('zz-l4-v2', 'V99', 'yellow', 'Zz acknowledged finding', 'acknowledged', now());

-- the manager's view ------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a1');
insert into _t select 'own_open', public.tasks_list_v1('e8400000-0000-4000-8000-0000000000b0');
insert into _t select 'own_all', public.tasks_list_v1('e8400000-0000-4000-8000-0000000000b0', true);
reset role;
select ok((select (v->>'ok')::boolean and (v->>'manager')::boolean from _t where k = 'own_open'), 'the owner gets the manager view');
select is((select count(*)::int from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open' and t->>'source' <> 'verifier_findings'), 8,
  'the owner sees all 8 open follow-ups and work orders, not the done, old or cancelled ones');
select ok((select bool_or(t->>'title' = 'Buy trash bags') and bool_or(t->>'title' = 'Guest wants a late checkout') and bool_or(t->>'title' = 'Guest reported a stain') and bool_or(t->>'title' = 'Cleaning report missing')
            from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open'), 'the owner sees reminders, guest follow-ups, guest reports and system tasks');
select ok((select bool_or(t->>'kind' = 'reminder') and bool_or(t->>'kind' = 'guest_follow_up') and bool_or(t->>'kind' = 'system') and bool_or(t->>'kind' = 'cleaning_issue')
            and bool_or(t->>'kind' = 'guest_report') and bool_or(t->>'kind' = 'work_order') from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open'),
  'every kind is labelled: reminder, guest_follow_up, system, cleaning_issue, guest_report, work_order');
select ok((select count(*) = 1 from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open' and t->>'source' = 'verifier_findings' and t->>'title' = 'Zz open finding' and t->>'priority' = 'high'),
  'the owner sees an open verifier finding as a high-priority task');
select ok((select not bool_or(t->>'title' in ('Zz acknowledged finding', 'Done two days ago', 'Resolved scratch', 'Done long ago', 'Cancelled reminder', 'Cancelled work'))
            from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open'), 'done, acknowledged and cancelled rows stay out of the open list');
select ok((select bool_or(t->>'title' = 'Water plants P1,500 ring 0917 123 4567') from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open'), 'the owner sees the raw text');
select ok((select bool_and(t->>'status' = 'open') from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open'), 'the default list holds open tasks only');
select ok((select bool_or(t->>'title' = 'Done two days ago') and bool_or(t->>'title' = 'Resolved scratch') and bool_or(t->>'title' = 'Zz acknowledged finding') and not bool_or(t->>'title' = 'Done long ago')
            from _t, jsonb_array_elements(v->'tasks') t where k = 'own_all'), 'with done included: tasks done in the last 14 days and acknowledged findings appear, older ones do not');
select ok((select (t->>'status') = 'done' from _t, jsonb_array_elements(v->'tasks') t where k = 'own_all' and t->>'title' = 'Done two days ago'), 'a done task is marked done');
select ok((select (t->>'assignee_id') = 'e8400000-0000-4000-8000-0000000000a4' from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open' and t->>'title' = 'Check gate latch'), 'the owner sees who a task is assigned to');
select ok((select (t->>'blocks_arrival')::boolean is not null from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open' and t->>'title' = 'Leaking tap in the bathroom'), 'work orders carry blocks_arrival');
select ok((select (t->>'due_at') is null from _t, jsonb_array_elements(v->'tasks') t where k = 'own_open' and t->>'title' = 'Buy trash bags'), 'a task without a due date reports due_at null, not a made-up date');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a2');
select ok((select (public.tasks_list_v1('e8400000-0000-4000-8000-0000000000b0')->>'manager')::boolean), 'an admin gets the manager view too');
reset role;

-- the staff view ----------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a3');
insert into _t select 'c_open', public.tasks_list_v1('e8400000-0000-4000-8000-0000000000b0');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a4');
insert into _t select 'd_open', public.tasks_list_v1('e8400000-0000-4000-8000-0000000000b0');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a5');
insert into _t select 'm_open', public.tasks_list_v1('e8400000-0000-4000-8000-0000000000b0');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a6');
insert into _t select 'f_open', public.tasks_list_v1('e8400000-0000-4000-8000-0000000000b0');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a7');
insert into _t select 'x_open', public.tasks_list_v1('e8400000-0000-4000-8000-0000000000b0');
reset role;
select ok((select not (v->>'manager')::boolean and (v->>'ok')::boolean from _t where k = 'c_open'), 'a cleaner gets the staff view');
select is((select string_agg(t->>'title', ' | ' order by t->>'title') from _t, jsonb_array_elements(v->'tasks') t where k = 'c_open'),
  'Buy trash bags | Leaking tap in the bathroom | Water plants [hidden] ring [hidden]',
  'cleaner C sees her own task, the unassigned reminder and the cleaning issue; not D''s, the guest follow-up, the guest report, the system task or a verifier finding');
select is((select string_agg(t->>'title', ' | ' order by t->>'title') from _t, jsonb_array_elements(v->'tasks') t where k = 'd_open'),
  'Buy trash bags | Check gate latch | Leaking tap in the bathroom | Repaint the fence', 'cleaner D sees her two assigned tasks plus the two unassigned ones');
select is((select string_agg(t->>'title', ' | ' order by t->>'title') from _t, jsonb_array_elements(v->'tasks') t where k = 'm_open'),
  'Buy trash bags | Leaking tap in the bathroom', 'maintenance sees the unassigned reminder and cleaning issue only');
select is((select count(*)::int from _t, jsonb_array_elements(v->'tasks') t where k = 'f_open'), 2, 'finance (read_operations) gets the same staff rules');
select is((select v->>'reason' from _t where k = 'x_open'), 'not_authorized', 'a staff account with no access to the property gets not_authorized');
select ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(t) k) =
            array['assignee_id','assignee_label','blocks_arrival','completed_at','created_at','detail','due_at','id','kind','mine','priority','source','status','title','version'])
            from _t, jsonb_array_elements(v->'tasks') t where k = 'c_open'), 'a staff row has exactly the allow-listed keys: no guest id, booking id or idempotency key');
select ok((select bool_and(t->'assignee_id' = 'null'::jsonb) from _t, jsonb_array_elements(v->'tasks') t where k = 'c_open'), 'staff never receive another account''s id');
select ok((select (t->>'mine')::boolean from _t, jsonb_array_elements(v->'tasks') t where k = 'c_open' and t->>'title' like 'Water plants%'), 'her own task is flagged mine');
select ok((select not (t->>'mine')::boolean from _t, jsonb_array_elements(v->'tasks') t where k = 'c_open' and t->>'title' = 'Buy trash bags'), 'an unassigned task is not flagged mine');
select ok((select not bool_or((t::text) ~ '(PHP|P)\s?[0-9]|[0-9]{3}\s?pesos|0917|@y\.org|4,550|2,800|1,500') from _t, jsonb_array_elements(v->'tasks') t where k in ('c_open', 'd_open', 'm_open', 'f_open')),
  'no money-shaped value, phone or e-mail reaches any staff payload (D-289, D-306)');
select ok((select t->>'detail' like 'Ask for [hidden] receipt and the [hidden] change' from _t, jsonb_array_elements(v->'tasks') t where k = 'c_open' and t->>'title' = 'Buy trash bags'), 'the detail text is redacted the same way as the title');
select ok((select not bool_or(t->>'source' = 'verifier_findings') from _t, jsonb_array_elements(v->'tasks') t where k in ('c_open', 'd_open', 'm_open', 'f_open')), 'verifier findings are owner/admin only');
select ok((select position('Zz Synthetic Guest' in v::text) = 0 from _t where k = 'c_open'), 'the guest''s name never reaches a cleaner');

-- done / undo ------------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a3');
insert into _t select 'done1', public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'follow_up_tasks', 'e8400000-0000-4000-8000-0000000000f1', true);
insert into _t select 'done1_again', public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'follow_up_tasks', 'e8400000-0000-4000-8000-0000000000f1', true);
insert into _t select 'done_wo', public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'work_orders', 'e8400000-0000-4000-8000-0000000000e1', true, 'Plumber came');
select throws_ok($$select public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'follow_up_tasks', 'e8400000-0000-4000-8000-0000000000f2', true)$$, 'P0002', 'task not found', 'C cannot close a task assigned to D');
select throws_ok($$select public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'follow_up_tasks', 'e8400000-0000-4000-8000-0000000000f4', true)$$, 'P0002', 'task not found', 'C cannot close a guest follow-up');
select throws_ok($$select public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'work_orders', 'e8400000-0000-4000-8000-0000000000e2', true)$$, 'P0002', 'task not found', 'C cannot close a guest report');
select throws_ok($$select public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'transactions', 'e8400000-0000-4000-8000-0000000000f1', true)$$, '22023', 'source must be follow_up_tasks or work_orders', 'only the two task tables can be toggled');
reset role;
select ok((select (v->>'changed')::boolean and v->>'status' = 'done' from _t where k = 'done1'), 'C marks the unassigned reminder done');
select ok((select status = 'done' and completed_at is not null and completed_by = 'e8400000-0000-4000-8000-0000000000a3' and completion_note = 'Marked done in the task list' and version = 2
             from public.follow_up_tasks where id = 'e8400000-0000-4000-8000-0000000000f1'), 'the row records who, when, a default note and a new version');
select ok((select not (v->>'changed')::boolean from _t where k = 'done1_again'), 'a second tap is a quiet no-op, not an error');
select ok((select status = 'resolved' and resolved_by = 'e8400000-0000-4000-8000-0000000000a3' and resolution = 'Plumber came' from public.work_orders where id = 'e8400000-0000-4000-8000-0000000000e1'),
  'closing a work order resolves it with the typed note');
select ok((select count(*) >= 1 from public.admin_audit_log where entity_table = 'follow_up_tasks' and entity_id = 'e8400000-0000-4000-8000-0000000000f1'
            and actor_user_id = 'e8400000-0000-4000-8000-0000000000a3' and after_state->>'status' = 'done'), 'the toggle is in the audit log with the actor');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a3');
insert into _t select 'undo1', public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'follow_up_tasks', 'e8400000-0000-4000-8000-0000000000f1', false);
insert into _t select 'undo_wo', public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'work_orders', 'e8400000-0000-4000-8000-0000000000e1', false);
reset role;
select ok((select status = 'open' and completed_at is null and completed_by is null and completion_note is null from public.follow_up_tasks where id = 'e8400000-0000-4000-8000-0000000000f1'), 'undo reopens the reminder and clears who closed it');
select ok((select status = 'open' and resolved_at is null and resolved_by is null and resolution is null from public.work_orders where id = 'e8400000-0000-4000-8000-0000000000e1'), 'undo reopens the work order');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a7');
select throws_ok($$select public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'follow_up_tasks', 'e8400000-0000-4000-8000-0000000000f1', true)$$, '42501', 'tasks denied', 'a staff account without property access cannot toggle');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a1');
select lives_ok($$select public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'follow_up_tasks', 'e8400000-0000-4000-8000-0000000000f4', true, 'Agreed 14:00')$$, 'the owner can close the guest follow-up');
select throws_ok($$select public.task_set_done_v1('e8400000-0000-4000-8000-0000000000b0', 'follow_up_tasks', 'e8400000-0000-4000-8000-0000000000f8', true)$$, 'P0002', 'task not found', 'a cancelled task cannot be toggled');
reset role;
select ok((select completion_note = 'Agreed 14:00' from public.follow_up_tasks where id = 'e8400000-0000-4000-8000-0000000000f4'), 'a typed note is kept');

-- adding a reminder ------------------------------------------------------------------------------------------------------------
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a3');
select throws_ok($$select public.task_add_reminder_v1('e8400000-0000-4000-8000-0000000000b0', 'Cleaner reminder', null, null, null, 'zz-l4-key-cleaner-0001')$$, '42501', 'manage_operations denied', 'a cleaner cannot add a reminder');
select throws_ok($$select public.task_assignees_v1('e8400000-0000-4000-8000-0000000000b0')$$, '42501', 'manage_operations denied', 'a cleaner cannot list assignees');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a2');
insert into _t select 'rem1', public.task_add_reminder_v1('e8400000-0000-4000-8000-0000000000b0', '  Order new towels  ', now() + interval '2 days', 'e8400000-0000-4000-8000-0000000000a3', 'Call the supplier first', 'zz-l4-key-reminder-0001');
insert into _t select 'rem1_again', public.task_add_reminder_v1('e8400000-0000-4000-8000-0000000000b0', '  Order new towels  ', now() + interval '2 days', 'e8400000-0000-4000-8000-0000000000a3', 'Call the supplier first', 'zz-l4-key-reminder-0001');
select throws_ok($$select public.task_add_reminder_v1('e8400000-0000-4000-8000-0000000000b0', 'ab', null, null, null, 'zz-l4-key-reminder-0002')$$, '22023', 'the title must be 3 to 200 characters', 'a title under 3 characters is refused');
select throws_ok($$select public.task_add_reminder_v1('e8400000-0000-4000-8000-0000000000b0', 'Fine title', null, null, null, 'short')$$, '22023', 'idempotency key required', 'a short idempotency key is refused');
select throws_ok($$select public.task_add_reminder_v1('e8400000-0000-4000-8000-0000000000b0', 'Fine title', null, 'e8400000-0000-4000-8000-0000000000ee', null, 'zz-l4-key-reminder-0003')$$, '22023', 'the assignee is not an active staff account', 'an unknown assignee is refused');
insert into _t select 'assignees', public.task_assignees_v1('e8400000-0000-4000-8000-0000000000b0');
reset role;
select ok((select (v->>'ok')::boolean and v->>'replayed' = 'false' from _t where k = 'rem1'), 'an admin adds a reminder');
select ok((select (v->>'replayed')::boolean and v->>'id' = (select v->>'id' from _t where k = 'rem1') from _t where k = 'rem1_again'), 'the same key replays instead of adding a second reminder');
select ok((select title = 'Order new towels' and detail = 'Call the supplier first' and assignee_user_id = 'e8400000-0000-4000-8000-0000000000a3' and source_kind = 'manual' and guest_id is null
              and purpose = 'other' and status = 'open' and due_at is not null and created_by = 'e8400000-0000-4000-8000-0000000000a2'
             from public.follow_up_tasks where id = (select (v->>'id')::uuid from _t where k = 'rem1')), 'the row is a plain follow_up_tasks row: trimmed title, note, assignee, due date, creator');
select ok((select count(*) = 1 from public.follow_up_tasks where title = 'Order new towels' and property_id = 'e8400000-0000-4000-8000-0000000000b0'), 'no second task store: still one follow_up_tasks row');
select pg_temp.as_user('e8400000-0000-4000-8000-0000000000a3');
insert into _t select 'c_after', public.tasks_list_v1('e8400000-0000-4000-8000-0000000000b0');
reset role;
select ok((select count(*) = 1 from _t, jsonb_array_elements(v->'tasks') t where k = 'c_after' and t->>'title' = 'Order new towels' and (t->>'mine')::boolean and t->>'detail' = 'Call the supplier first'),
  'the assignee sees the new reminder in her list, flagged mine');
select ok((select jsonb_array_length(v->'staff') >= 5 and bool_and(s->>'label' is not null) from _t, jsonb_array_elements(v->'staff') s where k = 'assignees' group by v), 'the assignee list names every active staff member of the property');
select ok((select not bool_or(s->>'user_id' = 'e8400000-0000-4000-8000-0000000000a7') from _t, jsonb_array_elements(v->'staff') s where k = 'assignees'), 'a staff account without access to the property is not offered');

-- the rollback ------------------------------------------------------------------------------------------------------------------------
select lives_ok($$
  drop function if exists public.task_assignees_v1(uuid);
  drop function if exists public.task_add_reminder_v1(uuid, text, timestamptz, uuid, text, text);
  drop function if exists public.task_set_done_v1(uuid, text, uuid, boolean, text);
  drop function if exists public.tasks_list_v1(uuid, boolean);
  drop function if exists public.tasks_rows_v1(uuid, uuid, boolean, boolean);
  drop function if exists public.admin_add_pay_rate_v1(uuid, date, numeric, numeric, numeric, text);
  drop function if exists public.admin_pay_rates_v1(uuid);
  drop trigger if exists admin_audit_row on public.cleaner_rate_schedule;
  drop trigger if exists cleaner_rate_schedule_append_only on public.cleaner_rate_schedule;
  drop function if exists public.cleaner_rate_schedule_append_only();
  drop index if exists public.cleaner_rate_schedule_property_from_uq;
$$, 'the rollback body runs cleanly');
select is((select count(*)::int from pg_proc where pronamespace = 'public'::regnamespace
            and proname in ('admin_pay_rates_v1','admin_add_pay_rate_v1','tasks_rows_v1','tasks_list_v1','task_set_done_v1','task_add_reminder_v1','task_assignees_v1','cleaner_rate_schedule_append_only')), 0,
  'the rollback dropped all eight functions');
select is((select count(*)::int from pg_trigger where tgrelid = 'public.cleaner_rate_schedule'::regclass and not tgisinternal), 0, 'the rollback dropped the rate-table triggers');
select ok((select count(*) = 3 from public.cleaner_rate_schedule where property_id = 'e8400000-0000-4000-8000-0000000000b0'), 'the rates added before the rollback stay');
select lives_ok($$update public.cleaner_rate_schedule set note = note where property_id = 'e8400000-0000-4000-8000-0000000000b0'$$, 'after the rollback the table is writable again');

select * from finish();
rollback;
