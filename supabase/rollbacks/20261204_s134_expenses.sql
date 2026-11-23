-- Rollback of release s134_expenses_20261204 (D-405). Revert the Cascade-Admin and Cascade-Staff pushes first (they call the new functions), and stop the Telegram functions that call telegram_expense_*.
--   * the two triggers on inventory_purchases and every s134 function are dropped (client, telegram and internal);
--   * kpi_tab_v1 goes back to the s127 body by removing exactly the inserted lines (md5 pinned: 7c6d5a22... or 80efd89e..., 55000 on a body that is neither);
--   * admin_review_transaction_v1 goes back to the s89 body (md5 pinned: fef25e31... or this release's 9fc10f4c..., 55000 on a body that is neither);
--   * the three s134 indexes are dropped.
-- KEPT on purpose (expand-only, inert without the triggers): the app_settings key s134_stock_expense_from (the migration keeps the EARLIEST existing value when it is applied again, so the cut-over
-- month never moves later and the KPI never flips back to the legacy figures for rows already filed), the 'inventory' value in transactions_source_check, the columns inventory_purchases.transaction_id and .expense_group, the guest_refund category,
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

-- 2b. admin_review_transaction_v1 back to the s89 body (same signature and grants)
do $a$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.admin_review_transaction_v1(uuid,uuid,text,jsonb,text)');
  if v is null then raise exception 's134 rollback: admin_review_transaction_v1 is missing' using errcode = '55000'; end if;
  if v is distinct from 'fef25e31f2ba4b3df8a9105f38e8c1c2' and v is distinct from '9fc10f4c47ca1343015acdfd6e637510' then
    raise exception 's134 rollback: admin_review_transaction_v1 is neither this release nor the s89 body (md5 %)', v using errcode = '55000';
  end if;
end $a$;
create or replace function public.admin_review_transaction_v1(p_property_id uuid, p_id uuid, p_action text, p_edits jsonb default '{}'::jsonb, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_row public.transactions%rowtype; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_cat text; v_amount numeric; v_date date;
begin
  perform public.admin_require('approve_payment', p_property_id);
  if p_action is null or p_action not in ('approve', 'void') then raise exception using errcode = '22023', message = 'action must be approve or void'; end if;
  p_edits := coalesce(p_edits, '{}'::jsonb);
  if jsonb_typeof(p_edits) <> 'object' then raise exception using errcode = '22023', message = 'edits must be an object'; end if;
  if p_action = 'void' and (v_reason is null or char_length(v_reason) < 3) then raise exception using errcode = '22023', message = 'a reason is required to void'; end if;
  select * into v_row from public.transactions where id = p_id and property_id = p_property_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'transaction not found'; end if;
  if v_row.status <> 'pending_review' then raise exception using errcode = '22023', message = 'this transaction is not waiting for review (it is ' || v_row.status || ')'; end if;
  if v_row.source = 'direct_booking' and v_row.booking_id is not null then
    raise exception using errcode = '22023', message = 'a direct booking payment is confirmed on Inquiries, not here';
  end if;
  if p_action = 'void' then
    -- the shared soft delete: sets void, adds the [voided: reason] note marker and writes the soft_delete audit row
    return public.admin_soft_delete_v1('transactions', v_row.id, v_reason) || jsonb_build_object('status', 'void');
  else
    v_cat := nullif(btrim(coalesce(p_edits->>'category', '')), '');
    v_amount := nullif(p_edits->>'gross_amount', '')::numeric;
    v_date := nullif(p_edits->>'transaction_date', '')::date;
    if p_edits <> '{}'::jsonb and (v_reason is null or char_length(v_reason) < 3) then
      raise exception using errcode = '22023', message = 'a reason is required to change a row while approving';
    end if;
    if v_date is not null and v_date > public.manila_today() + 1 then raise exception using errcode = '22023', message = 'the date cannot be in the future'; end if;
    if v_amount is not null and v_amount <= 0 then raise exception using errcode = '22023', message = 'amount must be more than zero'; end if;
    if v_amount is null and v_row.gross_amount <= 0 then raise exception using errcode = '22023', message = 'enter the amount before approving'; end if;
    if v_cat is not null and v_cat is distinct from v_row.category and v_row.txn_type = 'expense'
       and not exists (select 1 from public.expense_categories c where c.property_id = p_property_id and c.slug = v_cat and c.is_active) then
      raise exception using errcode = '22023', message = 'unknown expense category';
    end if;
    perform public.admin_audit_context_v1(coalesce(v_reason, case when p_edits = '{}'::jsonb then 'approved in review queue' else 'edited and approved in review queue' end), null, null);
    update public.transactions set
      status = 'confirmed',
      category = coalesce(v_cat, category),
      gross_amount = coalesce(v_amount, gross_amount),
      transaction_date = coalesce(v_date, transaction_date),
      payee_name = case when p_edits ? 'payee_name' then nullif(btrim(p_edits->>'payee_name'), '') else payee_name end,
      notes = case when p_edits ? 'notes' then nullif(btrim(p_edits->>'notes'), '') else notes end,
      or_number = case when p_edits ? 'or_number' then nullif(btrim(p_edits->>'or_number'), '') else or_number end,
      updated_at = now()
    where id = v_row.id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status,
    'auditId', (select a.id from public.admin_audit_log a where a.entity_table = 'transactions' and a.entity_id = v_row.id order by a.created_at desc, a.id limit 1));
end;
$$;
comment on function public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text) is 'S89: approve (optionally with edits) or void a pending_review ledger row. approve_payment only; audited by the table trigger; void is a soft_delete audit row with the reason.';
revoke all on function public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text) from public, anon, service_role;
grant execute on function public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text) to authenticated;

