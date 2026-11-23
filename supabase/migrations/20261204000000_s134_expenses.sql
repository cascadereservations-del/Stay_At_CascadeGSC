-- Session 134: release s134_expenses_20261204 (D-405). One expense ledger: stock bought becomes ONE ledger row per receipt (deferred trigger, never fails a stock write), an admin Expenses
-- screen reads the ledger by the one cost definition, receipts attach through one control, and the KPI tab reads Supplies / Cleaning pay from the ledger from the cut-over month on.
-- Contract: docs/s134/SPEC.md sections 3, 5, 5.1, 6, 7, 13.3-13.4, 14 (Revision 3 wins) and docs/s134/PLAN.md "L1", "L1 additions", "Revision 3". Over s133_option_stock_20261203 (live).
--
--   COST DEFINITION  expense + confirmed + source not in (airbnb, airbnb_email) + month of transaction_date (= get_finance_summary, which is NOT replaced). Pending is shown, not counted.
--   CHECK            transactions_source_check gains 'inventory' (same guarded drop-and-add as s127).
--   COLUMNS          inventory_purchases.transaction_id (FK, on delete set null) and .expense_group, both indexed; BEFORE INSERT trigger s_stock_expense_group_v1 sets the group from the note.
--   STOCK -> LEDGER  deferred constraint trigger s_stock_expense_trg_v1 (after insert, delete, update of qty / unit_cost / purchased_at) -> s_stock_expense_sync_v1(group): advisory lock, ownership rule,
--                    steps 1-6 of SPEC 5.1, nested exception blocks (a failure is a warning plus a stock_expense_sync follow-up task, never a failed stock write). Groups older than the cut-over are the
--                    back-fill's (supabase/sql/s134_backfill.sql); the sync creates a row only for a group whose first purchase was recorded after the cut-over.
--   NEW (client)     expenses_screen_v1, admin_save_transaction_v2, expense_void_v1, expense_receipt_paths_v1, expense_receipt_set_v1   (authenticated only)
--   NEW (telegram)   telegram_expense_save_v1, telegram_expense_review_v1   (service_role only)
--   NEW (internal)   s_stock_expense_group_of_v1, s_stock_expense_txn_of_v1, s_stock_expense_group_v1, s_stock_expense_trg_v1, s_stock_expense_sync_v1, s_stock_expense_task_v1, s_stock_expense_owned_v1,
--                    s_txn_void_core_v1, s_expense_chip_v1, s_expense_mime_v1, s_expense_receipt_v1, s_expense_lookalike_v1, s_expense_receipt_gate_v1, s_expense_bucket_pdf_v1, kpi_admin_costs_v1   (no grants)
--   CHANGED          kpi_tab_v1(uuid,date): ONE anchored replace inside `if v_fin` (SPEC 6). Guard: the live body is the s127 body or this release (both md5s pinned); the replace must match exactly once.
--   BUCKET           expense-receipts gains application/pdf in allowed_mime_types when the list is not null; the migration stops when file_size_limit is not null and under 5 MB (R4).
--                   admin_review_transaction_v1(uuid,uuid,text,jsonb,text) (s89, same signature and grants): approve refuses amount_incomplete, amount_locked, system_category, locked as {ok:false,error,where}; the rollback restores the s89 body.
--                   admin_review_queue_v1(uuid) (s89, same signature and grants): each row also returns s134_incomplete (boolean); the rollback restores the s89 body.
-- Guard (55000, nothing changes): the functions the trigger depends on must be the bodies this release was cut from. Grants restated (ML-21).
-- Rollback: supabase/rollbacks/20261204_s134_expenses.sql (keeps the 'inventory' CHECK value and the two purchase columns: expand-only, inert without the triggers).

begin;

-- 0. guard ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare r record; v text;
begin
  for r in select * from (values
    ('public.kpi_tab_v1(uuid,date)', '80efd89e916bcd6107c681baf86f143f', '7c6d5a22d09ad96916804630f31df602'),
    ('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid,text)', 'd190f6b6051be034e9e9babb99cbbf56', null),
    ('public.s_inventory_receipt_apply_v1(uuid,numeric,numeric,text,uuid,date,text,uuid)', '1d89aede56a8ed77aaf48a46f731300e', null),
    ('public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid,uuid)', 'd8b04844b3f9c654c6355a1958694402', null),
    ('public.s_inventory_receipt_confirm_core_v1(uuid,jsonb,date,text,boolean)', '6f1e7dc8c1dc43cd6dfb9cf2f92f9af9', null),
    ('public.inventory_receipt_manual_v1(jsonb,date,text,text,numeric,text,text)', '8c407320edbbc9d944a86461bef23adf', null),
    ('public.inventory_receipt_lines_v1(uuid,jsonb,numeric,date,uuid,text)', 'aff79ca9f33b04253d35ecf8f6038d9a', null),
    ('public.inventory_group_update_v1(uuid,text,jsonb,text)', '960acf4721bd5b0b95fde7845069035c', null),
    ('public.s_inventory_derive_key_v1(text,text)', '736e38143d5e421624c129c9ac5d9dde', null),
    ('public.inventory_receipt_undo_v1(uuid)', '589b583719a611445fcd88a6c1badf92', null),
    ('public.inventory_undo_v1(uuid,uuid)', '5125463a4d686d5a180f1ee599fa00b7', null),
    ('public.admin_review_transaction_v1(uuid,uuid,text,jsonb,text)', 'fef25e31f2ba4b3df8a9105f38e8c1c2', '9fc10f4c47ca1343015acdfd6e637510'),
    ('public.admin_review_queue_v1(uuid)', 'ed2a69205d365ea8afe96d5f55aa677b', '48ef55da008a00763a0ec2d9fc9053dc'),
    ('public.admin_save_transaction_v1(uuid,jsonb,text)', 'ff48081b485cacf547a1692d7641d85b', 'd58ca5bd59aac0681f8ed8fd914cbe13')
  ) t(sig, m_a, m_b) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is null then raise exception 's134: % is missing (apply s133 first)', r.sig using errcode = '55000'; end if;
    if v is distinct from r.m_a and v is distinct from r.m_b then
      raise exception 's134: % is not the body this release was cut from (md5 %): re-cut it from the live body', r.sig, v using errcode = '55000';
    end if;
  end loop;
  foreach v in array array['public.system_task_open_v1(uuid,text,text,text,text,text)', 'public.admin_audit_context_v1(text,text,uuid)', 'public.get_finance_summary(date,uuid)', 'public.admin_require(text,uuid)',
                           'public.current_staff_authorized(text,uuid)', 'public.manila_today()', 'public.try_uuid(text)', 'public.kpi_admin_bills_v1(uuid,numeric)'] loop
    if to_regprocedure(v) is null then raise exception 's134: % is missing' , v using errcode = '55000'; end if;
  end loop;
end $g$;

-- 1. the ledger accepts source 'inventory' (guarded drop-and-add, as s127 did for 'bill') ---------------------------------------------------------------------------------------------------------------------
do $c$
declare
  v_def text; v_bad text;
  v_known constant text[] := array['telegram', 'ocr', 'booking', 'manual', 'import', 'airbnb', 'airbnb_email', 'airbnb_payout_email', 'direct_booking', 'cleaner_fee', 'refund', 'bill'];
begin
  select pg_get_constraintdef(c.oid) into v_def from pg_constraint c where c.conrelid = 'public.transactions'::regclass and c.conname = 'transactions_source_check';
  if v_def is null then raise exception 's134: transactions_source_check is missing' using errcode = '55000'; end if;
  if v_def like '%''inventory''%' then return; end if;
  select string_agg(m[1], ', ') into v_bad from regexp_matches(v_def, '''([^'']+)''', 'g') m where m[1] <> all (v_known);
  if v_bad is not null then
    raise exception using errcode = '55000', message = 's134: transactions_source_check holds values this release does not know (' || v_bad || '): re-cut the list from the live constraint';
  end if;
  execute 'alter table public.transactions drop constraint transactions_source_check';
  execute 'alter table public.transactions add constraint transactions_source_check check (source = any (array[''telegram'', ''ocr'', ''booking'', ''manual'', ''import'', ''airbnb'', ''airbnb_email'', ''airbnb_payout_email'', ''direct_booking'', ''cleaner_fee'', ''refund'', ''bill'', ''inventory''])) not valid';
  execute 'alter table public.transactions validate constraint transactions_source_check';
end $c$;

-- 2. columns, indexes, settings, the system category ---------------------------------------------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_purchases add column if not exists transaction_id uuid references public.transactions(id) on delete set null;
alter table public.inventory_purchases add column if not exists expense_group text;
create index if not exists inventory_purchases_transaction_idx on public.inventory_purchases (transaction_id) where transaction_id is not null;
create index if not exists inventory_purchases_expense_group_idx on public.inventory_purchases (expense_group) where expense_group is not null;
create index if not exists transactions_stock_ref_idx on public.transactions (external_ref) where external_ref like 'stock:%';
comment on column public.inventory_purchases.transaction_id is 'S134: the one ledger row this purchase belongs to (set by the stock-to-ledger sync or the back-fill). Null = not linked.';
comment on column public.inventory_purchases.expense_group is 'S134: the receipt this purchase belongs to (txn:<uuid> | draft:<uuid> | rcpt:<key> | p:<purchase id>), set from the purchase note by a BEFORE INSERT trigger.';

-- the release time: the KPI switch uses its month in Manila, the "unlinked" count and the sync's create rule use the timestamp
insert into public.app_settings (key, value) values ('s134_stock_expense_from', to_jsonb(now())) on conflict (key) do nothing;

-- guest_refund must exist as a category wherever the other categories do (it is a system slug, never pickable by hand)
insert into public.expense_categories (property_id, slug, label, is_active, sort_order)
select distinct ec.property_id, 'guest_refund', 'Guest refund', true, 900
  from public.expense_categories ec
 where not exists (select 1 from public.expense_categories x where x.property_id = ec.property_id and x.slug = 'guest_refund');

