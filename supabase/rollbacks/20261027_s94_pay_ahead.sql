-- Compensating rollback for release s94_pay_ahead_20261027 (session 94).
-- Puts staff_pay_admin_create_v1, staff_pay_settle_v1, staff_pay_candidates_v1, staff_pay_admin_list_v1, staff_pay_notice_v1 and get_meter_photo_followups back to the bodies they had
-- on 2026-10-20 (md5 in the release guard), drops create_v2, the link trigger and function, the matching helper and meter_photo_prechecks (DATA LOSS by design: cached meter reads),
-- sets verify-meter-photo-daily back to 30 23 * * * (heartbeat 86400). Advance lines already in staff_pay_requests.lines stay; a request holding one that is still unpaid must be
-- cancelled first (the restored settle would otherwise treat the line as a claim). Roll the Staff app back first. Apply with run-sql-on-host.sh.

begin;

do $$
begin
  if exists (select 1 from public.staff_pay_requests r, jsonb_array_elements(r.lines) l where r.status in ('requested', 'paying') and l ->> 'kind' = 'advance') then
    raise exception 's94 rollback: an open pay request still holds an advance line; cancel it first' using errcode = '55000';
  end if;
end $$;

create or replace function public.staff_pay_admin_create_v1(p_payee_user_id uuid, p_sessions jsonb, p_claim_ids uuid[], p_idempotency_key text)
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
  v_name text; v_by text;
  v_date date; v_base numeric; v_tr numeric; v_transport boolean;
  v_clean_ids uuid[] := '{}'; v_claim_ids uuid[] := '{}';
  v_cleans jsonb := '[]'::jsonb; v_claims jsonb := '[]'::jsonb; v_lines jsonb;
  v_total numeric := 0;
