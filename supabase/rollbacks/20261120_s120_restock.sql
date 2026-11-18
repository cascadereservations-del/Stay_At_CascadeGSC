-- Compensating rollback for release s120_restock_20261120 (session 120, migration 20261120000004_s120_restock.sql).
-- Drops the three restock functions and the two closed tables. DATA LOSS (by design): every remembered restock amount and every Yes / No upkeep answer.
-- Usage rows written through record_inventory_usage stay (they are ordinary inventory_usage history), and open Follow-ups tasks of kind restock_reminder stay as
-- they are: they are true statements about stock and an admin closes them by hand. Roll the Staff app back first (it calls the three functions). Apply with run-sql-on-host.sh.
-- The migration also restated revoke/grant on system_task_open_v1 (service_role only, as its own migration set it). This script leaves that grant alone: reverting it
-- would only reopen a function that is meant to be closed.

begin;

drop function if exists public.restock_remind_admin_v1(uuid, uuid);
drop function if exists public.record_restock_v1(uuid, date, text, text, jsonb, jsonb, jsonb);
drop function if exists public.restock_context_v1(uuid);
drop table if exists public.restock_upkeep_checks;
drop table if exists public.restock_remembered_amounts;

do $$
begin
  if to_regclass('public.restock_upkeep_checks') is not null or to_regclass('public.restock_remembered_amounts') is not null then
    raise exception 's120 restock rollback: a restock table is still there' using errcode = '55000';
  end if;
  if to_regprocedure('public.restock_context_v1(uuid)') is not null
     or to_regprocedure('public.record_restock_v1(uuid,date,text,text,jsonb,jsonb,jsonb)') is not null
     or to_regprocedure('public.restock_remind_admin_v1(uuid,uuid)') is not null then
    raise exception 's120 restock rollback: a restock function is still there' using errcode = '55000';
  end if;
end $$;

commit;