-- 3. internal helpers ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 3a. the group of a purchase from its note. txn:<uuid> | draft:<uuid> | rcpt:<key without trailing :g<n>> | p:<id>. The uuid is matched by regex before any cast.
create or replace function public.s_stock_expense_group_of_v1(p_id uuid, p_notes text)
returns text language plpgsql immutable set search_path = '' as $$
declare v_k text; v_u text;
begin
  v_u := lower((regexp_match(coalesce(p_notes, ''), '\(txn ([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\)'))[1]);
  if v_u is not null then return 'txn:' || v_u; end if;
  v_u := lower((regexp_match(coalesce(p_notes, ''), '^Staff receipt \[key:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\]'))[1]);
  if v_u is not null then return 'draft:' || v_u; end if;
  if coalesce(p_notes, '') ~ '^Admin receipt \[key:' then
    v_k := (regexp_match(p_notes, '\[key:([^]]*)\]'))[1];
    v_k := regexp_replace(coalesce(v_k, ''), '(:g[0-9]+)+$', '');
    if v_k <> '' then return 'rcpt:' || v_k; end if;
  end if;
  return 'p:' || p_id::text;
end $$;

create or replace function public.s_stock_expense_txn_of_v1(p_notes text)
returns uuid language sql immutable set search_path = '' as $$
  select lower((regexp_match(coalesce(p_notes, ''), '\(txn ([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\)'))[1])::uuid
$$;

-- 3b. BEFORE INSERT trigger: group (and, for the Telegram path, the link) from the note. Any failure falls back to p:<id>; it never blocks the insert.
create or replace function public.s_stock_expense_group_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  begin
    if new.expense_group is null then new.expense_group := public.s_stock_expense_group_of_v1(new.id, new.notes); end if;
    if new.transaction_id is null then
      new.transaction_id := (select t.id from public.transactions t where t.id = public.s_stock_expense_txn_of_v1(new.notes));
    end if;
  exception when others then
    begin
      new.expense_group := coalesce(new.expense_group, 'p:' || new.id::text);
    exception when others then
      null;
    end;
  end;
  return new;
end $$;

-- 3c. follow-up task, never raises (the second, nested layer of SPEC 5.1 step 6)
create or replace function public.s_stock_expense_task_v1(p_prop uuid, p_group text, p_title text, p_detail text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  begin
    if p_prop is null then raise warning 's134 stock sync (%): %', p_group, p_title; return; end if;
    perform public.system_task_open_v1(p_prop, 'stock_expense_sync', left(p_group, 100), p_title, p_detail, 'normal');
  exception when others then
    raise warning 's134 stock sync task failed (%): %', p_group, sqlerrm;
  end;
end $$;

-- 3d. who owns a stock row's amount: the sync, while the row is its own (stock:<group>, source inventory), not void, pending or auto-confirmed, and the amount is still the one it wrote
create or replace function public.s_stock_expense_owned_v1(p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select t.source = 'inventory' and t.external_ref like 'stock:%' and t.status <> 'void'
                          and (t.status = 'pending_review' or t.ocr_raw ->> 's134_auto' = 'true')
                          and case when (t.ocr_raw ->> 's134_amount') ~ '^[0-9]+(\.[0-9]+)?$' then t.gross_amount = (t.ocr_raw ->> 's134_amount')::numeric else false end
                     from public.transactions t where t.id = p_id), false)
$$;

-- 3e. the shared void core (same effect as admin_soft_delete_v1 on a transaction: status void, marker appended, original note kept)
create or replace function public.s_txn_void_core_v1(p_id uuid, p_reason text, p_marker text default null, p_owned_only boolean default false)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  perform public.admin_audit_context_v1(p_reason, 'soft_delete', null);
  -- p_owned_only (the stock sync): the ownership rule of s_stock_expense_owned_v1 is part of the WHERE, so a row a person approved or edited after the sync read it is never voided (returns false)
  update public.transactions set status = 'void', notes = concat_ws(' ', notes, '[voided: ' || coalesce(nullif(btrim(p_marker), ''), p_reason) || ']'), updated_at = now()
   where id = p_id and status <> 'void'
     and (not p_owned_only or (source = 'inventory' and external_ref like 'stock:%' and (status = 'pending_review' or ocr_raw ->> 's134_auto' = 'true')
                               and case when (ocr_raw ->> 's134_amount') ~ '^[0-9]+(\.[0-9]+)?$' then gross_amount = (ocr_raw ->> 's134_amount')::numeric else false end));
  get diagnostics v_n = row_count;
  perform public.admin_audit_context_v1('', null, null);
  return v_n > 0;
end $$;

