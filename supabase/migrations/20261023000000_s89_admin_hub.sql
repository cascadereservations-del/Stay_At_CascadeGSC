-- 20261023000000_s89_admin_hub.sql
-- Session 89, lane L1 (admin server): release s89_admin_hub_20261023. Backs the Manage hub on the staff app so the React dashboard is not needed on a phone.
--   1. admin_save_transaction_v1  now stores an optional receipt_image_path (+ ocr_confidence, ocr_raw). The path must be an existing object in the private
--      expense-receipts bucket under '<property_id>/' (new scans) or 'receipts/' (legacy Telegram receipts), and may be attached to one live ledger row only.
--      Everything else in the body, and the grant, is unchanged.
--   2. admin_review_queue_v1 / admin_review_transaction_v1  the 'transactions waiting for review' queue as audited RPCs (approve, edit+approve, void).
--      Direct-booking payments linked to a booking are excluded and refused: they are confirmed on Inquiries (SPEC-44) and a void would cancel the booking.
--   3. get_hospitality_series_v1  months of occupancy / ADR / RevPAR / revenue plus last year and 3-month pace. Calls get_hospitality_metrics_v1 per month, so
--      every number is that function's number by construction. Same gate: read_operations, and the stays gate inside the metrics makes the effective roles owner, admin and finance (a cleaner is refused).
--   4. expense_categories is the one list: six slugs that Manage and the ledger already use are added to it (no transaction is touched);
--      expense_categories_v1() reads it for owner/admin/finance.
-- Expand only. Guard (55000, nothing changed): md5(replace(prosrc, chr(13), '')) of admin_save_transaction_v1 = 147e217b6c7a14f264f7dfce43b8bb2f.
-- Rollback: supabase/rollbacks/20261023_s89_admin_hub.sql

begin;

-- 0. guard ----------------------------------------------------------------------------------------------------------------------------------
do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.admin_save_transaction_v1(uuid,jsonb,text)');
  if v_got is distinct from '147e217b6c7a14f264f7dfce43b8bb2f' then
    raise exception 's89 admin hub: admin_save_transaction_v1 is not the body this release was cut from (md5 %): re-cut it', v_got using errcode = '55000';
  end if;
  if to_regprocedure('public.get_hospitality_metrics_v1(uuid,date,date)') is null or to_regprocedure('public.admin_stays_v1(uuid)') is null then
    raise exception 's89 admin hub: get_hospitality_metrics_v1 or admin_stays_v1 is missing' using errcode = '55000';
  end if;
end $$;

-- 1. admin_save_transaction_v1 --------------------------------------------------------------------------------------------------------------
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
-- create or replace keeps the grants (authenticated only); restated so a re-run is harmless
revoke all on function public.admin_save_transaction_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.admin_save_transaction_v1(uuid, jsonb, text) to authenticated;

-- 4. one category list ----------------------------------------------------------------------------------------------------------------------
insert into public.expense_categories(property_id, slug, label, keywords, sort_order, is_active)
select pc.property_id, v.slug, v.label, '{}'::text[], v.so, true
  from (select distinct property_id from public.expense_categories) pc
  cross join (values ('internet','Internet',80), ('subscription','Subscription',90), ('furnishing','Furnishing',100),
                     ('cohost_fee','Co-host fee',110), ('airbnb_adjustment','Airbnb adjustment',120), ('loan','Loan',130)) v(slug, label, so)
 where not exists (select 1 from public.expense_categories e where e.property_id = pc.property_id and e.slug = v.slug);

create or replace function public.expense_categories_v1(p_property_id uuid)
returns table (slug text, label text, sort_order integer)
language plpgsql stable security definer set search_path to '' as $$
begin
  perform public.admin_require('read_finance', p_property_id);
  return query select c.slug, c.label, c.sort_order from public.expense_categories c
    where c.property_id = p_property_id and c.is_active order by c.sort_order, c.slug;
end;
$$;
revoke all on function public.expense_categories_v1(uuid) from public, anon, service_role;
grant execute on function public.expense_categories_v1(uuid) to authenticated;
comment on function public.expense_categories_v1(uuid) is 'S89: the one expense category list (expense_categories table, active rows). owner/admin/finance.';

-- 2. review queue ---------------------------------------------------------------------------------------------------------------------------
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
revoke all on function public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text) from public, anon, service_role;
grant execute on function public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text) to authenticated;
comment on function public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text) is 'S89: approve (optionally with edits) or void a pending_review ledger row. approve_payment only; audited by the table trigger; void is a soft_delete audit row with the reason.';

-- 3. hospitality series -------------------------------------------------------------------------------------------------------------------
create or replace function public.get_hospitality_series_v1(p_property_id uuid, p_months integer default 12)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare
  v_today date; v_first date; v_m date; v_cur jsonb; v_ly jsonb; v_items jsonb := '[]'::jsonb; v_pace jsonb := '[]'::jsonb; v_op date; v_fin boolean;
  v_end date; v_ly_start date; v_ly_end date; v_ly_asof date; v_otb integer; v_lyotb integer; v_lyunk integer; v_cap integer; i integer;
