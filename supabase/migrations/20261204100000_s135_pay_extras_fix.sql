-- Session 135: release s135_pay_extras_fix_20261204 (D-420). A staff pay request that carries an extra (a new expense typed in the request) was refused with extra_needs_a_clean every time.
-- Cause: staff_pay_request_create_v2 (first defined in s99, 20261101000000_s99_staff_pay_ahead.sql) resolves and locks the session the extras attach to (v_attach) behind
-- "if jsonb_array_length(v_extras) > 0", but v_extras is only filled by the validation loop further down, so the test was always false, v_attach stayed null, and the check before the write refused.
-- Live since s99 (2026-11-01); 0 expense claims were created through this path since. Fix: ONE token changes in that line, v_extras becomes p_extras (already normalised to an array above it).
-- Lock order is unchanged (idempotency lock, cleans, attach session FOR KEY SHARE, per-date advance locks, claims). Same signature, security definer, search_path, language; grants are not touched (create or replace keeps them).
-- Guard (55000, nothing changes): the live body must be the s99 body (md5 a95f98dedb25f139451f38b80032f9d6) or this release (md5 2e29292fece7c5533395c663b29873a3). Post-check: the new body is live.
-- Rollback: supabase/rollbacks/20261204_s135_pay_extras_fix.sql (restores the s99 body, md5 a95f98dedb25f139451f38b80032f9d6).

begin;

-- 0. guard
do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)');
  if v is null then raise exception 's135: staff_pay_request_create_v2 is missing (apply s99 first)' using errcode = '55000'; end if;
  if v is distinct from 'a95f98dedb25f139451f38b80032f9d6' and v is distinct from '2e29292fece7c5533395c663b29873a3' then
    raise exception 's135: staff_pay_request_create_v2 is not the body this release was cut from (md5 %): re-cut it from the live body', v using errcode = '55000';
  end if;
end $g$;