begin
  if v_uid is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  if p_payee_user_id is not null and p_payee_user_id = v_uid then
    return jsonb_build_object('ok', false, 'reason', 'self'); -- nobody makes a pay request for her own work through the admin door
  end if;
  if p_payee_user_id is null or p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 80 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if not exists (select 1 from public.staff_access_profiles where user_id = p_payee_user_id) then
    return jsonb_build_object('ok', false, 'reason', 'payee_not_found');
  end if;
  -- the payee must be a current member of staff who may submit cleanings (not disabled, not a role without that right)
  if not exists (select 1 from public.staff_access_profiles p where p.user_id = p_payee_user_id and p.disabled_at is null
                  and public.staff_access_allowed(p.role, 'submit_cleaning', p.disabled_at, null)) then
    return jsonb_build_object('ok', false, 'reason', 'payee_not_allowed');
  end if;
  -- the same lock key the staff member's own create takes, so her tap and this one cannot both write
  perform pg_advisory_xact_lock(hashtextextended('staff_pay_create:' || p_payee_user_id::text || ':' || p_idempotency_key, 0));
  select * into v_req from public.staff_pay_requests where payee_user_id = p_payee_user_id and idempotency_key = p_idempotency_key;
  if found then
    if v_req.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'key_cancelled', 'ref', v_req.ref); end if;
    return jsonb_build_object('ok', true, 'replay', true, 'id', v_req.id, 'request_id', v_req.id, 'ref', v_req.ref, 'status', v_req.status,
                              'total', v_req.total_amount, 'payee_name', v_req.payee_name, 'lines', v_req.lines);
  end if;

  select nullif(btrim(cleaner_name), '') into v_name from public.cleaning_sessions
   where property_id = c_prop and submitted_by_user_id = p_payee_user_id order by cleaned_at desc limit 1;
  v_name := coalesce(v_name, 'Staff');

  if p_sessions is null or jsonb_typeof(p_sessions) <> 'array' then p_sessions := '[]'::jsonb; end if;
  p_claim_ids := coalesce(p_claim_ids, '{}');
  if cardinality(p_claim_ids) <> (select count(distinct x) from unnest(p_claim_ids) x) then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- cleans, locked in id order so two taps of the same list cannot deadlock
  for v_e in select value from jsonb_array_elements(p_sessions) order by value->>'id' loop
    if jsonb_typeof(v_e) <> 'object' or coalesce(v_e->>'id', '') !~* c_uuid or (v_e->>'id')::uuid = any(v_clean_ids) then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;
    v_clean_ids := v_clean_ids || (v_e->>'id')::uuid;
    select * into v_s from public.cleaning_sessions where id = (v_e->>'id')::uuid for update;
    if not found or v_s.property_id <> c_prop or v_s.submitted_by_user_id is distinct from p_payee_user_id then
      return jsonb_build_object('ok', false, 'reason', 'session_not_yours');
    end if;
    if v_s.fee_paid_at is not null or v_s.pay_request_id is not null then
      return jsonb_build_object('ok', false, 'reason', 'session_taken');
    end if;
    v_date := public.s_pay_day_v1(v_s.checkout_date, v_s.checkin_date, v_s.cleaned_at);
    select * into v_rate from public.s_pay_price_v1(v_s.cleaning_type, v_date);
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
    v_cleans := v_cleans || jsonb_strip_nulls(jsonb_build_object('kind', 'clean', 'session_id', v_s.id, 'date', v_date,
      'type', coalesce(v_s.cleaning_type, 'turnover'), 'base', v_base, 'transport', v_tr, 'amount', v_base + v_tr,
      'guest', nullif(split_part(btrim(coalesce(v_s.last_guest_name, '')), ' ', 1), '')));
    v_total := v_total + v_base + v_tr;
  end loop;
  select coalesce(jsonb_agg(l order by l->>'date', l->>'session_id'), '[]'::jsonb) into v_cleans from jsonb_array_elements(v_cleans) l;

  -- existing claims
  for v_cid in select distinct x from unnest(p_claim_ids) x order by x loop
    select * into v_c from public.cleaning_expense_claims where id = v_cid for update;
    if not found or v_c.property_id <> c_prop or v_c.submitted_by_user_id <> p_payee_user_id
       or v_c.status not in ('pending_review', 'approved') or v_c.pay_request_id is not null then
      return jsonb_build_object('ok', false, 'reason', 'claim_taken');
    end if;
    v_claim_ids := v_claim_ids || v_c.id;
    v_claims := v_claims || jsonb_build_object('kind', 'claim', 'claim_id', v_c.id, 'date', v_c.expense_date,
      'description', v_c.description, 'amount', v_c.amount, 'receipt', v_c.receipt_path is not null);
    v_total := v_total + v_c.amount;
  end loop;

  -- lines: 20 keeps the Telegram photo caption under 1,024 characters
  if jsonb_array_length(v_cleans) + jsonb_array_length(v_claims) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_lines');
  end if;
  if jsonb_array_length(v_cleans) + jsonb_array_length(v_claims) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_lines');
  end if;
  if v_total <= 0 then return jsonb_build_object('ok', false, 'reason', 'bad_total'); end if;

  -- write: the audit trigger on staff_pay_requests records the actor (auth.uid()) and this reason; created_by_user_id marks the row
  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')), 'Admin')
    into v_by from auth.users u where u.id = v_uid;
  perform set_config('cascade.audit_reason', 'staff pay request made by ' || left(coalesce(v_by, 'Admin'), 30) || ' for ' || v_name, true);
  v_lines := v_cleans || v_claims;
  insert into public.staff_pay_requests(property_id, payee_user_id, payee_name, idempotency_key, lines, total_amount, created_by_user_id)
  values (c_prop, p_payee_user_id, v_name, p_idempotency_key, v_lines, v_total, v_uid) returning * into v_req;
  update public.cleaning_sessions set pay_request_id = v_req.id where id = any(v_clean_ids);
  update public.cleaning_expense_claims set pay_request_id = v_req.id where id = any(v_claim_ids);

  return jsonb_build_object('ok', true, 'id', v_req.id, 'request_id', v_req.id, 'ref', v_req.ref, 'status', v_req.status, 'total', v_req.total_amount,
                            'payee_name', v_req.payee_name, 'lines', v_req.lines, 'created_by_user_id', v_uid);
end $$;