-- 3f. the sync: one ledger row per receipt group (SPEC 5.1). Under an advisory lock on the group; the body is one exception block, the task call another (s_stock_expense_task_v1).
create or replace function public.s_stock_expense_sync_v1(p_group text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_ref text := 'stock:' || p_group; v_is_draft boolean := p_group like 'draft:%'; v_cut timestamptz;
  v_prop uuid; v_n integer; v_priced integer; v_sum numeric; v_date date; v_first timestamptz; v_nsup integer; v_nblank integer; v_sup text;
  v_draft public.inventory_receipt_drafts%rowtype; v_row public.transactions%rowtype; v_tid uuid; v_owned boolean;
  v_names text[]; v_amt numeric; v_payee text; v_note text; v_status text; v_auto boolean; v_incomplete boolean; v_new uuid; v_total numeric; v_n2 integer; v_flip boolean;
begin
  if p_group is null or p_group = '' then return; end if;
  begin
    -- inside the block: a lock error (timeout, deadlock) opens the follow-up task instead of failing the stock write
    perform pg_advisory_xact_lock(hashtextextended('s134:stock:' || p_group, 0));
    select count(*),count(*) filter (where p.unit_cost > 0), round(coalesce(sum(p.qty * p.unit_cost) filter (where p.unit_cost > 0), 0), 2), min(p.purchased_at), min(p.created_at),
           count(distinct nullif(btrim(p.supplier), '')), count(*) filter (where nullif(btrim(p.supplier), '') is null), min(nullif(btrim(p.supplier), '')), (array_agg(i.property_id))[1]
      into v_n, v_priced, v_sum, v_date, v_first, v_nsup, v_nblank, v_sup, v_prop
      from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
     where p.expense_group = p_group;
    if v_is_draft and substr(p_group, 7) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      select * into v_draft from public.inventory_receipt_drafts d where d.id = substr(p_group, 7)::uuid;
    end if;

    -- the group's amount, needed by step 1 (a sync-voided row that is priced again) as well as by steps 3-5
    v_total := case when v_draft.total is not null and v_draft.total > 0 then round(v_draft.total, 2) end;
    v_amt := coalesce(v_total, v_sum);
    v_incomplete := v_amt > 0 and v_priced < v_n and v_total is null;
    v_payee := case when v_nsup = 1 then v_sup end;

    -- step 1: the group's row. A purchase's link, else stock:<group>, else the draft's own row (OCR path).
    v_tid := (select p.transaction_id from public.inventory_purchases p where p.expense_group = p_group and p.transaction_id is not null order by p.created_at, p.id limit 1);
    if v_tid is null and v_draft.id is not null then v_tid := v_draft.transaction_id; end if;
    -- the row is locked here (FOR UPDATE), before v_owned is read: an approval or edit that committed first is seen, one that comes later waits for this transaction
    if v_tid is not null then select * into v_row from public.transactions t where t.id = v_tid for update; end if;
    if v_row.id is null then
      select * into v_row from public.transactions t where t.external_ref = v_ref and t.txn_type = 'expense' order by (t.status <> 'void') desc, t.created_at desc, t.id limit 1 for update;
    end if;
    if v_row.id is null and v_draft.id is not null then
      select * into v_row from public.transactions t where t.txn_type = 'expense' and t.status <> 'void' and t.ocr_raw ->> 'draft_id' = v_draft.id::text order by t.created_at, t.id limit 1 for update;
    end if;
    -- a foreign or void row: link every purchase to it and stop (OCR and Telegram keep their one row; a voided "not a cost" row is never recreated)
    if v_row.id is not null and (v_row.external_ref is distinct from v_ref or v_row.status = 'void') then
      update public.inventory_purchases set transaction_id = v_row.id where expense_group = p_group and transaction_id is distinct from v_row.id;
      -- the group is priced again after its own stock row was voided (fix r3, item 1). A row the SYNC voided (its marker ends the note) is reopened as pending_review: a void row cannot be inserted over
      -- (uq_transactions_external_ref), and one live row per priced group is the invariant. A row a PERSON voided is never reopened: a follow-up task says the stock is priced again.
      if v_row.status = 'void' and v_row.external_ref = v_ref and v_n > 0 and v_amt > 0 then
        if v_row.source = 'inventory' and v_row.notes ~ '\[voided: stock receipt (undone|has no priced line left)\]$' then
          perform public.admin_audit_context_v1('stock sync', null, null);
          update public.transactions set status = 'pending_review', gross_amount = v_amt, transaction_date = v_date, payee_name = v_payee,
                 notes = nullif(btrim(regexp_replace(notes, '\s*\[voided: stock receipt (undone|has no priced line left)\]$', '')), ''),
                 ocr_raw = coalesce(ocr_raw, '{}'::jsonb) || jsonb_build_object('s134_auto', false, 's134_amount', v_amt, 's134_incomplete', v_incomplete),
                 updated_at = now()
           where id = v_row.id and status = 'void' and source = 'inventory' and external_ref like 'stock:%' and notes ~ '\[voided: stock receipt (undone|has no priced line left)\]$'
             and case when (ocr_raw ->> 's134_amount') ~ '^[0-9]+(\.[0-9]+)?$' then gross_amount = (ocr_raw ->> 's134_amount')::numeric else false end;
          get diagnostics v_n2 = row_count;
          perform public.admin_audit_context_v1('', null, null);
          if v_n2 = 0 then
            perform public.s_stock_expense_task_v1(v_row.property_id, 'repriced:' || p_group, 'Stock priced again after its expense was voided',
              'Expense ' || left(v_row.id::text, 8) || ' was voided and the stock now adds up to P' || v_amt || '. Check it in Expenses.');
          end if;
        elsif v_amt is distinct from v_row.gross_amount then
          perform public.s_stock_expense_task_v1(v_row.property_id, 'repriced:' || p_group, 'Stock priced again after its expense was voided',
            'Expense ' || left(v_row.id::text, 8) || ' was voided by a person (P' || v_row.gross_amount || ') but the stock now adds up to P' || v_amt || '. The expense was left voided.');
        end if;
      end if;
      return;
    end if;
    v_owned := v_row.id is not null and public.s_stock_expense_owned_v1(v_row.id);

    -- step 2: nothing left (an undo deleted the purchases)
    if v_n = 0 then
      if v_row.id is null then return; end if;
      if not (v_owned and public.s_txn_void_core_v1(v_row.id, 'stock receipt undone', null, true)) then
        -- not owned, or a person took the row between the read and the void (the void's own WHERE refused it): a task, never a silent void
        perform public.s_stock_expense_task_v1(v_row.property_id, 'undone:' || p_group, 'Stock receipt undone after its expense was approved', 'The stock for expense ' || left(v_row.id::text, 8) || ' was undone but the expense was already approved or edited. Check it in Expenses.');
      end if;
      return;
    end if;
    v_prop := coalesce(v_prop, v_row.property_id);

    -- step 3: values (v_total, v_amt, v_incomplete and v_payee are set above)
    select array_agg(x.name order by x.first_at, x.name) into v_names
      from (select i.name, min(p.created_at) first_at from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id where p.expense_group = p_group group by i.name) x;
    v_note := 'Stock bought: ' || array_to_string(v_names[1:3], ', ') || case when array_length(v_names, 1) > 3 then ' (+' || (array_length(v_names, 1) - 3) || ' more)' else '' end
              || case when v_nsup >= 2 then ' - Several suppliers' else '' end;

    if v_row.id is not null then
      -- step 5: recompute. The link first (idempotent), then a sync-owned row follows the purchases; a human-owned row is never changed.
      update public.inventory_purchases set transaction_id = v_row.id where expense_group = p_group and transaction_id is distinct from v_row.id;
      if v_draft.id is not null and v_draft.transaction_id is distinct from v_row.id then update public.inventory_receipt_drafts set transaction_id = v_row.id where id = v_draft.id; end if;
      if v_owned then
        if v_amt <= 0 then
          if not public.s_txn_void_core_v1(v_row.id, 'stock receipt has no priced line left', null, true) then
            perform public.s_stock_expense_task_v1(v_row.property_id, 'changed:' || p_group, 'Stock changed after its expense was approved',
              'Expense ' || left(v_row.id::text, 8) || ' was approved or edited while its last priced line was removed. The expense was left as it is.');
          end if;
        else
          -- the amount, date and payee follow the purchases; the note is NOT rewritten (a person may have edited it) and nothing depends on its text: the incomplete marker lives in ocr_raw.s134_incomplete,
          -- set on every pass. An owned row that turns incomplete and was auto-confirmed goes back to review.
          v_flip := v_incomplete and v_row.status = 'confirmed';
          if (v_row.gross_amount, v_row.transaction_date, v_row.payee_name) is distinct from (v_amt, v_date, v_payee) or v_flip
             or (v_row.ocr_raw ->> 's134_incomplete') is distinct from v_incomplete::text then
            perform public.admin_audit_context_v1('stock sync', null, null);
            -- the ownership rule is in the WHERE too: a row approved or edited since the lock above is left alone and a task opens instead
            update public.transactions set gross_amount = v_amt, transaction_date = v_date, payee_name = v_payee,
                   status = case when v_flip then 'pending_review' else status end,
                   ocr_raw = coalesce(ocr_raw, '{}'::jsonb) || jsonb_build_object('s134_amount', v_amt, 's134_incomplete', v_incomplete) || case when v_flip then jsonb_build_object('s134_auto', false) else '{}'::jsonb end,
                   updated_at = now()
             where id = v_row.id and status <> 'void' and source = 'inventory' and external_ref like 'stock:%' and (status = 'pending_review' or ocr_raw ->> 's134_auto' = 'true')
               and case when (ocr_raw ->> 's134_amount') ~ '^[0-9]+(\.[0-9]+)?$' then gross_amount = (ocr_raw ->> 's134_amount')::numeric else false end;
            get diagnostics v_n2 = row_count;
            perform public.admin_audit_context_v1('', null, null);
            if v_n2 = 0 then
              perform public.s_stock_expense_task_v1(v_row.property_id, 'changed:' || p_group, 'Stock changed after its expense was approved',
                'Expense ' || left(v_row.id::text, 8) || ' was approved or edited while the stock changed. The expense was left as it is.');
            end if;
          end if;
        end if;
      elsif v_amt is distinct from v_row.gross_amount then
        perform public.s_stock_expense_task_v1(v_row.property_id, 'changed:' || p_group, 'Stock changed after its expense was approved',
          'Expense ' || left(v_row.id::text, 8) || ' is P' || v_row.gross_amount || ' but the stock bought now adds up to P' || v_amt || '. The expense was left as it is.');
      end if;
      return;
    end if;

    -- step 4: create. No price at all = no row. A group older than the cut-over belongs to the back-fill.
    if v_amt is null or v_amt <= 0 then return; end if;
    v_cut := (select (s.value #>> '{}')::timestamptz from public.app_settings s where s.key = 's134_stock_expense_from');
    if v_cut is null or v_first < v_cut then return; end if;
    v_auto := false;
    if v_is_draft or v_incomplete then
      v_status := 'pending_review';
    elsif exists (select 1 from public.transactions o
                   where o.property_id = v_prop and o.txn_type = 'expense' and o.status <> 'void' and o.category in ('supplies', 'maintenance', 'repairs')
                     and o.source not in ('airbnb', 'airbnb_email') and abs(o.transaction_date - v_date) <= 3
                     and not exists (select 1 from public.inventory_purchases ip where ip.transaction_id = o.id)) then
      v_status := 'pending_review';
    else
      v_status := 'confirmed'; v_auto := true;
    end if;
    perform public.admin_audit_context_v1('stock sync', null, null);
    insert into public.transactions (property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, payee_name, notes, external_ref, logged_by, ocr_raw)
    values (v_prop, 'expense', 'supplies', v_status, 'inventory', v_date, v_amt, 'PHP', v_payee, v_note, v_ref, 'system',
            jsonb_build_object('s134_auto', v_auto, 's134_amount', v_amt, 's134_group', p_group, 's134_incomplete', v_incomplete))
    returning id into v_new;
    perform public.admin_audit_context_v1('', null, null);
    update public.inventory_purchases set transaction_id = v_new where expense_group = p_group and transaction_id is distinct from v_new;
    if v_draft.id is not null then update public.inventory_receipt_drafts set transaction_id = v_new where id = v_draft.id and transaction_id is null; end if;
  exception when others then
    raise warning 's134 stock sync failed for %: % (%)', p_group, sqlerrm, sqlstate;
    perform public.s_stock_expense_task_v1(coalesce(v_prop, (select t.property_id from public.transactions t where t.external_ref = v_ref limit 1)), 'failed:' || p_group, 'Stock receipt could not be filed as an expense',
      'The stock was saved, but its expense row could not be written (' || sqlerrm || '). Add it in Expenses.');
  end;
end $$;

-- 3g. the deferred constraint trigger's function: never raises
create or replace function public.s_stock_expense_trg_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_a text; v_b text;
begin
  begin
    if tg_op = 'DELETE' then v_a := old.expense_group; v_b := null;
    elsif tg_op = 'UPDATE' then v_a := new.expense_group; v_b := old.expense_group;
    else v_a := new.expense_group; v_b := null; end if;
    if v_a is not null then perform public.s_stock_expense_sync_v1(v_a); end if;
    if v_b is not null and v_b is distinct from v_a then perform public.s_stock_expense_sync_v1(v_b); end if;
  exception when others then
    raise warning 's134 stock trigger failed: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end $$;

drop trigger if exists s134_stock_expense_group on public.inventory_purchases;
create trigger s134_stock_expense_group before insert on public.inventory_purchases for each row execute function public.s_stock_expense_group_v1();
drop trigger if exists s134_stock_expense_sync on public.inventory_purchases;
create constraint trigger s134_stock_expense_sync after insert or delete or update of qty, unit_cost, purchased_at on public.inventory_purchases
  deferrable initially deferred for each row execute function public.s_stock_expense_trg_v1();

-- 3h. chip, mime
create or replace function public.s_expense_chip_v1(p_source text, p_has_stock boolean, p_has_receipt boolean)
returns text language sql immutable set search_path = '' as $$
  select case when p_source = 'bill' then 'bill' when p_source = 'cleaner_fee' then 'staff_pay' when p_source = 'refund' then 'refund'
              when p_source = 'inventory' or coalesce(p_has_stock, false) then 'stock' when p_source = 'telegram' then 'telegram'
              when p_source = 'ocr' or (p_source = 'manual' and coalesce(p_has_receipt, false)) then 'receipt' else 'manual' end
$$;
create or replace function public.s_expense_mime_v1(p_path text)
returns text language sql immutable set search_path = '' as $$
  select case lower(substring(coalesce(p_path, '') from '[.]([A-Za-z0-9]+)$')) when 'jpg' then 'image/jpeg' when 'jpeg' then 'image/jpeg' when 'png' then 'image/png' when 'webp' then 'image/webp' when 'pdf' then 'application/pdf' end
$$;

-- 3i. the receipt of a ledger row, first hit wins: txn (own pointer) > draft (the stock draft that holds this row) > bill (the bill's payment screenshot) > stock (a purchase's photo).
--     With p_check the bucket is chosen from the kind's own candidate list (R5): a candidate counts only when the path has that bucket's known shape AND the object exists in it. The bucket is never read from the path.
create or replace function public.s_expense_receipt_v1(p_id uuid, p_check boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare t public.transactions%rowtype; v_kind text; v_ref uuid; v_path text; v_bucket text; v_pre text; c record;
begin
  select * into t from public.transactions x where x.id = p_id;
  if not found then return null; end if;
  v_pre := t.property_id::text;
  if t.receipt_image_path is not null then
    v_kind := 'txn'; v_ref := t.id; v_path := t.receipt_image_path;
  else
    select d.id, d.receipt_path into v_ref, v_path from public.inventory_receipt_drafts d where d.transaction_id = t.id and d.receipt_path is not null and d.status <> 'cancelled' order by d.created_at, d.id limit 1;
    if v_path is not null then v_kind := 'draft';
    else
      if t.source = 'bill' then
        select b.id, b.proof_path into v_ref, v_path from public.utility_bills b
         where b.property_id = t.property_id and b.proof_path is not null and (b.txn_id = t.id or 'bill:' || b.kind || ':' || b.period = t.external_ref) order by b.created_at, b.id limit 1;
        if v_path is not null then v_kind := 'bill'; end if;
      end if;
      if v_path is null then
        select p.id, p.receipt_path into v_ref, v_path from public.inventory_purchases p where p.transaction_id = t.id and p.receipt_path is not null order by p.created_at, p.id limit 1;
        if v_path is not null then v_kind := 'stock'; end if;
      end if;
    end if;
  end if;
  if v_path is null then return null; end if;
  if not p_check then
    return jsonb_build_object('kind', v_kind, 'id', v_ref, 'mime', public.s_expense_mime_v1(v_path), 'path', v_path, 'bucket', null);
  end if;
  if char_length(v_path) <= 300 and position('..' in v_path) = 0 then
    for c in
      select * from (values
        ('txn',   'expense-receipts',  '^(' || v_pre || '|receipts)/[^/].*$'),
        ('draft', 'expense-receipts',  '^' || v_pre || '/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|png|webp|pdf)$'),
        ('draft', 'inventory-photos',  '^items/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|webp)$'),
        ('bill',  'cleaning-photos',   '^' || v_pre || '/[0-9a-f-]{36}/.+$'),
        ('stock', 'inventory-photos',  '^items/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|webp)$')
      ) m(kind, bucket, shape) where m.kind = v_kind
    loop
      if v_path ~ c.shape and exists (select 1 from storage.objects o where o.bucket_id = c.bucket and o.name = v_path) then v_bucket := c.bucket; exit; end if;
    end loop;
  end if;
  return jsonb_build_object('kind', v_kind, 'id', v_ref, 'mime', public.s_expense_mime_v1(v_path), 'path', case when v_bucket is not null then v_path end, 'bucket', v_bucket);
end $$;

-- 3j. the look-alike of a row (read time, both directions, confirmed rows included): same property, supplies / maintenance / repairs, within 3 days, exactly one of the two has linked
--     purchases; the nearest amount wins. A hint for a person, never an action.
create or replace function public.s_expense_lookalike_v1(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', c.id, 'date', c.transaction_date, 'amount', c.gross_amount,
                            'chip', public.s_expense_chip_v1(c.source, exists (select 1 from public.inventory_purchases p where p.transaction_id = c.id), public.s_expense_receipt_v1(c.id) is not null))
    from public.transactions r
    cross join lateral (
      select o.* from public.transactions o
       where o.property_id = r.property_id and o.id <> r.id and o.txn_type = 'expense' and o.status <> 'void' and o.source not in ('airbnb', 'airbnb_email')
         and o.category in ('supplies', 'maintenance', 'repairs') and abs(o.transaction_date - r.transaction_date) <= 3
         and exists (select 1 from public.inventory_purchases p where p.transaction_id = o.id) <> exists (select 1 from public.inventory_purchases p where p.transaction_id = r.id)
       order by abs(o.gross_amount - r.gross_amount), o.created_at, o.id limit 1) c
   where r.id = p_id and r.txn_type = 'expense' and r.status <> 'void' and r.category in ('supplies', 'maintenance', 'repairs')
$$;

-- 3k. the receipt gate shared by expense_receipt_set_v1 and admin_save_transaction_v2 (create): the path rule, the upload proof, the open-draft rule, the duplicate rule. Locks the path and the sha so two
--     sessions attaching one file to two rows serialise (R6). Answers {ok:true, sha256, mime} or {ok:false, error, ...}; never raises for a refusal.
create or replace function public.s_expense_receipt_gate_v1(p_prop uuid, p_path text, p_self uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_sha text; v_dup record; v_where text;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  if p_path is null or char_length(p_path) > 300 or position('..' in p_path) > 0
     or p_path !~ ('^' || p_prop::text || '/' || v_uid::text || '/[0-9a-f-]{36}[.](jpg|png|webp|pdf)$') then
    return jsonb_build_object('ok', false, 'error', 'bad_path');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('s134:receipt-path:' || p_path, 0));
  if not exists (select 1 from storage.objects o where o.bucket_id = 'expense-receipts' and o.name = p_path) then return jsonb_build_object('ok', false, 'error', 'no_file'); end if;
  select h.sha256 into v_sha from public.staff_upload_hashes h where h.path = p_path and h.uploaded_by = v_uid and h.created_at > now() - interval '24 hours';
  if v_sha is null then return jsonb_build_object('ok', false, 'error', 'no_upload_record'); end if;
  perform pg_advisory_xact_lock(hashtextextended('s134:receipt-sha:' || v_sha, 0));
  if exists (select 1 from public.inventory_receipt_drafts d where d.receipt_path = p_path and d.status <> 'cancelled') then
    return jsonb_build_object('ok', false, 'error', 'receipt_in_use', 'where', 'Inventory');
  end if;
  select t.id, t.transaction_date into v_dup from public.transactions t
   where t.property_id = p_prop and t.status <> 'void' and t.id is distinct from p_self and (t.receipt_image_path = p_path or t.ocr_raw ->> 'receipt_sha256' = v_sha) order by t.created_at, t.id limit 1;
  if found then return jsonb_build_object('ok', false, 'error', 'duplicate_receipt', 'id', v_dup.id, 'ref', left(v_dup.id::text, 8)); end if;
  if exists (select 1 from public.utility_bills b where b.property_id = p_prop and lower(b.proof_sha256) = v_sha) then v_where := 'Bills';
  elsif exists (select 1 from public.staff_pay_requests q where q.property_id = p_prop and lower(q.proof_sha256) = v_sha) then v_where := 'Pay staff'; end if;
  if v_where is not null then return jsonb_build_object('ok', false, 'error', 'duplicate_receipt', 'where', v_where); end if;
  return jsonb_build_object('ok', true, 'sha256', v_sha, 'mime', public.s_expense_mime_v1(p_path));
end $$;

-- 3l. the bucket statement (R4), as a function so the test can run it on fixture buckets
create or replace function public.s_expense_bucket_pdf_v1(p_bucket text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_limit bigint;
begin
  select b.file_size_limit into v_limit from storage.buckets b where b.id = p_bucket;
  if v_limit is not null and v_limit < 5242880 then
    raise exception 's134: bucket % has file_size_limit % (under 5 MB): raise it before releasing PDF receipts', p_bucket, v_limit using errcode = '55000';
  end if;
  update storage.buckets set allowed_mime_types = allowed_mime_types || array['application/pdf']::text[]
   where id = p_bucket and allowed_mime_types is not null and not ('application/pdf' = any (allowed_mime_types));
end $$;
select public.s_expense_bucket_pdf_v1('expense-receipts');

-- 3m. KPI: what the ledger adds to admin (SPEC 6). costs_pending_month and cleaning_pay_open always; supplies_month and cleaning_pay_month from the cut-over month on (they override the s127 keys).
create or replace function public.kpi_admin_costs_v1(p_property_id uuid, p_m0 date, p_m1 date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cut timestamptz; v_cm date; v_pc integer; v_pt numeric; v_open numeric; v_ledger boolean; v_out jsonb;
begin
  v_cut := (select (s.value #>> '{}')::timestamptz from public.app_settings s where s.key = 's134_stock_expense_from');
  v_cm := case when v_cut is not null then date_trunc('month', v_cut at time zone 'Asia/Manila')::date end;
  v_ledger := v_cm is not null and p_m0 >= v_cm;
  select count(*), coalesce(sum(t.gross_amount), 0) into v_pc, v_pt from public.transactions t
   where t.property_id = p_property_id and t.txn_type = 'expense' and t.status = 'pending_review' and t.source not in ('airbnb', 'airbnb_email') and t.transaction_date >= p_m0 and t.transaction_date < p_m1;
  select coalesce(sum(q.total_amount), 0) into v_open from public.staff_pay_requests q
   where q.property_id = p_property_id and q.status in ('requested', 'paying') and (q.created_at at time zone 'Asia/Manila')::date < p_m1;
  v_out := jsonb_build_object('costs_pending_month', jsonb_build_object('count', v_pc, 'total', v_pt), 'cleaning_pay_open', v_open, 'kpi_source', case when v_ledger then 'ledger' else 'legacy' end,
                                'kpi_ledger_from', to_char(v_cm, 'YYYY-MM'));
  if v_ledger then
    v_out := v_out || jsonb_build_object(
      'supplies_month', (select coalesce(sum(t.gross_amount), 0) from public.transactions t where t.property_id = p_property_id and t.txn_type = 'expense' and t.status = 'confirmed'
                            and t.source not in ('airbnb', 'airbnb_email') and t.category = 'supplies' and t.transaction_date >= p_m0 and t.transaction_date < p_m1),
      'cleaning_pay_month', (select coalesce(sum(t.gross_amount), 0) from public.transactions t where t.property_id = p_property_id and t.txn_type = 'expense' and t.status = 'confirmed'
                            and t.source not in ('airbnb', 'airbnb_email') and t.category = 'cleaning' and t.transaction_date >= p_m0 and t.transaction_date < p_m1));
  end if;
  return v_out;
end $$;

-- 4. kpi_tab_v1: ONE anchored replace inside `if v_fin` (never after end if: jsonb_set is strict and would null the payload for cleaners, inspectors and laundry) -----------------------------------------------------------
do $k$
declare v_src text; v_new text; v_anchor text; v_add text; v_n integer;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.kpi_tab_v1(uuid,date)');
  if md5(v_src) = '7c6d5a22d09ad96916804630f31df602' then raise notice 's134: kpi_tab_v1 already carries this change'; return; end if;
  if md5(v_src) <> '80efd89e916bcd6107c681baf86f143f' then raise exception 's134: kpi_tab_v1 is not the s127 body (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_anchor := '    v_out := jsonb_set(v_out, ''{admin}'', (v_out -> ''admin'') || public.kpi_admin_bills_v1(p_property_id, v_rate.php_per_kwh));';
  v_add := E'\n    -- s134: costs_pending_month, cleaning_pay_open, kpi_source; supplies_month / cleaning_pay_month from the ledger from the cut-over month on (read_finance only, inside if v_fin)\n'
           || '    v_out := jsonb_set(v_out, ''{admin}'', (v_out -> ''admin'') || public.kpi_admin_costs_v1(p_property_id, v_m0, v_m1));';
  v_n := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then raise exception 's134: the kpi_tab_v1 anchor matches % times (expected 1)', v_n using errcode = '55000'; end if;
  v_new := replace(v_src, v_anchor, v_anchor || v_add);
  if md5(v_new) <> '7c6d5a22d09ad96916804630f31df602' then raise exception 's134: kpi_tab_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.kpi_tab_v1(p_property_id uuid, p_month date default null)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
end $k$;
revoke all on function public.kpi_tab_v1(uuid, date) from public, anon, service_role;
grant execute on function public.kpi_tab_v1(uuid, date) to authenticated;

-- 5. client RPCs ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 5a. the screen. Paging: (created_at desc, id desc); p_before + p_before_id continue after that exact row (rows sharing one created_at are never skipped or repeated), p_before alone keeps the old meaning (created_at < p_before).
drop function if exists public.expenses_screen_v1(uuid, date, integer, timestamptz, text);
create or replace function public.expenses_screen_v1(p_property_id uuid, p_month date default null, p_limit integer default 100, p_before timestamptz default null, p_filter text default null, p_before_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_m0 date; v_m1 date; v_fs jsonb; v_lim integer := least(greatest(coalesce(p_limit, 100), 0), 200); v_cut timestamptz; v_rows jsonb; v_more boolean := false;
  v_basis numeric; v_bm integer; v_pend jsonb; v_pend_all jsonb; v_unp jsonb; v_unl integer; v_cats jsonb; v_cnt integer; v_flt text := nullif(btrim(coalesce(p_filter, '')), '');
begin
  if auth.uid() is null or not public.current_staff_authorized('read_finance', p_property_id) then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  v_m0 := date_trunc('month', coalesce(p_month, public.manila_today()))::date;
  v_m1 := (v_m0 + interval '1 month')::date;
  v_fs := public.get_finance_summary(v_m0, p_property_id);
  select round(avg(x.e), 2), count(*) into v_basis, v_bm
    from (select (public.get_finance_summary((v_m0 - (k * interval '1 month'))::date, p_property_id) ->> 'expenses')::numeric e from generate_series(1, 3) k) x where x.e > 0;
  select count(*) into v_cnt from public.transactions t where t.property_id = p_property_id and t.txn_type = 'expense' and t.status = 'confirmed' and t.source not in ('airbnb', 'airbnb_email')
     and t.transaction_date >= v_m0 and t.transaction_date < v_m1;
  select jsonb_build_object('count', count(*), 'total', coalesce(sum(t.gross_amount), 0)) into v_pend from public.transactions t
   where t.property_id = p_property_id and t.txn_type = 'expense' and t.status = 'pending_review' and t.source not in ('airbnb', 'airbnb_email') and t.transaction_date >= v_m0 and t.transaction_date < v_m1;
  select jsonb_build_object('count', count(*), 'total', coalesce(sum(t.gross_amount), 0)) into v_pend_all from public.transactions t
   where t.property_id = p_property_id and t.txn_type = 'expense' and t.status = 'pending_review' and t.source not in ('airbnb', 'airbnb_email');
  v_cut := (select (s.value #>> '{}')::timestamptz from public.app_settings s where s.key = 's134_stock_expense_from');

  if v_lim > 0 then
    with base as (
      select t.*, public.s_expense_receipt_v1(t.id) rc,
             exists (select 1 from public.inventory_purchases ip where ip.transaction_id = t.id) has_stock,
             t.source in ('bill', 'cleaner_fee', 'refund', 'direct_booking', 'airbnb', 'airbnb_email', 'airbnb_payout_email') locked
        from public.transactions t
       where t.property_id = p_property_id and t.txn_type = 'expense' and t.status in ('confirmed', 'pending_review') and t.source not in ('airbnb', 'airbnb_email')
         and t.transaction_date >= v_m0 and t.transaction_date < v_m1 and (p_before is null or (case when p_before_id is null then t.created_at < p_before else (t.created_at, t.id) < (p_before, p_before_id) end))
    ), chipped as (
      select b.*, public.s_expense_chip_v1(b.source, b.has_stock, b.rc is not null) chip from base b
    ), picked as (
      select c.* from chipped c
       where v_flt is null or v_flt = 'all' or (v_flt = 'review' and c.status = 'pending_review') or (v_flt like 'cat:%' and c.category = substr(v_flt, 5)) or c.chip = v_flt
       order by c.created_at desc, c.id desc limit v_lim + 1
    ), numbered as (
      select p.*, row_number() over (order by p.created_at desc, p.id desc) rn, public.s_expense_lookalike_v1(p.id) lk from picked p
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', n.id, 'date', n.transaction_date, 'amount', n.gross_amount, 'category', n.category,
             'label', coalesce(ec.label, initcap(replace(n.category, '_', ' '))), 'payee', n.payee_name, 'notes', n.notes, 'status', n.status, 'chip', n.chip, 'source', n.source,
             'hidden', n.hidden_at is not null,
             'has_receipt', n.rc is not null,
             'receipt_ref', case when n.rc is null then null else jsonb_build_object('kind', n.rc ->> 'kind', 'id', n.rc ->> 'id', 'mime', n.rc ->> 'mime') end,
             'receipt_can', jsonb_build_object(
                 'add', (not n.locked and n.source in ('manual', 'telegram', 'ocr', 'inventory') and n.rc is null),
                 'replace', (not n.locked and n.source in ('manual', 'telegram', 'ocr', 'inventory') and n.rc ->> 'kind' = 'txn'),
                 'remove', (not n.locked and n.source in ('manual', 'telegram', 'ocr', 'inventory') and n.rc ->> 'kind' = 'txn')),
             'locked', n.locked,
             'amount_locked', (n.locked or (n.has_stock and public.s_stock_expense_owned_v1(n.id))),
             'stock', case when n.has_stock then (select jsonb_build_object('lines', count(*), 'items', count(distinct ip.item_id)) from public.inventory_purchases ip where ip.transaction_id = n.id) end,
             'lookalike_id', n.lk ->> 'id', 'lookalike', n.lk,
             's134_incomplete', coalesce((n.ocr_raw ->> 's134_incomplete') = 'true', false),
             'created_at', n.created_at) order by n.rn), '[]'::jsonb),
           coalesce(bool_or(n.rn > v_lim), false)
      into v_rows, v_more
      from numbered n left join public.expense_categories ec on ec.property_id = p_property_id and ec.slug = n.category
     where n.rn <= v_lim or true;
    -- the +1 row only proves there is more: drop it
    if v_more then v_rows := (select coalesce(jsonb_agg(e.value order by e.ord), '[]'::jsonb) from jsonb_array_elements(v_rows) with ordinality e(value, ord) where e.ord <= v_lim); end if;
  else
    v_rows := '[]'::jsonb;
  end if;

  -- purchases with no price (no priced line, no draft total, no ledger row) whose receipt falls in the month
  with g as (
    select p.expense_group, min(p.purchased_at) d, (array_agg(i.name order by p.created_at, p.id))[1] name, (array_agg(p.item_id order by p.created_at, p.id))[1] item_id
      from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
     where i.property_id = p_property_id and p.expense_group is not null and p.purchased_at >= v_m0 and p.purchased_at < v_m1
     group by p.expense_group
    having count(*) filter (where p.unit_cost > 0) = 0 and bool_and(p.transaction_id is null)
       and not exists (select 1 from public.inventory_receipt_drafts dr where p.expense_group like 'draft:%' and dr.id::text = substr(p.expense_group, 7) and dr.total > 0)
  )
  select jsonb_build_object('count', (select count(*) from g),
                            'items', coalesce((select jsonb_agg(jsonb_build_object('item_id', x.item_id, 'name', x.name, 'date', x.d) order by x.d desc, x.name) from (select * from g order by d desc, name limit 20) x), '[]'::jsonb))
    into v_unp;
  select count(*) into v_unl from public.inventory_purchases p join public.inventory_items i on i.id = p.item_id
   where i.property_id = p_property_id and v_cut is not null and p.created_at >= v_cut and p.unit_cost > 0 and p.transaction_id is null;
  select coalesce(jsonb_agg(jsonb_build_object('slug', c.slug, 'label', c.label) order by c.sort_order, c.label), '[]'::jsonb) into v_cats
    from public.expense_categories c where c.property_id = p_property_id and c.is_active and c.slug not in ('guest_refund', 'airbnb_adjustment');

  return jsonb_build_object('ok', true, 'month', v_m0, 'total', (v_fs ->> 'expenses')::numeric, 'count', v_cnt,
    'prev_total', (public.get_finance_summary((v_m0 - interval '1 month')::date, p_property_id) ->> 'expenses')::numeric,
    'basis', v_basis, 'basis_months', v_bm, 'pending', v_pend, 'pending_all', v_pend_all,
    'by_category', coalesce((select jsonb_agg(e.value) from jsonb_array_elements(v_fs -> 'by_category') e where e.value ->> 'txn_type' = 'expense'), '[]'::jsonb),
    'rows', v_rows, 'unpriced', v_unp, 'unlinked', v_unl, 'categories', v_cats,
    'can_write', public.current_staff_authorized('approve_payment', p_property_id), 'more', v_more);
end $$;

-- 5b. save (create / edit). Refusals are {ok:false, error, ...}; only the gate raises (42501).
create or replace function public.admin_save_transaction_v2(p_property_id uuid, p_txn jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid; v_row public.transactions%rowtype; v_type text; v_amount numeric; v_date date; v_ref text; v_reason text; v_cat text; v_receipt text; v_conf numeric; v_raw jsonb;
  v_gate jsonb; v_status text; v_where text; v_locked boolean;
  c_system constant text[] := array['guest_refund', 'airbnb_adjustment'];
begin
  perform public.admin_require('approve_payment', p_property_id);
  if p_txn is null or jsonb_typeof(p_txn) <> 'object' then return jsonb_build_object('ok', false, 'error', 'bad_request'); end if;
  begin
    v_amount := nullif(p_txn ->> 'gross_amount', '')::numeric;
    v_date := nullif(p_txn ->> 'transaction_date', '')::date;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end;
  if nullif(p_txn ->> 'id', '') is not null then
    v_id := public.try_uuid(p_txn ->> 'id');
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'bad_request'); end if;
  end if;
  v_type := coalesce(nullif(p_txn ->> 'txn_type', ''), 'expense');
  if v_type not in ('income', 'expense', 'drawing') then return jsonb_build_object('ok', false, 'error', 'bad_type'); end if;
  v_reason := nullif(btrim(coalesce(p_txn ->> 'reason', '')), '');
  v_cat := nullif(btrim(coalesce(p_txn ->> 'category', '')), '');

  if v_id is null then
    -- create ------------------------------------------------------------------------------------------------------------------------------------------------
    if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then return jsonb_build_object('ok', false, 'error', 'key_required'); end if;
    perform pg_advisory_xact_lock(hashtextextended('s134:save:' || p_property_id::text || ':' || p_idempotency_key, 0));
    v_ref := 'admin:' || p_idempotency_key;
    select * into v_row from public.transactions where property_id = p_property_id and external_ref = v_ref;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'replayed', true); end if;
    if v_date is null then return jsonb_build_object('ok', false, 'error', 'date_required'); end if;
    if v_type = 'expense' then
      if v_cat is null then return jsonb_build_object('ok', false, 'error', 'category_required'); end if;
      if v_cat = any (c_system) then return jsonb_build_object('ok', false, 'error', 'system_category'); end if;
      if not exists (select 1 from public.expense_categories c where c.property_id = p_property_id and c.slug = v_cat and c.is_active) then return jsonb_build_object('ok', false, 'error', 'bad_category'); end if;
      if v_amount is null or v_amount <= 0 then return jsonb_build_object('ok', false, 'error', 'bad_amount'); end if;
      if v_date > public.manila_today() + 1 then return jsonb_build_object('ok', false, 'error', 'future_date'); end if;
    elsif v_amount is null or v_amount < 0 then
      return jsonb_build_object('ok', false, 'error', 'bad_amount');
    end if;
    v_status := coalesce(nullif(p_txn ->> 'status', ''), 'confirmed');
    if v_status not in ('confirmed', 'pending_review') then return jsonb_build_object('ok', false, 'error', 'status_not_allowed'); end if;
    v_receipt := nullif(btrim(coalesce(p_txn ->> 'receipt_image_path', '')), '');
    if v_receipt is not null then
      v_gate := public.s_expense_receipt_gate_v1(p_property_id, v_receipt, null);
      if (v_gate ->> 'ok')::boolean is not true then return v_gate; end if;
      if nullif(p_txn ->> 'ocr_confidence', '') is not null then
        begin v_conf := (p_txn ->> 'ocr_confidence')::numeric; exception when others then return jsonb_build_object('ok', false, 'error', 'bad_confidence'); end;
        if v_conf < 0 or v_conf > 1 then return jsonb_build_object('ok', false, 'error', 'bad_confidence'); end if;
      end if;
      v_raw := '{}'::jsonb;
      if p_txn ? 'ocr_raw' and jsonb_typeof(p_txn -> 'ocr_raw') = 'object' then
        if char_length((p_txn -> 'ocr_raw')::text) > 20000 then return jsonb_build_object('ok', false, 'error', 'ocr_raw_too_large'); end if;
        v_raw := (p_txn -> 'ocr_raw') - 'receipt_sha256' - 'receipt_mime' - 's134_auto' - 's134_amount' - 's134_group' - 's134_backfill' - 's134_incomplete' - 'draft_id' - 'source';
      end if;
      v_raw := v_raw || jsonb_build_object('receipt_sha256', v_gate ->> 'sha256', 'receipt_mime', v_gate ->> 'mime');
    end if;
    perform public.admin_audit_context_v1(coalesce(v_reason, 'created in admin'), null, null);
    insert into public.transactions(property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, or_number, payee_name, notes, external_ref, income_stage, reservation_id, booking_id, logged_by, receipt_image_path, ocr_confidence, ocr_raw)
    values (p_property_id, v_type, coalesce(v_cat, case v_type when 'drawing' then 'owner_drawing' else 'other' end), v_status, 'manual', v_date, v_amount, 'PHP',
            nullif(p_txn ->> 'or_number', ''), nullif(p_txn ->> 'payee_name', ''), nullif(p_txn ->> 'notes', ''), v_ref, case when v_type = 'income' then 'confirmed' end,
            public.try_uuid(p_txn ->> 'reservation_id'), public.try_uuid(p_txn ->> 'booking_id'), 'admin', v_receipt, case when v_receipt is not null then v_conf end, v_raw)
    returning * into v_row;
    return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status,
                              'auditId', (select a.id from public.admin_audit_log a where a.entity_table = 'transactions' and a.entity_id = v_row.id order by a.created_at desc limit 1),
                              'lookalike', public.s_expense_lookalike_v1(v_row.id));
  end if;

  -- edit ------------------------------------------------------------------------------------------------------------------------------------------------------
  select * into v_row from public.transactions where id = v_id and property_id = p_property_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_row.status = 'void' then return jsonb_build_object('ok', false, 'error', 'void'); end if;
  if p_txn ? 'receipt_image_path' or p_txn ? 'ocr_raw' or p_txn ? 'ocr_confidence' then return jsonb_build_object('ok', false, 'error', 'use_receipt_control'); end if;
  if v_reason is null then return jsonb_build_object('ok', false, 'error', 'reason_required'); end if;
  if p_txn ? 'txn_type' and v_type is distinct from v_row.txn_type then return jsonb_build_object('ok', false, 'error', 'type_locked'); end if;
  v_locked := v_row.source in ('bill', 'cleaner_fee', 'refund', 'direct_booking', 'airbnb', 'airbnb_email', 'airbnb_payout_email');
  v_where := case v_row.source when 'bill' then 'Bills' when 'cleaner_fee' then 'Pay staff' end;
  if p_txn ? 'status' and p_txn ->> 'status' is distinct from v_row.status then
    return case when v_locked then jsonb_build_object('ok', false, 'error', 'locked', 'where', v_where) else jsonb_build_object('ok', false, 'error', 'status_not_allowed') end;
  end if;
  if v_locked and ((p_txn ? 'gross_amount' and v_amount is distinct from v_row.gross_amount)
                or (p_txn ? 'transaction_date' and v_date is distinct from v_row.transaction_date)
                or (p_txn ? 'payee_name' and nullif(p_txn ->> 'payee_name', '') is distinct from v_row.payee_name)
                or (p_txn ? 'or_number' and nullif(p_txn ->> 'or_number', '') is distinct from v_row.or_number)
                or (p_txn ? 'reservation_id' and public.try_uuid(p_txn ->> 'reservation_id') is distinct from v_row.reservation_id)
                -- a staff pay row keeps its category: the cleaning-pay month figure and the V19 reconciliation read category 'cleaning'
                or (v_row.source = 'cleaner_fee' and v_cat is not null and v_cat is distinct from v_row.category)) then
    return jsonb_build_object('ok', false, 'error', 'locked', 'where', v_where);
  end if;
  if v_row.txn_type = 'expense' then
    if v_cat is not null and v_cat is distinct from v_row.category then
      if v_cat = any (c_system) then return jsonb_build_object('ok', false, 'error', 'system_category'); end if;
      if not exists (select 1 from public.expense_categories c where c.property_id = p_property_id and c.slug = v_cat and c.is_active) then return jsonb_build_object('ok', false, 'error', 'bad_category'); end if;
    end if;
    if p_txn ? 'gross_amount' and (v_amount is null or v_amount <= 0) then return jsonb_build_object('ok', false, 'error', 'bad_amount'); end if;
    if p_txn ? 'transaction_date' and (v_date is null or (v_date is distinct from v_row.transaction_date and v_date > public.manila_today() + 1)) then
      return jsonb_build_object('ok', false, 'error', case when v_date is null then 'date_required' else 'future_date' end);
    end if;
    -- a sync-owned stock row with linked purchases: the purchases decide amount, date and payee (the sync rewrites them); a person may change the category and the note only
    if ((p_txn ? 'gross_amount' and v_amount is distinct from v_row.gross_amount)
        or (p_txn ? 'transaction_date' and v_date is distinct from v_row.transaction_date)
        or (p_txn ? 'payee_name' and nullif(p_txn ->> 'payee_name', '') is distinct from v_row.payee_name)
        or (p_txn ? 'or_number' and nullif(p_txn ->> 'or_number', '') is distinct from v_row.or_number)
        or (p_txn ? 'reservation_id' and public.try_uuid(p_txn ->> 'reservation_id') is distinct from v_row.reservation_id))
       and public.s_stock_expense_owned_v1(v_row.id)
       and exists (select 1 from public.inventory_purchases ip where ip.transaction_id = v_row.id) then
      return jsonb_build_object('ok', false, 'error', 'amount_locked', 'where', 'Inventory');
    end if;
  end if;
  perform public.admin_audit_context_v1(v_reason, null, null);
  update public.transactions set
    category = coalesce(v_cat, category),
    transaction_date = coalesce(v_date, transaction_date),
    gross_amount = coalesce(v_amount, gross_amount),
    or_number = case when p_txn ? 'or_number' then nullif(p_txn ->> 'or_number', '') else or_number end,
    payee_name = case when p_txn ? 'payee_name' then nullif(p_txn ->> 'payee_name', '') else payee_name end,
    notes = case when p_txn ? 'notes' then nullif(p_txn ->> 'notes', '') else notes end,
    reservation_id = case when p_txn ? 'reservation_id' then public.try_uuid(p_txn ->> 'reservation_id') else reservation_id end,
    updated_at = now()
  where id = v_id returning * into v_row;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status,
                            'auditId', (select a.id from public.admin_audit_log a where a.entity_table = 'transactions' and a.entity_id = v_row.id order by a.created_at desc limit 1));
end $$;

-- 5c. void
create or replace function public.expense_void_v1(p_property_id uuid, p_id uuid, p_reason text, p_same_as uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row public.transactions%rowtype; v_reason text := btrim(coalesce(p_reason, '')); v_target public.transactions%rowtype; v_where text; v_marker text;
begin
  perform public.admin_require('approve_payment', p_property_id);
  if char_length(v_reason) < 3 then return jsonb_build_object('ok', false, 'error', 'reason_required'); end if;
  select * into v_row from public.transactions where id = p_id and property_id = p_property_id and txn_type = 'expense' for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_row.status = 'void' then return jsonb_build_object('ok', false, 'error', 'void'); end if;
  if v_row.source in ('bill', 'cleaner_fee', 'refund', 'direct_booking', 'airbnb', 'airbnb_email', 'airbnb_payout_email') then
    v_where := case v_row.source when 'bill' then 'Bills' when 'cleaner_fee' then 'Pay staff' end;
    return jsonb_build_object('ok', false, 'error', 'locked', 'where', v_where);
  end if;
  if p_same_as is not null then
    select * into v_target from public.transactions where id = p_same_as and property_id = p_property_id and txn_type = 'expense' and status <> 'void' and id <> p_id;
    if not found then return jsonb_build_object('ok', false, 'error', 'bad_same_as'); end if;
    v_marker := 'duplicate of ' || left(v_target.id::text, 8);
    update public.inventory_purchases set transaction_id = v_target.id where transaction_id = p_id;
  end if;
  perform public.s_txn_void_core_v1(p_id, v_reason, v_marker);
  return jsonb_build_object('ok', true, 'id', p_id, 'status', 'void',
                            'auditId', (select a.id from public.admin_audit_log a where a.entity_table = 'transactions' and a.entity_id = p_id order by a.created_at desc limit 1));
end $$;

-- 5d. receipts: where each row's file lives (read_finance). Bucket and path come from here only; a path is returned only when it has its bucket's known shape and the object exists there.
create or replace function public.expense_receipt_paths_v1(p_property_id uuid, p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.current_staff_authorized('read_finance', p_property_id) then return '[]'::jsonb; end if;
  if p_ids is null then return '[]'::jsonb; end if;
  if cardinality(p_ids) > 20 then raise exception using errcode = '22023', message = 'at most 20 ids'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'kind', r.v ->> 'kind', 'bucket', r.v ->> 'bucket', 'path', r.v ->> 'path', 'mime', r.v ->> 'mime') order by t.created_at, t.id)
                     from (select distinct x from unnest(p_ids) x) u
                     join public.transactions t on t.id = u.x and t.property_id = p_property_id and t.txn_type = 'expense'
                     cross join lateral (select public.s_expense_receipt_v1(t.id, true) v) r
                    where r.v ->> 'path' is not null and r.v ->> 'bucket' is not null), '[]'::jsonb);
end $$;

-- 5e. receipts: add / replace / remove one receipt on an expense row. Writes the pointer, ocr_confidence (null) and the two receipt keys of ocr_raw; never amount, date, payee, category, status or s134_auto.
create or replace function public.expense_receipt_set_v1(p_property_id uuid, p_id uuid, p_path text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_row public.transactions%rowtype; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_cur jsonb; v_gate jsonb; v_raw jsonb; v_where text; v_new jsonb;
  v_keep constant text[] := array['s134_auto', 's134_amount', 's134_group', 's134_backfill', 's134_incomplete', 'draft_id', 'source'];
begin
  perform public.admin_require('approve_payment', p_property_id);
  if p_path is null and (v_reason is null or char_length(v_reason) not between 3 and 200) then return jsonb_build_object('ok', false, 'error', 'reason_required'); end if;
  if v_reason is not null and char_length(v_reason) > 200 then return jsonb_build_object('ok', false, 'error', 'reason_required'); end if;
  select * into v_row from public.transactions where id = p_id and property_id = p_property_id and txn_type = 'expense' for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_row.status = 'void' then return jsonb_build_object('ok', false, 'error', 'void'); end if;
  if v_row.source in ('bill', 'cleaner_fee', 'refund', 'direct_booking', 'airbnb', 'airbnb_email', 'airbnb_payout_email') or v_row.source not in ('manual', 'telegram', 'ocr', 'inventory') then
    v_where := case v_row.source when 'bill' then 'Bills' when 'cleaner_fee' then 'Pay staff' end;
    return jsonb_build_object('ok', false, 'error', 'locked', 'where', v_where);
  end if;
  v_cur := public.s_expense_receipt_v1(v_row.id);
  if v_cur is not null and v_cur ->> 'kind' in ('draft', 'stock') then return jsonb_build_object('ok', false, 'error', 'locked', 'where', 'Inventory'); end if;
  if p_path is null then
    if v_row.receipt_image_path is null then return jsonb_build_object('ok', true, 'id', v_row.id, 'has_receipt', false, 'receipt_ref', null); end if;
  else
    if v_row.receipt_image_path = p_path then
      return jsonb_build_object('ok', true, 'id', v_row.id, 'has_receipt', true, 'receipt_ref', jsonb_build_object('kind', 'txn', 'id', v_row.id, 'mime', public.s_expense_mime_v1(p_path)));
    end if;
    v_gate := public.s_expense_receipt_gate_v1(p_property_id, p_path, v_row.id);
    if (v_gate ->> 'ok')::boolean is not true then return v_gate; end if;
  end if;
  -- keep only the system keys of the old ocr_raw (the model read goes with the old file), add the new file's sha and type
  select coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) into v_raw from jsonb_each(coalesce(v_row.ocr_raw, '{}'::jsonb)) e where e.key = any (v_keep);
  if p_path is not null then v_raw := v_raw || jsonb_build_object('receipt_sha256', v_gate ->> 'sha256', 'receipt_mime', v_gate ->> 'mime'); end if;
  perform public.admin_audit_context_v1(coalesce(v_reason, case when v_row.receipt_image_path is null then 'receipt added' else 'receipt replaced' end), null, null);
  update public.transactions set receipt_image_path = p_path, ocr_confidence = null, ocr_raw = case when v_raw = '{}'::jsonb then null else v_raw end, updated_at = now() where id = v_row.id;
  v_new := public.s_expense_receipt_v1(v_row.id);
  return jsonb_build_object('ok', true, 'id', v_row.id, 'has_receipt', v_new is not null,
                            'receipt_ref', case when v_new is null then null else jsonb_build_object('kind', v_new ->> 'kind', 'id', v_new ->> 'id', 'mime', v_new ->> 'mime') end);
end $$;

-- 6. Telegram RPCs (service_role only) -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.telegram_expense_save_v1(p_property_id uuid, p_txn jsonb, p_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_row public.transactions%rowtype; v_amount numeric; v_date date; v_cat text; v_status text; v_src text; v_path text; v_raw jsonb; v_conf numeric;
begin
  if p_txn is null or jsonb_typeof(p_txn) <> 'object' then return jsonb_build_object('ok', false, 'error', 'bad_request'); end if;
  if p_key is null or char_length(p_key) not between 3 and 200 then return jsonb_build_object('ok', false, 'error', 'key_required'); end if;
  -- the keys the Telegram edge function writes: tg:<chat>:<message>, tgp:<pending id>, tgocr:<object path>[#again]. Another prefix (admin:, stock:, bill:...) could collide with a ledger key of another path.
  if p_key !~ '^(tg|tgp|tgocr):' then return jsonb_build_object('ok', false, 'error', 'bad_request'); end if;
  perform pg_advisory_xact_lock(hashtextextended('s134:tgsave:' || p_property_id::text || ':' || p_key, 0));
  select * into v_row from public.transactions where property_id = p_property_id and external_ref = p_key;
  if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'replayed', true, 'lookalike', public.s_expense_lookalike_v1(v_row.id)); end if;
  begin
    v_amount := coalesce(nullif(p_txn ->> 'amount', ''), nullif(p_txn ->> 'gross_amount', ''))::numeric;
    v_date := coalesce(nullif(p_txn ->> 'transaction_date', '')::date, public.manila_today());
    v_conf := nullif(p_txn ->> 'ocr_confidence', '')::numeric;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end;
  if v_amount is null or v_amount <= 0 then return jsonb_build_object('ok', false, 'error', 'bad_amount'); end if;
  if v_date > public.manila_today() + 1 then return jsonb_build_object('ok', false, 'error', 'future_date'); end if;
  if v_conf is not null and (v_conf < 0 or v_conf > 1) then return jsonb_build_object('ok', false, 'error', 'bad_confidence'); end if;
  v_cat := coalesce(nullif(btrim(coalesce(p_txn ->> 'category', '')), ''), 'other');
  if v_cat in ('guest_refund', 'airbnb_adjustment') or not exists (select 1 from public.expense_categories c where c.property_id = p_property_id and c.slug = v_cat and c.is_active) then
    return jsonb_build_object('ok', false, 'error', 'bad_category');
  end if;
  v_status := coalesce(nullif(p_txn ->> 'status', ''), 'confirmed');
  if v_status not in ('confirmed', 'pending_review') then return jsonb_build_object('ok', false, 'error', 'status_not_allowed'); end if;
  v_path := nullif(btrim(coalesce(p_txn ->> 'receipt_image_path', '')), '');
  if v_path is not null and (char_length(v_path) > 300 or position('..' in v_path) > 0) then return jsonb_build_object('ok', false, 'error', 'bad_path'); end if;
  v_src := coalesce(nullif(p_txn ->> 'source', ''), case when v_path is not null or p_txn ? 'ocr_raw' then 'ocr' else 'telegram' end);
  if v_src not in ('telegram', 'ocr') then return jsonb_build_object('ok', false, 'error', 'bad_source'); end if;
  if p_txn ? 'ocr_raw' and jsonb_typeof(p_txn -> 'ocr_raw') = 'object' and char_length((p_txn -> 'ocr_raw')::text) <= 20000 then
    v_raw := (p_txn -> 'ocr_raw') - 's134_auto' - 's134_amount' - 's134_group' - 's134_backfill' - 's134_incomplete' - 'draft_id';
  end if;
  perform public.admin_audit_context_v1('telegram', null, null);
  insert into public.transactions(property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, payee_name, notes, external_ref, logged_by, receipt_image_path, ocr_confidence, ocr_raw)
  values (p_property_id, 'expense', v_cat, v_status, v_src, v_date, v_amount, 'PHP', coalesce(nullif(p_txn ->> 'payee_name', ''), nullif(p_txn ->> 'payee', '')), nullif(p_txn ->> 'notes', ''), p_key,
          coalesce(nullif(p_txn ->> 'logged_by', ''), 'telegram'), v_path, v_conf, v_raw)
  returning * into v_row;
  perform public.admin_audit_context_v1('', null, null);
  return jsonb_build_object('ok', true, 'id', v_row.id, 'replayed', false, 'lookalike', public.s_expense_lookalike_v1(v_row.id));
end $$;

create or replace function public.telegram_expense_review_v1(p_id uuid, p_action text, p_payload jsonb, p_actor text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row public.transactions%rowtype; v_where text; v_reason text; v_amount numeric; v_who text := left(coalesce(nullif(btrim(p_actor), ''), 'telegram'), 80);
begin
  if p_action is null or p_action not in ('confirm', 'void', 'amount') then return jsonb_build_object('ok', false, 'error', 'bad_action'); end if;
  select * into v_row from public.transactions where id = p_id and txn_type = 'expense' for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_row.source in ('bill', 'cleaner_fee', 'refund', 'direct_booking', 'airbnb', 'airbnb_email', 'airbnb_payout_email') then
    v_where := case v_row.source when 'bill' then 'bills' when 'cleaner_fee' then 'pay' end;
    return jsonb_build_object('ok', false, 'error', 'locked', 'where', v_where);
  end if;
  if p_action = 'void' then
    if v_row.status = 'void' then return jsonb_build_object('ok', true, 'id', v_row.id, 'status', 'void', 'unchanged', true); end if;
    v_reason := btrim(coalesce(p_payload ->> 'reason', ''));
    if char_length(v_reason) < 3 then v_reason := 'voided in Telegram by ' || v_who; end if;
    perform public.s_txn_void_core_v1(v_row.id, left(v_reason, 200), null);
    return jsonb_build_object('ok', true, 'id', v_row.id, 'status', 'void');
  end if;
  if v_row.status = 'void' then return jsonb_build_object('ok', false, 'error', 'void'); end if;
  if p_action = 'confirm' then
    if v_row.status = 'confirmed' then return jsonb_build_object('ok', true, 'id', v_row.id, 'status', 'confirmed', 'unchanged', true); end if;
    -- a stock row whose receipt has an unpriced line holds only the priced part: a person prices the line (or voids the row) first
    if coalesce(v_row.ocr_raw ->> 's134_incomplete', '') = 'true' then return jsonb_build_object('ok', false, 'error', 'amount_incomplete', 'where', 'Inventory'); end if;
    if v_row.category in ('guest_refund', 'airbnb_adjustment') or not exists (select 1 from public.expense_categories c where c.property_id = v_row.property_id and c.slug = v_row.category and c.is_active) then
      return jsonb_build_object('ok', false, 'error', 'bad_category');
    end if;
    perform public.admin_audit_context_v1('telegram confirm by ' || v_who, null, null);
    update public.transactions set status = 'confirmed', updated_at = now() where id = v_row.id;
    perform public.admin_audit_context_v1('', null, null);
    return jsonb_build_object('ok', true, 'id', v_row.id, 'status', 'confirmed');
  end if;
  -- amount: the receipt-total edit, pending rows only
  if v_row.status <> 'pending_review' then return jsonb_build_object('ok', false, 'error', 'not_pending'); end if;
  begin v_amount := nullif(p_payload ->> 'amount', '')::numeric; exception when others then return jsonb_build_object('ok', false, 'error', 'bad_amount'); end;
  if v_amount is null or v_amount <= 0 then return jsonb_build_object('ok', false, 'error', 'bad_amount'); end if;
  if public.s_stock_expense_owned_v1(v_row.id) and exists (select 1 from public.inventory_purchases ip where ip.transaction_id = v_row.id) then
    return jsonb_build_object('ok', false, 'error', 'amount_locked', 'where', 'Inventory');
  end if;
  perform public.admin_audit_context_v1('telegram amount by ' || v_who, null, null);
  update public.transactions set gross_amount = v_amount, updated_at = now() where id = v_row.id;
  perform public.admin_audit_context_v1('', null, null);
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'amount', v_amount);
end $$;

-- 6c. admin_review_transaction_v1 (s89, same signature and grants): the review queue's approve gets the s134 refusals. A refusal is an answer {ok:false, error, where}, never an exception (the s89 errors stay exceptions).
--     amount_incomplete (stock row with an unpriced line), amount_locked (the purchases decide amount, date and payee), system_category, locked (a staff pay row keeps its category). The rollback restores the s89 body.
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
    -- s134 refusals (answers, not exceptions)
    if coalesce(v_row.ocr_raw ->> 's134_incomplete', '') = 'true' then return jsonb_build_object('ok', false, 'error', 'amount_incomplete', 'where', 'Inventory'); end if;
    if v_row.txn_type = 'expense' and v_cat is not null and v_cat is distinct from v_row.category then
      if v_row.source = 'cleaner_fee' then return jsonb_build_object('ok', false, 'error', 'locked', 'where', 'Pay staff'); end if;
      if v_cat = any (array['guest_refund', 'airbnb_adjustment']) then return jsonb_build_object('ok', false, 'error', 'system_category'); end if;
    end if;
    if ((v_amount is not null and v_amount is distinct from v_row.gross_amount) or (v_date is not null and v_date is distinct from v_row.transaction_date)
        or (p_edits ? 'payee_name' and nullif(btrim(p_edits->>'payee_name'), '') is distinct from v_row.payee_name))
       and public.s_stock_expense_owned_v1(v_row.id) and exists (select 1 from public.inventory_purchases ip where ip.transaction_id = v_row.id) then
      return jsonb_build_object('ok', false, 'error', 'amount_locked', 'where', 'Inventory');
    end if;
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
comment on function public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text) is 'S89: approve (optionally with edits) or void a pending_review ledger row. approve_payment only; audited by the table trigger; void is a soft_delete audit row with the reason. S134: approve refuses amount_incomplete, amount_locked, system_category and locked as {ok:false,error,where}.';

-- 6d. admin_review_queue_v1 (s89, same signature and grants): each row also returns s134_incomplete (boolean), so the queue can show a stock row with an unpriced line as not yet approvable (approve refuses it, 6c).
--     Body = the s89 body plus that one column; the guard in section 0 pins the s89 body (md5 ed2a6920...) and this release's body. The rollback restores the s89 body byte for byte.
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
           t.receipt_image_path, t.ocr_confidence, t.created_at,
           coalesce(t.ocr_raw->>'s134_incomplete' = 'true', false) as s134_incomplete
      from public.transactions t
     where t.property_id = p_property_id and t.status = 'pending_review' and not (t.source = 'direct_booking' and t.booking_id is not null)
     order by t.transaction_date desc, t.created_at desc limit 100) q;
  return jsonb_build_object('count', v_count, 'total', v_total, 'rows', v_rows, 'truncated', v_count > 100);
end;
$$;
comment on function public.admin_review_queue_v1(uuid) is 'S89: transactions waiting for review (count, total, newest 100). No guest data; direct-booking payments are on Inquiries. owner/admin/finance. S134: each row also returns s134_incomplete (an unpriced stock line: the row cannot be approved yet).';

-- 6e. admin_save_transaction_v1 (s89, same signature and grants, still granted to authenticated): the s134 system keys of ocr_raw (s134_auto, s134_amount, s134_group, s134_backfill, s134_incomplete) are the server's, never the client's.
--     Body = the s89 body plus two changes: on insert the five keys are stripped from the client's ocr_raw; on an edit that replaces ocr_raw the row's own five keys are carried over, so a client cannot clear s134_incomplete on a stock row
--     (approve would let it through) or rewrite its amount. The guard in section 0 pins the s89 body (md5 ff48081b485cacf547a1692d7641d85b) and this release's body. The rollback restores the s89 body byte for byte.
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
      v_raw := (p_txn->'ocr_raw') - 's134_auto' - 's134_amount' - 's134_group' - 's134_backfill' - 's134_incomplete';
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
      ocr_raw = case when v_receipt is not null then case when v_raw is null then ocr_raw else v_raw || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(coalesce(ocr_raw, '{}'::jsonb)) e
                                                                                                where e.key = any (array['s134_auto', 's134_amount', 's134_group', 's134_backfill', 's134_incomplete'])), '{}'::jsonb) end else ocr_raw end,
      updated_at = now()
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'auditId', (select id from public.admin_audit_log where entity_table = 'transactions' and entity_id = v_row.id order by created_at desc limit 1));
end;
$$;
revoke all on function public.admin_save_transaction_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.admin_save_transaction_v1(uuid, jsonb, text) to authenticated;

-- 7. grants, restated (ML-21) ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.expenses_screen_v1(uuid, date, integer, timestamptz, text, uuid) from public, anon, service_role;
revoke all on function public.admin_save_transaction_v2(uuid, jsonb, text) from public, anon, service_role;
revoke all on function public.expense_void_v1(uuid, uuid, text, uuid) from public, anon, service_role;
revoke all on function public.expense_receipt_paths_v1(uuid, uuid[]) from public, anon, service_role;
revoke all on function public.expense_receipt_set_v1(uuid, uuid, text, text) from public, anon, service_role;
grant execute on function public.expenses_screen_v1(uuid, date, integer, timestamptz, text, uuid) to authenticated;
grant execute on function public.admin_save_transaction_v2(uuid, jsonb, text) to authenticated;
grant execute on function public.expense_void_v1(uuid, uuid, text, uuid) to authenticated;
grant execute on function public.expense_receipt_paths_v1(uuid, uuid[]) to authenticated;
grant execute on function public.expense_receipt_set_v1(uuid, uuid, text, text) to authenticated;

revoke all on function public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text) from public, anon, service_role;
grant execute on function public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text) to authenticated;
revoke all on function public.admin_review_queue_v1(uuid) from public, anon, service_role;
grant execute on function public.admin_review_queue_v1(uuid) to authenticated;

