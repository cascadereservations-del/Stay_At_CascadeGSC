-- Compensating rollback for release d301_pay_rates_tasks_20261006 (session 72, lane L4).
-- Drops the seven RPCs, the append-only and audit triggers on cleaner_rate_schedule, their trigger function and the unique index.
-- Rate rows added through admin_add_pay_rate_v1 STAY (they are history the staff app may already have paid against); follow-up tasks and
-- work orders closed or reopened through task_set_done_v1, and reminders added through task_add_reminder_v1, stay as ordinary rows.
-- Roll the admin dashboard and the Cascade Staff app back too: their Pay rates and Tasks screens call these functions.
begin;
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
commit;