create or replace function public.staff_pay_settle_v1(p_id uuid, p_actor_tg bigint, p_actor text, p_verdict text, p_proof jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_r public.staff_pay_requests%rowtype;
  v_l jsonb; v_s public.cleaning_sessions%rowtype; v_c public.cleaning_expense_claims%rowtype;
  v_txn uuid; v_uid uuid; v_label text;
  -- S82: a settle made in the Staff app (staff_pay_admin_settle_v1 passes no Telegram id and an actor ending ' via Staff app') is not a Telegram settle
  v_web boolean := coalesce(p_actor_tg is null and p_actor ~ ' via Staff app$', false);
begin
  select * into v_r from public.staff_pay_requests where id = p_id;
  for v_l in select value from jsonb_array_elements(v_r.lines) loop
    if v_l->>'kind' = 'clean' then
      select * into v_s from public.cleaning_sessions where id = (v_l->>'session_id')::uuid for update;
      if not found or v_s.fee_paid_at is not null or v_s.pay_request_id is distinct from v_r.id
         or exists (select 1 from public.transactions t where t.external_ref = 'cleanfee:' || v_s.id and t.status <> 'void') then
        return jsonb_build_object('ok', false, 'reason', 'already_paid', 'date', v_l->>'date', 'status', v_r.status);
      end if;
    else
      select * into v_c from public.cleaning_expense_claims where id = (v_l->>'claim_id')::uuid for update;
      if not found or v_c.pay_request_id is distinct from v_r.id or v_c.status not in ('pending_review', 'approved')
         or exists (select 1 from public.transactions t where t.external_ref = 'claim:' || v_c.id and t.status <> 'void') then
        return jsonb_build_object('ok', false, 'reason', 'already_paid', 'date', v_l->>'date', 'status', v_r.status);
      end if;
    end if;
  end loop;

  perform set_config('cascade.audit_reason', 'staff pay ' || v_r.ref || ' paid by ' || p_actor, true);
  select user_id into v_uid from public.staff_access_profiles
   where p_actor_tg is not null and telegram_user_id = p_actor_tg and public.staff_access_allowed(role, 'approve_payment', disabled_at, null) limit 1;

  for v_l in select value from jsonb_array_elements(v_r.lines) loop
    if v_l->>'kind' = 'clean' then
      select * into v_s from public.cleaning_sessions where id = (v_l->>'session_id')::uuid;
      v_label := case v_l->>'type' when 'deep_clean' then 'Deep Clean' when 'mid_stay' then 'Mid-stay' else 'Turnover' end
                 || case when coalesce((v_l->>'transport')::numeric, 0) > 0 then ' + transport' else '' end;
      insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
      values (v_r.property_id, 'expense', 'cleaning', 'confirmed', 'cleaner_fee', (v_l->>'amount')::numeric, v_s.cleaner_name, (v_l->>'date')::date,
              'cleanfee:' || v_s.id,
              'Cleaning fee - ' || v_s.cleaner_name || ', ' || (v_l->>'date') || ', ' || v_label || '. Pay request ' || v_r.ref || '.',
              case when v_web then p_actor else 'Telegram: ' || p_actor end)
      returning id into v_txn;
      update public.cleaning_sessions set fee_amount = (v_l->>'amount')::numeric, fee_paid_at = now(), fee_txn_id = v_txn where id = v_s.id;
    else
      select * into v_c from public.cleaning_expense_claims where id = (v_l->>'claim_id')::uuid;
      insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
      values (v_r.property_id, 'expense', 'supplies', 'confirmed', 'cleaner_fee', (v_l->>'amount')::numeric, v_r.payee_name, v_c.expense_date,
              'claim:' || v_c.id,
              'Staff expense - ' || v_c.description || '. Pay request ' || v_r.ref || '.',
              case when v_web then p_actor else 'Telegram: ' || p_actor end);
      update public.cleaning_expense_claims
         set status = 'paid', reviewed_at = now(), reviewed_by_user_id = v_uid,
             review_note = 'Paid in request ' || v_r.ref || ', confirmed by ' || p_actor || case when v_web then '' else ' in Telegram' end
       where id = v_c.id;
    end if;
  end loop;

  update public.staff_pay_requests set
    status = 'paid', paid_at = now(), paid_by_tg = p_actor_tg, paid_by_name = p_actor, paid_by_user_id = v_uid, proof_verdict = p_verdict,
    proof_file_unique_id = case when p_proof is null then proof_file_unique_id else p_proof->>'file_unique_id' end,
    proof_file_id        = case when p_proof is null then proof_file_id        else nullif(p_proof->>'file_id', '') end,
    proof_sha256         = case when p_proof is null then proof_sha256         else p_proof->>'sha256' end,
    proof_amount         = case when p_proof is null then proof_amount         when jsonb_typeof(p_proof->'amount') = 'number' then (p_proof->>'amount')::numeric end,
    proof_reference      = case when p_proof is null then proof_reference      else nullif(p_proof->>'reference', '') end,
    proof_read           = case when p_proof is null then proof_read           else jsonb_build_object('read', p_proof->'read', 'verdict', p_verdict) end
  where id = v_r.id;
  return jsonb_build_object('ok', true, 'status', 'paid', 'ref', v_r.ref, 'total', v_r.total_amount, 'verdict', p_verdict);
end $$;

create or replace function public.staff_pay_candidates_v1()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to ''
as $function$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_uid uuid := auth.uid();
  v_name text; v_sessions jsonb; v_claims jsonb; v_missing jsonb; v_reqs jsonb;
begin
  if v_uid is null or not public.current_staff_authorized('submit_cleaning', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;

  select nullif(btrim(cleaner_name), '') into v_name from public.cleaning_sessions
   where property_id = c_prop and submitted_by_user_id = v_uid order by cleaned_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'date', s.d, 'type', coalesce(s.cleaning_type, 'turnover'),
                                               'base', r.base, 'transport', r.transport) order by s.d, s.cleaned_at), '[]'::jsonb)
    into v_sessions
    from (select cs.id, cs.cleaning_type, cs.cleaned_at, coalesce(cs.checkout_date, cs.checkin_date, (cs.cleaned_at at time zone 'Asia/Manila')::date) as d
            from public.cleaning_sessions cs
           where cs.property_id = c_prop and cs.submitted_by_user_id = v_uid
             and cs.fee_paid_at is null and cs.pay_request_id is null) s
    cross join lateral (select case when s.cleaning_type = 'deep_clean' then x.general else x.regular end as base, x.transport
                          from public.staff_pay_rate_v1(s.d) x) r;

  select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'date', k.expense_date, 'description', k.description,
                                               'amount', k.amount, 'receipt', k.receipt_path is not null) order by k.expense_date, k.created_at), '[]'::jsonb)
    into v_claims
    from public.cleaning_expense_claims k
   where k.property_id = c_prop and k.submitted_by_user_id = v_uid
     and k.status in ('pending_review', 'approved') and k.pay_request_id is null;

  -- checkout dates only, no guest names (D-289 spirit)
  select coalesce(jsonb_agg(m.d order by m.d), '[]'::jsonb) into v_missing
    from (select distinct g.checkout_date as d from public.get_missed_cleanings(c_prop, 30) g) m;

  select coalesce(jsonb_agg(jsonb_build_object('ref', q.ref, 'status', q.status, 'total', q.total_amount,
                                               'created_at', q.created_at, 'paid_at', q.paid_at) order by q.created_at desc), '[]'::jsonb)
    into v_reqs
    from (select * from public.staff_pay_requests where payee_user_id = v_uid order by created_at desc limit 5) q;

  return jsonb_build_object('ok', true, 'payee_name', coalesce(v_name, 'Staff'), 'sessions', v_sessions, 'claims', v_claims,
                            'missing_reports', v_missing, 'requests', v_reqs);
