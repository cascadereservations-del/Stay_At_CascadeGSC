-- Rollback of s131b_followups_20261201: puts the exact s131 body of bill_pay_settle_v1 back (md5 ede3c0432079186f73b7db56900e6671, CR stripped; the s131b body is 9784e8619b3aeb3d6b19c5fd7f679c79).
-- Nothing else changes: no table, column, setting or other function is touched by s131b. Refuses (55000, nothing changes) when the live body is neither the s131b body nor the s131 body.
-- Grants restated as s131 left them (authenticated only).
begin;

do $g$
declare v text; r record;
begin
  for r in select * from (values
    ('public.bill_pay_settle_v1(uuid,jsonb)', 'ede3c0432079186f73b7db56900e6671', '9784e8619b3aeb3d6b19c5fd7f679c79')
  ) t(sig, m_old, m_new) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is distinct from r.m_old and v is distinct from r.m_new then
      raise exception using errcode = '55000', message = 'rollback s131b: ' || r.sig || ' is neither this release nor the s131 body (md5 ' || coalesce(v, 'null') || ')';
    end if;
  end loop;
end $g$;

-- the s131 body
create or replace function public.bill_pay_settle_v1(p_bill_id uuid, p_proof jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_b public.utility_bills%rowtype; v_cfg jsonb; v_res jsonb;
  v_path text; v_client_sha text; v_sha text; v_prefix text;
  v_rd date; v_rv numeric; v_prev date; v_low date; v_warn boolean;
begin
  select b.property_id into v_prop from public.utility_bills b where b.id = p_bill_id;
  if v_uid is null or not public.bill_can_v1(v_prop) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  select * into v_b from public.utility_bills where id = p_bill_id for update;
  if not found or v_b.status = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_cfg := public.bill_schedule_cfg_v1();
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_entry_v1(v_b, v_cfg, true, v_uid)); end if;
  if v_b.status = 'paying' and v_b.paying_by is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_payer', 'name', v_b.paying_by_name); end if;

  if p_proof is null or jsonb_typeof(p_proof) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_proof'); end if;
  -- s131: a meter bill carries the reading date printed on it (required) and, optionally, the present reading. The date must move the cycle forward: later than the previous paid reading date
  -- (the setting open_from while none is paid yet) of an EARLIER period, not before the 1st of the month before the billed period, and not after Manila today. Nothing is stored here; the row gets both only when the bill is paid, in this same call.
  if v_b.kind in ('electric', 'water') then
    perform pg_advisory_xact_lock(hashtextextended('bill_reading:' || v_b.property_id::text || ':' || v_b.kind, 0));
    -- an older bill of the same meter that is still due or paying must be settled first: the cycle follows the bills in order
    if exists (select 1 from public.utility_bills o where o.property_id = v_b.property_id and o.kind = v_b.kind and o.period < v_b.period and o.status not in ('paid', 'skipped')) then
      return jsonb_build_object('ok', false, 'reason', 'older_bill_open');
    end if;
    if jsonb_typeof(p_proof -> 'reading_date') is distinct from 'string' or btrim(p_proof ->> 'reading_date') = '' then
      return jsonb_build_object('ok', false, 'reason', 'reading_date_required');
    end if;
    v_rd := public.utility_safe_date_v1(btrim(p_proof ->> 'reading_date'));
    v_prev := coalesce((select max(o.reading_date) from public.utility_bills o where o.property_id = v_b.property_id and o.kind = v_b.kind and o.status = 'paid' and o.reading_date is not null and o.period < v_b.period),
                       (public.utility_billing_cfg_v1() -> v_b.kind ->> 'open_from')::date);
    -- not before the 1st of the month before the billed period (a bill for November is read in October or November)
    v_low := (public.utility_safe_date_v1(v_b.period || '-01') - interval '1 month')::date;
    if v_rd is null or v_rd <= v_prev or v_rd < v_low or v_rd > public.manila_today() then
      return jsonb_build_object('ok', false, 'reason', 'reading_date_invalid', 'after', greatest(v_prev, v_low - 1));
    end if;
    if jsonb_typeof(p_proof -> 'reading_value') in ('number', 'string') and btrim(p_proof ->> 'reading_value') <> '' then
      v_rv := case when btrim(p_proof ->> 'reading_value') ~ '^[0-9]{1,10}(\.[0-9]{1,6})?$' then round(btrim(p_proof ->> 'reading_value')::numeric, 2) end;
      if v_rv is null or v_rv >= 10000000000 then return jsonb_build_object('ok', false, 'reason', 'reading_value_invalid'); end if;
    elsif jsonb_typeof(p_proof -> 'reading_value') in ('boolean', 'array', 'object') then
      return jsonb_build_object('ok', false, 'reason', 'reading_value_invalid');
    end if;
  end if;
  v_path := btrim(coalesce(p_proof ->> 'path', ''));
  v_client_sha := lower(coalesce(p_proof ->> 'sha256', ''));
  v_prefix := v_b.property_id::text || '/' || v_uid::text || '/';
  if (v_client_sha <> '' and v_client_sha !~ '^[0-9a-f]{64}$') or char_length(v_path) not between 40 and 300
     or left(v_path, length(v_prefix)) <> v_prefix or position('..' in v_path) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_proof');
  end if;
  -- stored proof: the object exists in the private bucket and upload-photo recorded the hash of the bytes it stored
  select h.sha256 into v_sha from public.staff_upload_hashes h where h.path = v_path;
  if v_sha is null or not exists (select 1 from storage.objects o where o.bucket_id = 'cleaning-photos' and o.name = v_path) then
    return jsonb_build_object('ok', false, 'reason', 'no_stored_proof');
  end if;
  if v_client_sha <> '' and v_client_sha <> v_sha then return jsonb_build_object('ok', false, 'reason', 'sha_mismatch'); end if;

  v_res := public.bill_step_v1(v_b.id, 'paid', v_uid, public.bill_actor_name_v1(v_uid),
    jsonb_build_object('file_unique_id', 'web:' || v_path, 'file_id', v_path, 'path', v_path, 'sha256', v_sha, 'amount', p_proof -> 'amount', 'verdict', 'read',
                       'confirmed', coalesce(p_proof -> 'confirmed' = 'true'::jsonb, false), 'read', jsonb_build_object('source', 'staff_app', 'typed_by', v_uid)));
  if v_res ->> 'reason' = 'confirm_amount' then v_res := v_res || jsonb_build_object('estimate_php', v_b.estimate_php); end if;
  -- s131: stored with the paid bill in this same call (a refusal above stores nothing); the warning never blocks
  if coalesce((v_res ->> 'ok')::boolean, false) and v_b.kind in ('electric', 'water') then
    update public.utility_bills set reading_date = v_rd, reading_value = v_rv where id = v_b.id;
    v_warn := public.utility_reading_warn_v1(v_b.property_id, v_b.kind, v_rd, v_rv);
    v_res := v_res || jsonb_build_object('reading_date', v_rd, 'reading_warn', v_warn);
  end if;
  return public.bill_reply_v1(v_res, v_b.id);
