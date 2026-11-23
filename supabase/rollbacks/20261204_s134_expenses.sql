-- Rollback of release s134_expenses_20261204 (D-405). Revert the Cascade-Admin and Cascade-Staff pushes first (they call the new functions), and stop the Telegram functions that call telegram_expense_*.
--   * the two triggers on inventory_purchases, the confirm-gate trigger on transactions (s134_stock_expense_confirm_guard) and every s134 function are dropped (client, telegram and internal);
--   * kpi_tab_v1 goes back to the s127 body by removing exactly the inserted lines (md5 pinned: 7c6d5a22... or 80efd89e..., 55000 on a body that is neither);
--   * admin_review_transaction_v1 goes back to the s89 body (md5 pinned: fef25e31... or this release's 9fc10f4c..., 55000 on a body that is neither);
--   * admin_review_queue_v1 goes back to the s89 body (md5 pinned: ed2a6920... or this release's 48ef55da008a00763a0ec2d9fc9053dc, 55000 on a body that is neither);
--   * admin_save_transaction_v1 goes back to the s89 body (md5 pinned: ff48081b485cacf547a1692d7641d85b or this release's 697fb240f1a177721601bb148af8c9cc, 55000 on a body that is neither);
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

-- 2c. admin_review_queue_v1 back to the s89 body (same signature and grants)
do $q$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.admin_review_queue_v1(uuid)');
  if v is null then raise exception 's134 rollback: admin_review_queue_v1 is missing' using errcode = '55000'; end if;
  if v is distinct from 'ed2a69205d365ea8afe96d5f55aa677b' and v is distinct from '48ef55da008a00763a0ec2d9fc9053dc' then
    raise exception 's134 rollback: admin_review_queue_v1 is neither this release nor the s89 body (md5 %)', v using errcode = '55000';
  end if;
end $q$;
create or replace function public.admin_review_queue_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_count integer; v_total numeric; v_rows jsonb;
begin
  perform public.admin_require('read_finance', p_property_id);
  select count(*), coalesce(sum(t.gross_amount), 0) into v_count, v_total
    from public.transactions t
   where t.property_id = p_property_id and t.status = 'pending_review' and not (t.source = 'direct_booking' and t.booking_id is not null);
  select coalesce(jsonb_agg(to_jsonb(q) order by q.transaction_date desc, q.created_at desc), '[]'::jsonb) into v_rows from (
    select t.id, t.transaction_date, t.txn_type, t.category, t.gross_amount, t.payee_name, t.notes, t.or_number, t.source,
           t.receipt_image_path, t.ocr_confidence, t.created_at
      from public.transactions t
     where t.property_id = p_property_id and t.status = 'pending_review' and not (t.source = 'direct_booking' and t.booking_id is not null)
     order by t.transaction_date desc, t.created_at desc limit 100) q;
  return jsonb_build_object('count', v_count, 'total', v_total, 'rows', v_rows, 'truncated', v_count > 100);
end;
$$;
revoke all on function public.admin_review_queue_v1(uuid) from public, anon, service_role;
grant execute on function public.admin_review_queue_v1(uuid) to authenticated;
comment on function public.admin_review_queue_v1(uuid) is 'S89: transactions waiting for review (count, total, newest 100). No guest data; direct-booking payments are on Inquiries. owner/admin/finance.';


-- 2d. admin_save_transaction_v1 back to the s89 body (same signature and grants)
do $s$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.admin_save_transaction_v1(uuid,jsonb,text)');
  if v is null then raise exception 's134 rollback: admin_save_transaction_v1 is missing' using errcode = '55000'; end if;
  if v is distinct from 'ff48081b485cacf547a1692d7641d85b' and v is distinct from '697fb240f1a177721601bb148af8c9cc' then
    raise exception 's134 rollback: admin_save_transaction_v1 is neither this release nor the s89 body (md5 %)', v using errcode = '55000';
  end if;
end $s$;
create or replace function public.admin_save_transaction_v1(p_property_id uuid, p_txn jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id uuid; v_row public.transactions%rowtype; v_type text; v_amount numeric; v_date date; v_ref text; v_reason text;
        v_receipt text; v_conf numeric; v_raw jsonb;
begin
  perform public.admin_require('approve_payment', p_property_id);
  v_id := nullif(p_txn->>'id', '')::uuid;
  v_type := coalesce(p_txn->>'txn_type', 'expense');
  if v_type not in ('income','expense','drawing') then raise exception using errcode = '22023', message = 'txn_type must be income, expense or drawing'; end if;
  v_amount := nullif(p_txn->>'gross_amount', '')::numeric;
  v_date := nullif(p_txn->>'transaction_date', '')::date;
  v_reason := nullif(btrim(coalesce(p_txn->>'reason', '')), '');
  -- S89: optional receipt. Validated before anything is written.
  v_receipt := nullif(btrim(coalesce(p_txn->>'receipt_image_path', '')), '');
  if v_receipt is not null then
    if v_receipt like '%..%' or v_receipt like '/%' or char_length(v_receipt) > 300
       or not (v_receipt like p_property_id::text || '/%' or v_receipt like 'receipts/%') then
      raise exception using errcode = '22023', message = 'receipt path is not allowed';
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'expense-receipts' and o.name = v_receipt) then
      raise exception using errcode = '22023', message = 'receipt file was not found';
    end if;
    if exists (select 1 from public.transactions t where t.receipt_image_path = v_receipt and t.status <> 'void' and t.id is distinct from v_id) then
      raise exception using errcode = '23505', message = 'this receipt is already attached to another transaction';
    end if;
    if nullif(p_txn->>'ocr_confidence', '') is not null then
      v_conf := (p_txn->>'ocr_confidence')::numeric;
      if v_conf < 0 or v_conf > 1 then raise exception using errcode = '22023', message = 'ocr_confidence must be between 0 and 1'; end if;
    end if;
    if p_txn ? 'ocr_raw' and jsonb_typeof(p_txn->'ocr_raw') = 'object' then
      v_raw := p_txn->'ocr_raw';
      if char_length(v_raw::text) > 20000 then raise exception using errcode = '22023', message = 'ocr_raw is too large'; end if;
    end if;
  end if;
  if v_id is null then
    if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
    if v_amount is null or v_amount < 0 or v_date is null then raise exception using errcode = '22023', message = 'amount and date are required'; end if;
    v_ref := coalesce(nullif(p_txn->>'external_ref', ''), 'admin:' || p_idempotency_key);
    select * into v_row from public.transactions where property_id = p_property_id and external_ref = v_ref;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'replayed', true); end if;
    perform public.admin_audit_context_v1(coalesce(v_reason, 'created in admin'), null, null);
    insert into public.transactions(property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, or_number, payee_name, notes, external_ref, income_stage, reservation_id, booking_id, logged_by, receipt_image_path, ocr_confidence, ocr_raw)
    values (p_property_id, v_type, coalesce(nullif(p_txn->>'category', ''), case v_type when 'drawing' then 'owner_drawing' else 'other' end), coalesce(nullif(p_txn->>'status', ''), 'confirmed'), 'manual', v_date, v_amount, 'PHP',
            nullif(p_txn->>'or_number', ''), nullif(p_txn->>'payee_name', ''), nullif(p_txn->>'notes', ''), v_ref, case when v_type = 'income' then 'confirmed' end,
            nullif(p_txn->>'reservation_id', '')::uuid, nullif(p_txn->>'booking_id', '')::uuid, 'admin', v_receipt, v_conf, v_raw)
    returning * into v_row;
  else
    select * into v_row from public.transactions where id = v_id and property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'transaction not found'; end if;
    if v_row.status = 'void' then raise exception using errcode = '22023', message = 'a void transaction cannot be edited; undo the void first'; end if;
    if v_reason is null then raise exception using errcode = '22023', message = 'a reason is required to edit a ledger row'; end if;
    perform public.admin_audit_context_v1(v_reason, null, null);
    update public.transactions set
      txn_type = case when p_txn ? 'txn_type' then v_type else txn_type end,
      category = coalesce(nullif(p_txn->>'category', ''), category),
      transaction_date = coalesce(v_date, transaction_date),
      gross_amount = coalesce(v_amount, gross_amount),
      or_number = case when p_txn ? 'or_number' then nullif(p_txn->>'or_number', '') else or_number end,
      payee_name = case when p_txn ? 'payee_name' then nullif(p_txn->>'payee_name', '') else payee_name end,
      notes = case when p_txn ? 'notes' then nullif(p_txn->>'notes', '') else notes end,
      reservation_id = case when p_txn ? 'reservation_id' then nullif(p_txn->>'reservation_id', '')::uuid else reservation_id end,
      status = case when p_txn ? 'status' and (p_txn->>'status') in ('confirmed','pending_review') then p_txn->>'status' else status end,
      receipt_image_path = coalesce(v_receipt, receipt_image_path),
      ocr_confidence = case when v_receipt is not null then coalesce(v_conf, ocr_confidence) else ocr_confidence end,
      ocr_raw = case when v_receipt is not null then coalesce(v_raw, ocr_raw) else ocr_raw end,
      updated_at = now()
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'auditId', (select id from public.admin_audit_log where entity_table = 'transactions' and entity_id = v_row.id order by created_at desc limit 1));
end;
$$;
revoke all on function public.admin_save_transaction_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.admin_save_transaction_v1(uuid, jsonb, text) to authenticated;

-- 3. triggers, then functions
drop trigger if exists s134_stock_expense_confirm_guard on public.transactions;
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
drop function if exists public.s_stock_expense_confirm_guard_v1();
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
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.admin_review_queue_v1(uuid)')) is distinct from 'ed2a69205d365ea8afe96d5f55aa677b' then
    raise exception 's134 rollback: admin_review_queue_v1 is not the s89 body' using errcode = '55000';
  end if;
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure('public.admin_save_transaction_v1(uuid,jsonb,text)')) is distinct from 'ff48081b485cacf547a1692d7641d85b' then
    raise exception 's134 rollback: admin_save_transaction_v1 is not the s89 body' using errcode = '55000';
  end if;
  if exists (select 1 from pg_trigger t where t.tgrelid = 'public.transactions'::regclass and t.tgname = 's134_stock_expense_confirm_guard') then
    raise exception 's134 rollback: the confirm-gate trigger is still present' using errcode = '55000';
  end if;
  if exists (select 1 from pg_trigger t where t.tgrelid = 'public.inventory_purchases'::regclass and t.tgname like 's134\_%') then
    raise exception 's134 rollback: an s134 trigger is still present' using errcode = '55000';
  end if;
end $v$;

commit;
