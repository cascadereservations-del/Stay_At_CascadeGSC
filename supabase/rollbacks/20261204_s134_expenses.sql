-- Rollback of release s134_expenses_20261204 (D-405). Revert the Cascade-Admin and Cascade-Staff pushes first (they call the new functions), and stop the Telegram functions that call telegram_expense_*.
--   * the two triggers on inventory_purchases and every s134 function are dropped (client, telegram and internal);
--   * kpi_tab_v1 goes back to the s127 body by removing exactly the inserted lines (md5 pinned: 7c6d5a22... or 80efd89e..., 55000 on a body that is neither);
--   * the three s134 indexes and the app_settings key s134_stock_expense_from are dropped.
-- KEPT on purpose (expand-only, inert without the triggers): the 'inventory' value in transactions_source_check, the columns inventory_purchases.transaction_id and .expense_group, the guest_refund category,
-- application/pdf in the expense-receipts mime list, and every ledger row already written (stock rows stay as ordinary expenses; void them in Expenses if they are not wanted).
-- It works with inventory-source rows present: nothing here deletes or rewrites a transactions row.

begin;

-- 1. guard
do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.kpi_tab_v1(uuid,date)');
  if v is null then raise exception 's134 rollback: kpi_tab_v1 is missing' using errcode = '55000'; end if;
  if v is distinct from '7c6d5a22d09ad96916804630f31df602' and v is distinct from '80efd89e916bcd6107c681baf86f143f' then
    raise exception 's134 rollback: kpi_tab_v1 is neither this release nor the s127 body (md5 %)', v using errcode = '55000';
  end if;
end $g$;

-- 2. kpi_tab_v1 back to the s127 body first (it calls kpi_admin_costs_v1, which is dropped below)
do $k$
declare v_src text; v_new text; v_add text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.kpi_tab_v1(uuid,date)');
  if md5(v_src) = '80efd89e916bcd6107c681baf86f143f' then raise notice 's134 rollback: kpi_tab_v1 is already the s127 body'; return; end if;
  v_add := E'\n    -- s134: costs_pending_month, cleaning_pay_open, kpi_source; supplies_month / cleaning_pay_month from the ledger from the cut-over month on (read_finance only, inside if v_fin)\n'
           || '    v_out := jsonb_set(v_out, ''{admin}'', (v_out -> ''admin'') || public.kpi_admin_costs_v1(p_property_id, v_m0, v_m1));';
  if (length(v_src) - length(replace(v_src, v_add, ''))) / length(v_add) <> 1 then raise exception 's134 rollback: the s134 lines are not in kpi_tab_v1 exactly once' using errcode = '55000'; end if;
  v_new := replace(v_src, v_add, '');
  if md5(v_new) <> '80efd89e916bcd6107c681baf86f143f' then raise exception 's134 rollback: kpi_tab_v1 did not return to the s127 body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.kpi_tab_v1(p_property_id uuid, p_month date default null)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
end $k$;
revoke all on function public.kpi_tab_v1(uuid, date) from public, anon, service_role;
grant execute on function public.kpi_tab_v1(uuid, date) to authenticated;

-- 3. triggers, then functions
drop trigger if exists s134_stock_expense_sync on public.inventory_purchases;
drop trigger if exists s134_stock_expense_group on public.inventory_purchases;
drop function if exists public.expenses_screen_v1(uuid, date, integer, timestamptz, text);
drop function if exists public.admin_save_transaction_v2(uuid, jsonb, text);
drop function if exists public.expense_void_v1(uuid, uuid, text, uuid);
drop function if exists public.expense_receipt_paths_v1(uuid, uuid[]);
drop function if exists public.expense_receipt_set_v1(uuid, uuid, text, text);
drop function if exists public.telegram_expense_save_v1(uuid, jsonb, text);
drop function if exists public.telegram_expense_review_v1(uuid, text, jsonb, text);
drop function if exists public.kpi_admin_costs_v1(uuid, date, date);
drop function if exists public.s_stock_expense_trg_v1();
drop function if exists public.s_stock_expense_group_v1();
drop function if exists public.s_stock_expense_sync_v1(text);
drop function if exists public.s_stock_expense_owned_v1(uuid);
drop function if exists public.s_stock_expense_task_v1(uuid, text, text, text);
drop function if exists public.s_txn_void_core_v1(uuid, text, text);
drop function if exists public.s_expense_receipt_gate_v1(uuid, text, uuid);
drop function if exists public.s_expense_lookalike_v1(uuid);
drop function if exists public.s_expense_receipt_v1(uuid, boolean);
drop function if exists public.s_expense_chip_v1(text, boolean, boolean);
drop function if exists public.s_expense_mime_v1(text);
drop function if exists public.s_expense_bucket_pdf_v1(text);
drop function if exists public.s_stock_expense_txn_of_v1(text);
drop function if exists public.s_stock_expense_group_of_v1(uuid, text);

-- 4. indexes and the cut-over setting (the columns and the CHECK value stay)
drop index if exists public.inventory_purchases_transaction_idx;
drop index if exists public.inventory_purchases_expense_group_idx;
drop index if exists public.transactions_stock_ref_idx;
delete from public.app_settings where key = 's134_stock_expense_from';

-- 5. read-back: nothing of s134 is left callable, the s127 body is back, the kept pieces are still there
do $v$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and (p.proname like 's\_stock\_expense\_%' or p.proname like 's\_expense\_%' or p.proname in ('expenses_screen_v1', 'admin_save_transaction_v2', 'expense_void_v1', 'expense_receipt_paths_v1', 'expense_receipt_set_v1', 'telegram_expense_save_v1', 'telegram_expense_review_v1', 'kpi_admin_costs_v1', 's_txn_void_core_v1'))) then
    raise exception 's134 rollback: an s134 function is still present' using errcode = '55000';
  end if;
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.kpi_tab_v1(uuid,date)')) is distinct from '80efd89e916bcd6107c681baf86f143f' then
    raise exception 's134 rollback: kpi_tab_v1 is not the s127 body' using errcode = '55000';
  end if;
  if exists (select 1 from pg_trigger t where t.tgrelid = 'public.inventory_purchases'::regclass and t.tgname like 's134\_%') then
    raise exception 's134 rollback: an s134 trigger is still present' using errcode = '55000';
  end if;
end $v$;

commit;