end $$;

revoke all on function public.bill_pay_settle_v1(uuid, jsonb) from public, anon, service_role;
grant execute on function public.bill_pay_settle_v1(uuid, jsonb) to authenticated;

comment on function public.bill_pay_settle_v1(uuid, jsonb) is 's131: approve_payment. p_proof {path, sha256, amount, confirmed, reading_date (required for electric and water), reading_value (optional)}; one expense row. Refusals: not_authorized, not_found, already_paid, not_payer, bad_proof, older_bill_open, reading_date_required, reading_date_invalid, reading_value_invalid, no_stored_proof, sha_mismatch, duplicate_proof, bad_amount, confirm_amount. Adds reading_date and reading_warn.';

-- check
do $$
begin
  if md5(replace((select prosrc from pg_proc where oid = 'public.bill_pay_settle_v1(uuid,jsonb)'::regprocedure), chr(13), '')) <> 'ede3c0432079186f73b7db56900e6671' then raise exception 'rollback s131b: bill_pay_settle_v1 is not the s131 body'; end if;
  if not has_function_privilege('authenticated', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute') or has_function_privilege('anon', 'public.bill_pay_settle_v1(uuid,jsonb)', 'execute') then raise exception 'rollback s131b: bill_pay_settle_v1 grants wrong'; end if;
end $$;

commit;
