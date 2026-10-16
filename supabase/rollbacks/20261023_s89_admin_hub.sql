-- Compensating rollback for release s89_admin_hub_20261023 (session 89).
-- Puts admin_save_transaction_v1 back to the body md5 147e217b6c7a14f264f7dfce43b8bb2f (receipt_image_path no longer read), drops the four new functions,
-- and removes the six category slugs the release added unless a transaction already uses them. Receipt paths already saved stay on their rows.
-- Roll the Staff app back first: Manage calls the new functions.
begin;

drop function if exists public.get_hospitality_series_v1(uuid, integer);
drop function if exists public.admin_review_transaction_v1(uuid, uuid, text, jsonb, text);
drop function if exists public.admin_review_queue_v1(uuid);
drop function if exists public.expense_categories_v1(uuid);

delete from public.expense_categories e
 where e.slug in ('internet','subscription','furnishing','cohost_fee','airbnb_adjustment','loan')
   and not exists (select 1 from public.transactions t where t.property_id = e.property_id and t.category = e.slug);

create or replace function public.admin_save_transaction_v1(p_property_id uuid, p_txn jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id uuid; v_row public.transactions%rowtype; v_type text; v_amount numeric; v_date date; v_ref text; v_reason text;
begin
  perform public.admin_require('approve_payment', p_property_id);
  v_id := nullif(p_txn->>'id', '')::uuid;
  v_type := coalesce(p_txn->>'txn_type', 'expense');
  if v_type not in ('income','expense','drawing') then raise exception using errcode = '22023', message = 'txn_type must be income, expense or drawing'; end if;
  v_amount := nullif(p_txn->>'gross_amount', '')::numeric;
  v_date := nullif(p_txn->>'transaction_date', '')::date;
  v_reason := nullif(btrim(coalesce(p_txn->>'reason', '')), '');
  if v_id is null then
    if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
    if v_amount is null or v_amount < 0 or v_date is null then raise exception using errcode = '22023', message = 'amount and date are required'; end if;
    v_ref := coalesce(nullif(p_txn->>'external_ref', ''), 'admin:' || p_idempotency_key);
    select * into v_row from public.transactions where property_id = p_property_id and external_ref = v_ref;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'replayed', true); end if;
    perform public.admin_audit_context_v1(coalesce(v_reason, 'created in admin'), null, null);
    insert into public.transactions(property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, or_number, payee_name, notes, external_ref, income_stage, reservation_id, booking_id, logged_by)
    values (p_property_id, v_type, coalesce(nullif(p_txn->>'category', ''), case v_type when 'drawing' then 'owner_drawing' else 'other' end), coalesce(nullif(p_txn->>'status', ''), 'confirmed'), 'manual', v_date, v_amount, 'PHP',
            nullif(p_txn->>'or_number', ''), nullif(p_txn->>'payee_name', ''), nullif(p_txn->>'notes', ''), v_ref, case when v_type = 'income' then 'confirmed' end,
            nullif(p_txn->>'reservation_id', '')::uuid, nullif(p_txn->>'booking_id', '')::uuid, 'admin')
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
      updated_at = now()
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'auditId', (select id from public.admin_audit_log where entity_table = 'transactions' and entity_id = v_row.id order by created_at desc limit 1));
end;
$$;
revoke all on function public.admin_save_transaction_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.admin_save_transaction_v1(uuid, jsonb, text) to authenticated;

commit;