revoke all on function public.telegram_expense_save_v1(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.telegram_expense_review_v1(uuid, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.telegram_expense_save_v1(uuid, jsonb, text) to service_role;
grant execute on function public.telegram_expense_review_v1(uuid, text, jsonb, text) to service_role;

revoke all on function public.s_stock_expense_group_of_v1(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.s_stock_expense_txn_of_v1(text) from public, anon, authenticated, service_role;
revoke all on function public.s_stock_expense_group_v1() from public, anon, authenticated, service_role;
revoke all on function public.s_stock_expense_trg_v1() from public, anon, authenticated, service_role;
revoke all on function public.s_stock_expense_sync_v1(text) from public, anon, authenticated, service_role;
revoke all on function public.s_stock_expense_task_v1(uuid, text, text, text) from public, anon, authenticated, service_role;
revoke all on function public.s_stock_expense_owned_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.s_txn_void_core_v1(uuid, text, text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.s_expense_chip_v1(text, boolean, boolean) from public, anon, authenticated, service_role;
revoke all on function public.s_expense_mime_v1(text) from public, anon, authenticated, service_role;
revoke all on function public.s_expense_receipt_v1(uuid, boolean) from public, anon, authenticated, service_role;
revoke all on function public.s_expense_lookalike_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.s_expense_receipt_gate_v1(uuid, text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.s_expense_bucket_pdf_v1(text) from public, anon, authenticated, service_role;
revoke all on function public.kpi_admin_costs_v1(uuid, date, date) from public, anon, authenticated, service_role;

commit;