begin
  perform public.admin_require('read_operations', p_property_id);
  if p_months is null or p_months < 1 or p_months > 24 then raise exception using errcode = '22023', message = 'months must be between 1 and 24'; end if;
  v_fin := public.finance_human_authorized(p_property_id);
  v_today := public.manila_today();
  v_first := (date_trunc('month', v_today) - make_interval(months => p_months - 1))::date;
  for i in 0 .. p_months - 1 loop
    v_m := (v_first + make_interval(months => i))::date;
    v_cur := public.get_hospitality_metrics_v1(p_property_id, v_m, (v_m + interval '1 month')::date) -> 'metrics';
    v_ly := public.get_hospitality_metrics_v1(p_property_id, (v_m - interval '1 year')::date, (v_m + interval '1 month' - interval '1 year')::date) -> 'metrics';
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'month', v_m,
      'capacity_nights', (v_cur->'capacity_nights'->>'value')::integer,
      'sold_nights', (v_cur->'sold_nights'->>'value')::integer,
      'occupancy', (v_cur->'occupancy'->>'value')::numeric,
      'adr', (v_cur->'adr'->>'value')::numeric,
      'revpar', (v_cur->'revpar'->>'value')::numeric,
      'revenue', (v_cur->'accommodation_revenue'->>'value')::numeric,
      'coverage', jsonb_build_object('occupancy', v_cur->'occupancy'->>'coverage', 'adr', v_cur->'adr'->>'coverage', 'revpar', v_cur->'revpar'->>'coverage', 'revenue', v_cur->'accommodation_revenue'->>'coverage'),
      'ly', case when coalesce((v_ly->'capacity_nights'->>'value')::integer, 0) > 0 then jsonb_build_object(
              'month', (v_m - interval '1 year')::date,
              'capacity_nights', (v_ly->'capacity_nights'->>'value')::integer,
              'sold_nights', (v_ly->'sold_nights'->>'value')::integer,
              'occupancy', (v_ly->'occupancy'->>'value')::numeric,
              'adr', (v_ly->'adr'->>'value')::numeric,
              'revpar', (v_ly->'revpar'->>'value')::numeric,
              'revenue', (v_ly->'accommodation_revenue'->>'value')::numeric) end));
  end loop;

  -- Pace: nights on the books for this month and the next two, against the books on the same day last year.
  -- This year counts every confirmed or completed stay now. Last year counts stays whose booking date was on or before today minus one year; stays with
  -- no booking date are counted separately (ly_unknown_booking_date) and left out. The cancellation date is not stored, so a stay cancelled later is
  -- not counted last year either: last year's figure is approximate and null when the property was not yet operating on that day.
  select coalesce((select (value #>> '{}')::date from public.app_settings where key = 'operating_start_date'),
                  (select min(checkin) from public.admin_stays_v1(p_property_id) where status <> 'cancelled')) into v_op;
  v_ly_asof := (v_today - interval '1 year')::date;
  for i in 0 .. 2 loop
    v_m := (date_trunc('month', v_today) + make_interval(months => i))::date;
    v_end := (v_m + interval '1 month')::date;
    v_ly_start := (v_m - interval '1 year')::date;
    v_ly_end := (v_end - interval '1 year')::date;
    select count(distinct d)::int into v_otb
      from public.admin_stays_v1(p_property_id) s
      cross join lateral generate_series(greatest(s.checkin, v_m), least(s.checkout, v_end) - 1, interval '1 day') d
     where s.status in ('confirmed','completed') and s.checkin < v_end and s.checkout > v_m;
    if v_op is not null and v_op <= v_ly_asof then
      select count(distinct d) filter (where s.booking_created is not null and s.booking_created <= v_ly_asof)::int into v_lyotb
        from public.admin_stays_v1(p_property_id) s
        cross join lateral generate_series(greatest(s.checkin, v_ly_start), least(s.checkout, v_ly_end) - 1, interval '1 day') d
       where s.status in ('confirmed','completed') and s.checkin < v_ly_end and s.checkout > v_ly_start;
      select count(distinct s.stay_id)::int into v_lyunk
        from public.admin_stays_v1(p_property_id) s
       where s.status in ('confirmed','completed') and s.checkin < v_ly_end and s.checkout > v_ly_start and s.booking_created is null;
    else
      v_lyotb := null; v_lyunk := null;
    end if;
    v_cap := greatest(0, v_end - greatest(v_m, coalesce(v_op, v_m)));
    v_pace := v_pace || jsonb_build_array(jsonb_build_object('month', v_m, 'capacity_nights', v_cap, 'otb_nights', v_otb,
      'ly_otb_nights', v_lyotb, 'ly_unknown_booking_date', v_lyunk, 'ly_asof', v_ly_asof));
  end loop;

  return jsonb_build_object('propertyId', p_property_id, 'definition', 'metrics.v1', 'financeVisible', v_fin, 'asOf', v_today, 'months', v_items, 'pace', v_pace);
end;
$$;
revoke all on function public.get_hospitality_series_v1(uuid, integer) from public, anon, service_role;
grant execute on function public.get_hospitality_series_v1(uuid, integer) to authenticated;
comment on function public.get_hospitality_series_v1(uuid, integer) is 'S89: per-month occupancy, ADR, RevPAR, revenue and sold nights (each from get_hospitality_metrics_v1), the same month last year where capacity existed, and 3-month on-the-books pace against the same day last year. read_operations plus the stays gate inside the metrics: effective roles owner, admin and finance.';

commit;