-- 3. triggers, then functions
drop trigger if exists s134_stock_expense_sync on public.inventory_purchases;
drop trigger if exists s134_stock_expense_group on public.inventory_purchases;
drop function if exists public.expenses_screen_v1(uuid, date, integer, timestamptz, text, uuid);
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
drop function if exists public.s_txn_void_core_v1(uuid, text, text, boolean);
drop function if exists public.s_txn_void_core_v1(uuid, text, text);
drop function if exists public.s_expense_receipt_gate_v1(uuid, text, uuid);
drop function if exists public.s_expense_lookalike_v1(uuid);
drop function if exists public.s_expense_receipt_v1(uuid, boolean);
drop function if exists public.s_expense_chip_v1(text, boolean, boolean);
drop function if exists public.s_expense_mime_v1(text);
drop function if exists public.s_expense_bucket_pdf_v1(text);
drop function if exists public.s_stock_expense_txn_of_v1(text);
drop function if exists public.s_stock_expense_group_of_v1(uuid, text);

-- 4. indexes (the cut-over setting, the columns and the CHECK value stay)
drop index if exists public.inventory_purchases_transaction_idx;
drop index if exists public.inventory_purchases_expense_group_idx;
drop index if exists public.transactions_stock_ref_idx;

-- 5. read-back: nothing of s134 is left callable, the s127 body is back, the kept pieces are still there
do $v$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and (p.proname like 's\_stock\_expense\_%' or p.proname like 's\_expense\_%' or p.proname in ('expenses_screen_v1', 'admin_save_transaction_v2', 'expense_void_v1', 'expense_receipt_paths_v1', 'expense_receipt_set_v1', 'telegram_expense_save_v1', 'telegram_expense_review_v1', 'kpi_admin_costs_v1', 's_txn_void_core_v1'))) then
    raise exception 's134 rollback: an s134 function is still present' using errcode = '55000';
  end if;
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.kpi_tab_v1(uuid,date)')) is distinct from '80efd89e916bcd6107c681baf86f143f' then
    raise exception 's134 rollback: kpi_tab_v1 is not the s127 body' using errcode = '55000';
  end if;
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.admin_review_transaction_v1(uuid,uuid,text,jsonb,text)')) is distinct from 'fef25e31f2ba4b3df8a9105f38e8c1c2' then
    raise exception 's134 rollback: admin_review_transaction_v1 is not the s89 body' using errcode = '55000';
  end if;
  if exists (select 1 from pg_trigger t where t.tgrelid = 'public.inventory_purchases'::regclass and t.tgname like 's134\_%') then
    raise exception 's134 rollback: an s134 trigger is still present' using errcode = '55000';
  end if;
end $v$;

commit;