end $function$;

create or replace function public.staff_pay_admin_list_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'; v_rows jsonb; v_unreq jsonb;
begin
  if auth.uid() is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'ref', q.ref, 'status', q.status, 'payee_name', q.payee_name, 'total', q.total_amount, 'created_at', q.created_at,
      'paying_by_name', q.paying_by_name, 'paying_by_user_id', case when q.status = 'paying' then q.paying_by_user_id end, 'paying_at', q.paying_at, 'sent_said_at', q.sent_said_at, 'paid_at', q.paid_at, 'paid_by_name', q.paid_by_name,
      'has_proof', q.proof_file_unique_id is not null, 'bank_reference', q.proof_reference,
      'has_qr', exists (select 1 from public.staff_details d where d.user_id = q.payee_user_id and d.payout_qrph is not null),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('kind', l ->> 'kind', 'date', l ->> 'date', 'type', l ->> 'type',
                                                              'description', l ->> 'description', 'amount', l -> 'amount') order by l ->> 'date'), '[]'::jsonb)
                  from jsonb_array_elements(q.lines) l)
    ) order by (q.status in ('requested', 'paying')) desc, q.created_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.staff_pay_requests r
           where r.property_id = c_prop
             and (r.status in ('requested', 'paying') or (r.status = 'paid' and r.paid_at > now() - interval '14 days'))
           order by (r.status in ('requested', 'paying')) desc, r.created_at desc limit 30) q;
  -- S82: unpaid work that is in no request, one entry per staff member. The same rule as staff_pay_candidates_v1 (a clean is open while
  -- fee_paid_at and pay_request_id are null, priced by the rate row in force on its pay day; a claim while pending_review or approved and in no
  -- request); a clean with no rate row is left out, as there. total = bases + claims (transport is counted only when chosen at create time).
  with ses as (
    select cs.submitted_by_user_id uid, cs.id, d.d, coalesce(cs.cleaning_type, 'turnover') typ, r.base, r.transport, cs.cleaned_at
      from public.cleaning_sessions cs
      cross join lateral (select public.s_pay_day_v1(cs.checkout_date, cs.checkin_date, cs.cleaned_at) d) d
      cross join lateral public.s_pay_price_v1(cs.cleaning_type, d.d) r
     where cs.property_id = c_prop and cs.submitted_by_user_id is not null and cs.fee_paid_at is null and cs.pay_request_id is null
  ), clm as (
    select k.submitted_by_user_id uid, k.id, k.expense_date d, k.description, k.amount, k.receipt_path is not null receipt, k.created_at
      from public.cleaning_expense_claims k
     where k.property_id = c_prop and k.submitted_by_user_id is not null
       and k.status in ('pending_review', 'approved') and k.pay_request_id is null
  ), who as (
    select w.uid, coalesce((select nullif(btrim(c.cleaner_name), '') from public.cleaning_sessions c
                             where c.property_id = c_prop and c.submitted_by_user_id = w.uid order by c.cleaned_at desc limit 1), 'Staff') name
      from (select uid from ses union select uid from clm) w
      join public.staff_access_profiles p on p.user_id = w.uid
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'payee_user_id', w.uid, 'payee_name', w.name, 'self', w.uid = auth.uid(),
      'has_qr', exists (select 1 from public.staff_details d where d.user_id = w.uid and d.payout_qrph is not null),
      'total', coalesce((select sum(s.base) from ses s where s.uid = w.uid), 0) + coalesce((select sum(k.amount) from clm k where k.uid = w.uid), 0),
      'sessions', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'date', s.d, 'type', s.typ, 'base', s.base, 'transport', s.transport)
                                             order by s.d, s.cleaned_at) from ses s where s.uid = w.uid), '[]'::jsonb),
      'claims', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'date', k.d, 'description', k.description, 'amount', k.amount, 'receipt', k.receipt)
                                           order by k.d, k.created_at) from clm k where k.uid = w.uid), '[]'::jsonb)
    ) order by lower(w.name), w.uid), '[]'::jsonb)
    into v_unreq from who w;
  return jsonb_build_object('ok', true, 'requests', v_rows, 'unrequested', v_unreq);
