-- Compensating rollback for 20260914200000_admin_crud_audit_v1.sql.
-- Drops what the migration added and restores the two-value txn_type check.
-- Refuses to run while any 'drawing' row exists, because narrowing the check
-- would otherwise fail half way; void or retype those rows first.
begin;

do $$
begin
  if exists (select 1 from public.transactions where txn_type = 'drawing') then
    raise exception 'drawing rows exist; retype or void them before rolling back';
  end if;
end $$;

do $$
declare t text;
begin
  foreach t in array array['transactions','work_orders','follow_up_tasks','ops_notices','inventory_shopping_list','meter_readings'] loop
    execute format('drop trigger if exists admin_audit_row on public.%I', t);
  end loop;
end $$;

drop function if exists public.run_health_checks_v1(uuid);
drop function if exists public.admin_audit_feed_v1(uuid, integer);
drop function if exists public.review_meter_reading_v1(uuid, text, text);
drop function if exists public.admin_save_transaction_v1(uuid, jsonb, text);
drop function if exists public.admin_undo_v1(uuid, text);
drop function if exists public.admin_soft_delete_v1(text, uuid, text);
drop function if exists public.admin_table_action_v1(text);
drop function if exists public.admin_audit_context_v1(text, text, uuid);
drop function if exists public.admin_audit_row_v1();
drop table if exists public.admin_health_check_runs;
drop table if exists public.admin_audit_log;

alter table public.transactions drop constraint if exists transactions_txn_type_check;
alter table public.transactions add constraint transactions_txn_type_check check (txn_type in ('income','expense'));

commit;