-- 1. the s99 body byte for byte, except the one token in the attach-session test
create or replace function public.staff_pay_request_create_v2(p_sessions jsonb, p_claim_ids uuid[], p_extras jsonb, p_advance jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  c_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_uid uuid := auth.uid();
  v_req public.staff_pay_requests%rowtype;
  v_s public.cleaning_sessions%rowtype;
  v_c public.cleaning_expense_claims%rowtype;
  v_rate record;
  v_e jsonb; v_cid uuid;
  v_name text; v_prefix text;
  v_date date; v_base numeric; v_tr numeric; v_transport boolean;
  v_clean_ids uuid[] := '{}'; v_claim_ids uuid[] := '{}';
  v_cleans jsonb := '[]'::jsonb; v_claims jsonb := '[]'::jsonb; v_extras jsonb := '[]'::jsonb; v_lines jsonb;
  v_total numeric := 0; v_extras_total numeric := 0;
  v_amt numeric; v_desc text; v_rp text;
  v_latest_sid uuid; v_latest_date date; v_attach uuid;
  v_adv jsonb := '[]'::jsonb; v_dates date[] := '{}'; v_ref text; v_guest text;
begin
  if v_uid is null or not public.current_staff_authorized('submit_cleaning', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 80 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  -- same key, same person: one at a time, so the second call sees the first one's row
  perform pg_advisory_xact_lock(hashtextextended('staff_pay_create:' || v_uid::text || ':' || p_idempotency_key, 0));
  select * into v_req from public.staff_pay_requests where payee_user_id = v_uid and idempotency_key = p_idempotency_key;
  if found then
    -- a cancelled request keeps its key: the app mints a new one and sends again
    if v_req.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'key_cancelled', 'ref', v_req.ref); end if;
    return jsonb_build_object('ok', true, 'replay', true, 'request_id', v_req.id, 'ref', v_req.ref, 'status', v_req.status,
                              'total', v_req.total_amount, 'payee_name', v_req.payee_name, 'lines', v_req.lines,
                              'finance_message_id', v_req.finance_message_id);
  end if;

  select nullif(btrim(cleaner_name), '') into v_name from public.cleaning_sessions
   where property_id = c_prop and submitted_by_user_id = v_uid order by cleaned_at desc limit 1;
  v_name := coalesce(v_name, 'Staff');

  if p_sessions is null or jsonb_typeof(p_sessions) <> 'array' then p_sessions := '[]'::jsonb; end if;
  if p_extras is null or jsonb_typeof(p_extras) <> 'array' then p_extras := '[]'::jsonb; end if;
  if p_advance is null or jsonb_typeof(p_advance) <> 'array' then p_advance := '[]'::jsonb; end if;
  p_claim_ids := coalesce(p_claim_ids, '{}');
  if cardinality(p_claim_ids) <> (select count(distinct x) from unnest(p_claim_ids) x) then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- 2. cleans, locked in id order so two taps of the same list cannot deadlock
  for v_e in select value from jsonb_array_elements(p_sessions) order by value->>'id' loop
    if jsonb_typeof(v_e) <> 'object' or coalesce(v_e->>'id', '') !~* c_uuid or (v_e->>'id')::uuid = any(v_clean_ids) then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;
    v_clean_ids := v_clean_ids || (v_e->>'id')::uuid;
    select * into v_s from public.cleaning_sessions where id = (v_e->>'id')::uuid for update;
    if not found or v_s.property_id <> c_prop or v_s.submitted_by_user_id is distinct from v_uid then
      return jsonb_build_object('ok', false, 'reason', 'session_not_yours');
    end if;
    if v_s.fee_paid_at is not null or v_s.pay_request_id is not null then
      return jsonb_build_object('ok', false, 'reason', 'session_taken');
    end if;
    v_date := coalesce(v_s.checkout_date, v_s.checkin_date, (v_s.cleaned_at at time zone 'Asia/Manila')::date);
    select * into v_rate from public.staff_pay_rate_v1(v_date);
    if not found then return jsonb_build_object('ok', false, 'reason', 'no_rate', 'date', v_date); end if;
    v_base := case when v_s.cleaning_type = 'deep_clean' then v_rate.general else v_rate.regular end;
    case coalesce(jsonb_typeof(v_e->'transport'), 'null')
      when 'boolean' then v_transport := (v_e->>'transport')::boolean;
      when 'null' then v_transport := false;
      else return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end case;
    v_tr := 0;
    if v_transport then
      if v_rate.transport is null then return jsonb_build_object('ok', false, 'reason', 'transport_not_allowed', 'date', v_date); end if;
      v_tr := v_rate.transport;
    end if;
    v_cleans := v_cleans || jsonb_strip_nulls(jsonb_build_object('kind', 'clean', 'session_id', v_s.id, 'date', v_date,
      'type', coalesce(v_s.cleaning_type, 'turnover'), 'base', v_base, 'transport', v_tr, 'amount', v_base + v_tr,
      'guest', nullif(split_part(btrim(coalesce(v_s.last_guest_name, '')), ' ', 1), '')));
    v_total := v_total + v_base + v_tr;
    if v_latest_date is null or v_date >= v_latest_date then v_latest_sid := v_s.id; v_latest_date := v_date; end if;
  end loop;
  select coalesce(jsonb_agg(l order by l->>'date', l->>'session_id'), '[]'::jsonb) into v_cleans from jsonb_array_elements(v_cleans) l;

  -- S2 (deadlock): the session the extras attach to is resolved and locked HERE, before any per-date advance lock, so every caller takes locks in the same order:
  -- idempotency lock -> cleans (id order, FOR UPDATE) -> attach session (FOR KEY SHARE) -> per-date advance locks (date order) -> claims. Same rule as v1: the latest clean of this request, else her latest session.
  if jsonb_array_length(p_extras) > 0 then
    v_attach := v_latest_sid;
    if v_attach is null then
      select id into v_attach from public.cleaning_sessions where property_id = c_prop and submitted_by_user_id = v_uid order by cleaned_at desc limit 1 for key share;
    end if;
  end if;

  -- S99 advance lines (D-348): a checkout with no report yet (get_missed_cleanings, 30 days, a named guest), turnover rate on that date, no other live request paying it ahead.
  -- Copied from staff_pay_admin_create_v2 (s94): the per-date lock makes two taps (hers and the admin's) on the same date wait for each other, so the second reads the first one's line.
  for v_e in select value from jsonb_array_elements(p_advance) order by value->>'checkout_date' loop
    if jsonb_typeof(v_e) <> 'object' or coalesce(v_e->>'checkout_date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;
    begin v_date := (v_e->>'checkout_date')::date; exception when others then return jsonb_build_object('ok', false, 'reason', 'bad_request'); end;
    if v_date = any(v_dates) then return jsonb_build_object('ok', false, 'reason', 'bad_request'); end if;
    v_dates := v_dates || v_date;
    perform pg_advisory_xact_lock(hashtextextended('staff_pay_advance:' || v_date::text, 0));
    select nullif(split_part(btrim(g.guest_name), ' ', 1), '') into v_guest
      from public.get_missed_cleanings(c_prop, 30) g where g.checkout_date = v_date and nullif(btrim(coalesce(g.guest_name, '')), '') is not null order by g.checkin_date limit 1; -- a row with no guest (an Airbnb block) is not a stay to pay
    if not found then return jsonb_build_object('ok', false, 'reason', 'advance_not_owed', 'date', v_date); end if;
    select q.ref into v_ref from public.staff_pay_requests q, jsonb_array_elements(q.lines) l
     where q.property_id = c_prop and q.status <> 'cancelled' and l ->> 'kind' = 'advance' and l ->> 'checkout_date' = v_date::text limit 1;
    if found then return jsonb_build_object('ok', false, 'reason', 'advance_taken', 'date', v_date, 'ref', v_ref); end if;
    select * into v_rate from public.s_pay_price_v1('turnover', v_date);
    if not found then return jsonb_build_object('ok', false, 'reason', 'no_rate', 'date', v_date); end if;
    v_base := v_rate.base;
    case coalesce(jsonb_typeof(v_e->'transport'), 'null')
      when 'boolean' then v_transport := (v_e->>'transport')::boolean;
      when 'null' then v_transport := false;
      else return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end case;
    v_tr := 0;
    if v_transport then
      if v_rate.transport is null then return jsonb_build_object('ok', false, 'reason', 'transport_not_allowed', 'date', v_date); end if;
      v_tr := v_rate.transport;
    end if;
    v_adv := v_adv || jsonb_strip_nulls(jsonb_build_object('kind', 'advance', 'checkout_date', v_date, 'date', v_date, 'type', 'turnover',
      'base', v_base, 'transport', v_tr, 'amount', v_base + v_tr, 'guest', v_guest));
    v_total := v_total + v_base + v_tr;
  end loop;

  -- 3. existing claims
  for v_cid in select distinct x from unnest(p_claim_ids) x order by x loop
    select * into v_c from public.cleaning_expense_claims where id = v_cid for update;
    if not found or v_c.property_id <> c_prop or v_c.submitted_by_user_id <> v_uid
       or v_c.status not in ('pending_review', 'approved') or v_c.pay_request_id is not null then
      return jsonb_build_object('ok', false, 'reason', 'claim_taken');
    end if;
    v_claim_ids := v_claim_ids || v_c.id;
    v_claims := v_claims || jsonb_build_object('kind', 'claim', 'claim_id', v_c.id, 'date', v_c.expense_date,
      'description', v_c.description, 'amount', v_c.amount, 'receipt', v_c.receipt_path is not null);
    v_total := v_total + v_c.amount;
  end loop;

  -- 4. new expenses typed in the request (validated here, written after every check has passed)
  v_prefix := c_prop::text || '/' || v_uid::text || '/';
  for v_e in select value from jsonb_array_elements(p_extras) loop
    v_desc := case when jsonb_typeof(v_e) = 'object' then btrim(coalesce(v_e->>'description', '')) else '' end;
    if char_length(v_desc) not between 3 and 500 then return jsonb_build_object('ok', false, 'reason', 'bad_extra'); end if;
    if jsonb_typeof(v_e->'amount') not in ('number', 'string') or coalesce(v_e->>'amount', '') !~ '^[0-9]{1,5}(\.[0-9]{1,2})?$' then
      return jsonb_build_object('ok', false, 'reason', 'bad_extra');
    end if;
    v_amt := (v_e->>'amount')::numeric;
    if v_amt <= 0 or v_amt > 5000 then return jsonb_build_object('ok', false, 'reason', 'bad_extra'); end if;
    v_rp := nullif(btrim(coalesce(v_e->>'receipt_path', '')), '');
    if v_rp is not null and (left(v_rp, length(v_prefix)) <> v_prefix or position('..' in v_rp) > 0 or char_length(v_rp) > 300) then
      return jsonb_build_object('ok', false, 'reason', 'bad_extra');
    end if;
    v_extras_total := v_extras_total + v_amt;
    v_extras := v_extras || jsonb_build_object('description', v_desc, 'amount', v_amt, 'receipt_path', v_rp);
  end loop;
  if v_extras_total > 5000 then return jsonb_build_object('ok', false, 'reason', 'bad_extra'); end if;
  v_total := v_total + v_extras_total;

  -- 5. lines: 20 keeps the Telegram photo caption under 1,024 characters
  if jsonb_array_length(v_cleans) + jsonb_array_length(v_adv) + jsonb_array_length(v_claims) + jsonb_array_length(v_extras) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_lines');
  end if;
  if jsonb_array_length(v_cleans) + jsonb_array_length(v_adv) + jsonb_array_length(v_claims) + jsonb_array_length(v_extras) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_lines');
  end if;
  if v_total <= 0 then return jsonb_build_object('ok', false, 'reason', 'bad_total'); end if;
  if jsonb_array_length(v_extras) > 0 and v_attach is null then return jsonb_build_object('ok', false, 'reason', 'extra_needs_a_clean'); end if; -- v_attach was resolved and locked before the advance loop

  -- 6. write: the extras become claims, then the request, then the links
  for v_e in select value from jsonb_array_elements(v_extras) loop
    insert into public.cleaning_expense_claims(property_id, cleaning_session_id, submitted_by_user_id, expense_date, description, amount, receipt_path)
    values (c_prop, v_attach, v_uid, (now() at time zone 'Asia/Manila')::date, v_e->>'description', (v_e->>'amount')::numeric, v_e->>'receipt_path')
    returning id into v_cid;
    v_claim_ids := v_claim_ids || v_cid;
    v_claims := v_claims || jsonb_build_object('kind', 'claim', 'claim_id', v_cid, 'date', (now() at time zone 'Asia/Manila')::date,
      'description', v_e->>'description', 'amount', (v_e->>'amount')::numeric, 'receipt', (v_e->>'receipt_path') is not null);
  end loop;
  v_lines := v_cleans || v_adv || v_claims;
  insert into public.staff_pay_requests(property_id, payee_user_id, payee_name, idempotency_key, lines, total_amount)
  values (c_prop, v_uid, v_name, p_idempotency_key, v_lines, v_total) returning * into v_req;
  update public.cleaning_sessions set pay_request_id = v_req.id where id = any(v_clean_ids);
  update public.cleaning_expense_claims set pay_request_id = v_req.id where id = any(v_claim_ids);

  return jsonb_build_object('ok', true, 'request_id', v_req.id, 'ref', v_req.ref, 'status', v_req.status, 'total', v_req.total_amount,
                            'payee_name', v_req.payee_name, 'lines', v_req.lines, 'finance_message_id', null);
end $$;

-- 2. post-check
do $c$
declare v text; v_src text;
begin
  select md5(replace(p.prosrc, chr(13), '')), p.prosrc into v, v_src from pg_proc p where p.oid = to_regprocedure('public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)');
  if v is distinct from '2e29292fece7c5533395c663b29873a3' then raise exception 's135: staff_pay_request_create_v2 did not take the new body (md5 %)', v using errcode = '55000'; end if;
  if position('jsonb_array_length(p_extras) > 0' in v_src) = 0 then raise exception 's135: the attach-session test does not read p_extras' using errcode = '55000'; end if;
  if not exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)') and p.prosecdef) then
    raise exception 's135: staff_pay_request_create_v2 is no longer security definer' using errcode = '55000';
  end if;
end $c$;

commit;
