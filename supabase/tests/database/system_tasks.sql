-- Session 45: release system_tasks_20260923 (D-218). A job files a non-urgent problem as ONE Follow-ups
-- task, and closes it when the problem stops being reported. Fixtures roll back with the transaction.

begin;
select plan(11);

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000046', 'Synthetic Tasks 46', true);

-- Only the scheduled jobs may call them.
select ok(has_function_privilege('service_role', 'public.system_task_open_v1(uuid, text, text, text, text, text)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public.system_task_open_v1(uuid, text, text, text, text, text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.system_task_open_v1(uuid, text, text, text, text, text)', 'EXECUTE'),
  'opening a system task is service_role only');
select ok(has_function_privilege('service_role', 'public.system_task_close_missing_v1(text, text[], text, text)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public.system_task_close_missing_v1(text, text[], text, text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.system_task_close_missing_v1(text, text[], text, text)', 'EXECUTE'),
  'closing system tasks is service_role only');

-- Idempotent: the same problem reported every morning is still one task.
create temp table t46 as select public.system_task_open_v1('e1000000-0000-4000-8000-000000000046', 'missed_cleaning', '2026-09-20',
  'Cleaning report missing: Synthetic Guest, checkout Sep 20', 'detail', 'normal') id;
select is(public.system_task_open_v1('e1000000-0000-4000-8000-000000000046', 'missed_cleaning', '2026-09-20',
  'Cleaning report missing: Synthetic Guest, checkout Sep 20', 'detail', 'normal'), (select id from t46),
  'opening the same problem again returns the same task');
select is((select count(*) from public.follow_up_tasks where idempotency_key = 'system:missed_cleaning:2026-09-20'), 1::bigint,
  'and there is exactly one row');
select is((select status from public.follow_up_tasks where id = (select id from t46)), 'open', 'it is open');

select throws_ok($$select public.system_task_open_v1('e1000000-0000-4000-8000-000000000046', 'Bad Kind!', 'x', 'title')$$,
  '22023', null, 'a malformed kind is refused');

-- Closing: still reported stays open; no longer reported inside the window closes; outside the window never closes.
create temp table old46 as select public.system_task_open_v1('e1000000-0000-4000-8000-000000000046', 'missed_cleaning', '2026-09-01', 'Old one', null, 'normal') id;
select is(public.system_task_close_missing_v1('missed_cleaning', array['2026-09-20'], '2026-09-10', 'closed'), 0,
  'a task still reported is not closed');
select is(public.system_task_close_missing_v1('missed_cleaning', array[]::text[], '2026-09-10', 'Closed: the report is on file.'), 1,
  'a task no longer reported, inside the window, is closed');
select is((select status || ' / ' || completion_note from public.follow_up_tasks where id = (select id from t46)),
  'done / Closed: the report is on file.', 'with the reason written on it');
select is((select status from public.follow_up_tasks where id = (select id from old46)), 'open',
  'a task whose ref aged out of the window is never closed as if fixed');

-- A person's own task is never touched by a job.
insert into public.follow_up_tasks(property_id, purpose, title, status, source_kind, source_ref, idempotency_key)
values ('e1000000-0000-4000-8000-000000000046', 'other', 'A task a person wrote', 'open', 'missed_cleaning', '2026-09-21', 'manual-task-000000046');
create temp table sweep46 as select public.system_task_close_missing_v1('missed_cleaning', array[]::text[], null, 'closed') n;
select is((select status from public.follow_up_tasks where idempotency_key = 'manual-task-000000046'), 'open',
  'a task a person created is never closed by a job');

select * from finish();
rollback;