end $$;

create or replace function public.staff_pay_notice_v1(p_request_id uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_r public.staff_pay_requests%rowtype; v_label text;
begin
  if p_action = 'release' then
    update public.staff_pay_requests set paid_notified_at = null where id = p_request_id and paid_notified_at is not null;
    return jsonb_build_object('ok', true);
  end if;
  if p_action <> 'claim' then return jsonb_build_object('ok', false, 'reason', 'bad_action'); end if;
  update public.staff_pay_requests set paid_notified_at = now()
   where id = p_request_id and status = 'paid' and paid_notified_at is null returning * into v_r;
  if not found then
    select * into v_r from public.staff_pay_requests where id = p_request_id;
    if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
    return jsonb_build_object('ok', false, 'reason', case when v_r.status <> 'paid' then 'not_paid' else 'already_sent' end);
  end if;
  select nullif(btrim(d.payout_bank_label), '') into v_label from public.staff_details d where d.user_id = v_r.payee_user_id;
  return jsonb_build_object('ok', true, 'request_id', v_r.id, 'ref', v_r.ref, 'payee_user_id', v_r.payee_user_id, 'payee_name', v_r.payee_name,
    'first_name', split_part(btrim(v_r.payee_name), ' ', 1), 'total', v_r.total_amount, 'paid_at', v_r.paid_at, 'bank_reference', v_r.proof_reference,
    'bank_label', v_label, 'paid_by_tg', v_r.paid_by_tg, 'ops_chat_id', v_r.ops_chat_id, 'ops_message_id', v_r.ops_message_id,
    'date_from', (select min((l ->> 'date')::date) from jsonb_array_elements(v_r.lines) l),
    'date_to', (select max((l ->> 'date')::date) from jsonb_array_elements(v_r.lines) l));
end $$;

create or replace function public.get_meter_photo_followups(
  p_property_id uuid    default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid,
  p_lookback    integer default 14
)
returns table (
  session_id      uuid,
  submission_id   text,
  cleaned_at      timestamptz,
  cleaner_name    text,
  reason          text,
  typed_electric  numeric,
  typed_water     numeric,
  vision_electric numeric,
  vision_water    numeric,
  vision_verdict  text
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception 'not authorized to read operations for this property'
      using errcode = '42501';
  end if;

  return query
  select
    cs.id,
    cs.submission_id,
    cs.cleaned_at,
    cs.cleaner_name,
    case
      when cs.meter_photos_skipped              then 'no meter photos were attached'
      when mr.vision_verdict = 'mismatch'       then 'the photo does not show the number that was typed'
      when mr.vision_verdict = 'not_a_meter'    then 'the photo does not look like a meter'
      when mr.vision_verdict = 'unreadable'     then 'the photo could not be read'
      else 'needs another look'
    end,
    mr.electric_curr,
    mr.water_curr,
    mr.vision_electric,
    mr.vision_water,
    mr.vision_verdict
  from public.cleaning_sessions cs
  left join public.meter_readings mr on mr.session_id = cs.id
  where cs.property_id = p_property_id
    and cs.cleaned_at >= (now() - make_interval(days => greatest(p_lookback, 1)))
    and mr.vision_resolved_at is null
    and (
      cs.meter_photos_skipped
      or mr.vision_verdict in ('mismatch', 'not_a_meter', 'unreadable')
    )
  order by cs.cleaned_at desc;
end;
$function$;

drop trigger if exists cleaning_sessions_link_advance on public.cleaning_sessions;
drop function if exists public.cleaning_sessions_link_advance_trg();
drop function if exists public.staff_pay_admin_create_v2(uuid, jsonb, uuid[], jsonb, text);
drop function if exists public.s_advance_session_v1(uuid, date);
drop table if exists public.meter_photo_prechecks;

do $$
declare v_id bigint;
begin
  if to_regclass('cron.job') is not null then
    select jobid into v_id from cron.job where jobname = 'verify-meter-photo-daily';
    if v_id is not null then perform cron.alter_job(v_id, schedule := '30 23 * * *'); end if;
  end if;
  update public.job_heartbeats set expected_interval_seconds = 86400 where job_name = 'verify-meter-photo-daily';
end $$;

commit;
