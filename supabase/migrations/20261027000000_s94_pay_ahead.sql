-- 20261027000000_s94_pay_ahead.sql
-- Session 94, lane SQL: release s94_pay_ahead_20261027 (contract: Cascade/docs/s94/CONTRACT.md, SQL section). Pay a turnover BEFORE its report exists, clear settled meter
-- follow-ups, store prechecks for the instant meter check, and run the meter sweep every 10 minutes.
-- (1) Advance line in staff_pay_requests.lines: {kind:'advance', checkout_date, date (same), type:'turnover', base, transport, amount, guest}. No session_id. Priced by
--     s_pay_price_v1('turnover', date).
-- (2) staff_pay_admin_create_v2(payee, sessions, claim_ids, advance, key): v1's checks plus, per advance date, it must be a checkout in get_missed_cleanings(prop, 30)
--     ('advance_not_owed') and held by no non-cancelled request ('advance_taken', ref). The 20-line cap counts advance lines. v1 is now a wrapper passing '[]'.
-- (3) staff_pay_settle_v1: an advance line writes one expense row (external_ref cleanadv:<request>:<date>, found again by that ref so a second pass is a no-op) and stamps a
--     session already linked for that date. A line of any other kind is refused ('bad_line') instead of falling into the claim branch. logged_by is the actor whenever no
--     Telegram id is given.
-- (4) cleaning_sessions_link_advance (AFTER INSERT, definer, internal): a new non-mid_stay session with no request, filed by the payee of a live request that holds an advance
--     line for that checkout, joins that request (and, when the request is paid, is stamped paid with the cleanadv row). It never shows again as an unpaid candidate.
--     A cancel releases it with the others (telegram_staff_pay_step_v1 clears pay_request_id for every session on the request). The trigger never fails the insert.
-- (5) staff_pay_candidates_v1 adds reports_owed [{date, ref, status}]; (6) staff_pay_admin_list_v1 adds advance_candidates, payees [{user_id, name, has_qr}] and the line's guest / checkout_date;
-- (7) staff_pay_notice_v1 adds reports_owed (ISO dates still owed) for the paid notice. staff_pay_my_requests_v1, telegram_staff_pay_step_v1, staff_pay_admin_step_v1,
--     staff_pay_admin_settle_v1, staff_pay_notify_paid_trg and kpi_recompute_v1 were read and need no change (they use only line date and amount, or no lines).
-- (8) get_meter_photo_followups: a session with fee_paid_at set drops out.
-- (9) meter_photo_prechecks (object_name pk, meter, result, checked_at): RLS on, service_role only.
-- (10) cron verify-meter-photo-daily -> */10 * * * * (name and command unchanged); job_heartbeats.expected_interval_seconds 86400 -> 600.
-- Guards: each replaced body must be the live one this was cut from (md5 of prosrc, CR stripped, read live 2026-10-20), else 55000 and nothing changes.
-- To undo apply supabase/rollbacks/20261027_s94_pay_ahead.sql.

begin;

do $$
declare v_got text; r record;
begin
  for r in select * from (values
      ('public.staff_pay_admin_create_v1(uuid,jsonb,uuid[],text)', '7b2fdc962b1b0eda3da1cd66eacf9606'),
      ('public.staff_pay_settle_v1(uuid,bigint,text,text,jsonb)', '8b57e10fc2db491a065a8915255fbd12'),
      ('public.staff_pay_candidates_v1()', '6cdafb8627ee6d3081a486ccd832ee66'),
      ('public.staff_pay_admin_list_v1()', 'e358920c180ba46fd2fe3e595234f68b'),
      ('public.staff_pay_notice_v1(uuid,text)', 'bc108903a2ac4bf13ab10fdbf9318279'),
      ('public.get_meter_photo_followups(uuid,integer)', '68844a6d99f94ab7c410f4d55806ee19')) v(sig, md) loop
    select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v_got is distinct from r.md then
      raise exception 's94 pay ahead: % is not the body this release was cut from (md5 %): re-cut it from the live body', r.sig, v_got using errcode = '55000';
    end if;
  end loop;
end $$;

-- 1. which session, if any, a request's advance line has been matched to ----------------------------------------------------------------------
-- A session matches by its checkout date; only a session with no checkout date falls back to get_missed_cleanings' window (filed the same or next Manila day), so consecutive checkouts
-- can never take each other's report. A session that is itself a 'clean' line of the request is not a match.
create or replace function public.s_advance_session_v1(p_request_id uuid, p_date date)
returns uuid
language sql stable security definer set search_path = '' as $$
  select cs.id
    from public.cleaning_sessions cs
    join public.staff_pay_requests r on r.id = cs.pay_request_id
   where r.id = p_request_id
     and coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay'
     and (cs.checkout_date = p_date or (cs.checkout_date is null and (cs.cleaned_at at time zone 'Asia/Manila')::date between p_date and p_date + 1))
     and not exists (select 1 from jsonb_array_elements(r.lines) x where x ->> 'session_id' = cs.id::text)
   order by (cs.checkout_date = p_date) desc nulls last, cs.cleaned_at
   limit 1;
$$;

-- 2. create v2 and the v1 wrapper -----------------------------------------------------------------------------------------------------------------
create or replace function public.staff_pay_admin_create_v2(p_payee_user_id uuid, p_sessions jsonb, p_claim_ids uuid[], p_advance jsonb, p_idempotency_key text)
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
  v_cleans jsonb := '[]'::jsonb; v_claims jsonb := '[]'::jsonb; v_adv jsonb := '[]'::jsonb; v_lines jsonb;
  v_dates date[] := '{}'; v_ref text; v_guest text;
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
  if p_advance is null or jsonb_typeof(p_advance) <> 'array' then p_advance := '[]'::jsonb; end if;
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

  -- S94 advance lines: a checkout with no report yet (get_missed_cleanings, 30 days), turnover rate on that date, no other live request paying it ahead.
  -- The per-date lock makes two admins' taps on the same date wait for each other, so the second reads the first one's line.
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
  if jsonb_array_length(v_cleans) + jsonb_array_length(v_adv) + jsonb_array_length(v_claims) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_lines');
  end if;
  if jsonb_array_length(v_cleans) + jsonb_array_length(v_adv) + jsonb_array_length(v_claims) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_lines');
  end if;
  if v_total <= 0 then return jsonb_build_object('ok', false, 'reason', 'bad_total'); end if;

  -- write: the audit trigger on staff_pay_requests records the actor (auth.uid()) and this reason; created_by_user_id marks the row
  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')), 'Admin')
    into v_by from auth.users u where u.id = v_uid;
  perform set_config('cascade.audit_reason', 'staff pay request made by ' || left(coalesce(v_by, 'Admin'), 30) || ' for ' || v_name, true);
  v_lines := v_cleans || v_adv || v_claims;
  insert into public.staff_pay_requests(property_id, payee_user_id, payee_name, idempotency_key, lines, total_amount, created_by_user_id)
  values (c_prop, p_payee_user_id, v_name, p_idempotency_key, v_lines, v_total, v_uid) returning * into v_req;
  update public.cleaning_sessions set pay_request_id = v_req.id where id = any(v_clean_ids);
  update public.cleaning_expense_claims set pay_request_id = v_req.id where id = any(v_claim_ids);

  return jsonb_build_object('ok', true, 'id', v_req.id, 'request_id', v_req.id, 'ref', v_req.ref, 'status', v_req.status, 'total', v_req.total_amount,
                            'payee_name', v_req.payee_name, 'lines', v_req.lines, 'created_by_user_id', v_uid);
end $$;

create or replace function public.staff_pay_admin_create_v1(p_payee_user_id uuid, p_sessions jsonb, p_claim_ids uuid[], p_idempotency_key text)
returns jsonb
language sql volatile security definer set search_path = '' as $$
  select public.staff_pay_admin_create_v2(p_payee_user_id, p_sessions, p_claim_ids, '[]'::jsonb, p_idempotency_key);
$$;

-- 3. settle ----------------------------------------------------------------------------------------------------------------------------------
create or replace function public.staff_pay_settle_v1(p_id uuid, p_actor_tg bigint, p_actor text, p_verdict text, p_proof jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_r public.staff_pay_requests%rowtype;
  v_l jsonb; v_s public.cleaning_sessions%rowtype; v_c public.cleaning_expense_claims%rowtype;
  v_txn uuid; v_uid uuid; v_label text; v_ref text;
  -- S94: a settle with no Telegram id (the Staff app, or a data step run by hand) is not a Telegram settle, whatever the actor text says
  v_web boolean := p_actor_tg is null;
begin
  select * into v_r from public.staff_pay_requests where id = p_id;
  for v_l in select value from jsonb_array_elements(v_r.lines) loop
    if v_l->>'kind' = 'clean' then
      select * into v_s from public.cleaning_sessions where id = (v_l->>'session_id')::uuid for update;
      if not found or v_s.fee_paid_at is not null or v_s.pay_request_id is distinct from v_r.id
         or exists (select 1 from public.transactions t where t.external_ref = 'cleanfee:' || v_s.id and t.status <> 'void') then
        return jsonb_build_object('ok', false, 'reason', 'already_paid', 'date', v_l->>'date', 'status', v_r.status);
      end if;
    elsif v_l->>'kind' = 'claim' then
      select * into v_c from public.cleaning_expense_claims where id = (v_l->>'claim_id')::uuid for update;
      if not found or v_c.pay_request_id is distinct from v_r.id or v_c.status not in ('pending_review', 'approved')
         or exists (select 1 from public.transactions t where t.external_ref = 'claim:' || v_c.id and t.status <> 'void') then
        return jsonb_build_object('ok', false, 'reason', 'already_paid', 'date', v_l->>'date', 'status', v_r.status);
      end if;
    elsif v_l->>'kind' is distinct from 'advance' then -- S94: an advance line needs no pre-check (its transaction is written once, below); anything else is not a line this function knows
      return jsonb_build_object('ok', false, 'reason', 'bad_line', 'date', v_l->>'date', 'status', v_r.status);
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
    elsif v_l->>'kind' = 'claim' then
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
    else -- S94 advance: paid before the report exists. One expense row per line, found again by its ref, so a second pass never writes twice.
      v_ref := 'cleanadv:' || v_r.id || ':' || (v_l->>'checkout_date');
      select t.id into v_txn from public.transactions t where t.external_ref = v_ref and t.status <> 'void' limit 1;
      if v_txn is null then
        insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
        values (v_r.property_id, 'expense', 'cleaning', 'confirmed', 'cleaner_fee', (v_l->>'amount')::numeric, v_r.payee_name, (v_l->>'checkout_date')::date,
                v_ref,
                'Cleaning fee paid ahead, report owed - ' || v_r.payee_name || ', ' || (v_l->>'checkout_date') || ', Turnover'
                  || case when coalesce((v_l->>'transport')::numeric, 0) > 0 then ' + transport' else '' end || '. Pay request ' || v_r.ref || '.',
                case when v_web then p_actor else 'Telegram: ' || p_actor end)
        returning id into v_txn;
      end if;
      -- the report was filed after the request was made (the link trigger put it on this request): this same payment settles it
      update public.cleaning_sessions set fee_amount = (v_l->>'amount')::numeric, fee_paid_at = now(), fee_txn_id = v_txn
       where id = public.s_advance_session_v1(v_r.id, (v_l->>'checkout_date')::date) and fee_paid_at is null;
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

-- 4. link a later report to the request that paid it ahead ----------------------------------------------------------------------------------------
create or replace function public.cleaning_sessions_link_advance_trg()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_d date; v_r public.staff_pay_requests%rowtype; v_txn uuid;
begin
  if new.pay_request_id is not null or new.submitted_by_user_id is null or coalesce(new.cleaning_type, 'checkout') = 'mid_stay' then return null; end if;
  begin -- the report must always be saved: a failure here is a warning, never a rollback of her submission
    -- the same per-date lock create_v2 takes, so a request being made and a report arriving in the same instant see each other
    perform pg_advisory_xact_lock(hashtextextended('staff_pay_advance:' || coalesce(new.checkout_date, (new.cleaned_at at time zone 'Asia/Manila')::date)::text, 0));
    select r.id, (l.value ->> 'checkout_date')::date into v_id, v_d
      from public.staff_pay_requests r cross join lateral jsonb_array_elements(r.lines) l
     where r.payee_user_id = new.submitted_by_user_id and r.property_id = new.property_id and r.status <> 'cancelled'
       and l.value ->> 'kind' = 'advance'
       and ((l.value ->> 'checkout_date')::date = new.checkout_date
            or (new.checkout_date is null and (new.cleaned_at at time zone 'Asia/Manila')::date between (l.value ->> 'checkout_date')::date and (l.value ->> 'checkout_date')::date + 1))
       and public.s_advance_session_v1(r.id, (l.value ->> 'checkout_date')::date) is null
     order by coalesce((l.value ->> 'checkout_date')::date = new.checkout_date, false) desc, (l.value ->> 'checkout_date')::date, r.created_at
     limit 1
       for update of r;
    if v_id is null then return null; end if;
    update public.cleaning_sessions set pay_request_id = v_id where id = new.id;
    select * into v_r from public.staff_pay_requests where id = v_id;
    if v_r.status = 'paid' then
      select t.id into v_txn from public.transactions t where t.external_ref = 'cleanadv:' || v_id || ':' || v_d and t.status <> 'void' limit 1;
      update public.cleaning_sessions
         set fee_amount = (select (l ->> 'amount')::numeric from jsonb_array_elements(v_r.lines) l where l ->> 'kind' = 'advance' and l ->> 'checkout_date' = v_d::text limit 1),
             fee_paid_at = v_r.paid_at, fee_txn_id = v_txn
       where id = new.id;
    end if;
  exception when others then
    raise warning 'cleaning_sessions_link_advance_trg: could not link session % (%)', new.id, sqlstate;
  end;
  return null;
end $$;
revoke all on function public.cleaning_sessions_link_advance_trg() from public, anon, authenticated, service_role;
drop trigger if exists cleaning_sessions_link_advance on public.cleaning_sessions;
create trigger cleaning_sessions_link_advance after insert on public.cleaning_sessions
  for each row execute function public.cleaning_sessions_link_advance_trg();

-- 5. candidates (staff): reports still owed -------------------------------------------------------------------------------------------------------
create or replace function public.staff_pay_candidates_v1()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_uid uuid := auth.uid();
  v_name text; v_sessions jsonb; v_claims jsonb; v_missing jsonb; v_reqs jsonb; v_owed jsonb;
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

  -- S94: paid ahead, report not filed yet
  select coalesce(jsonb_agg(jsonb_build_object('date', l.value ->> 'checkout_date', 'ref', q.ref, 'status', q.status) order by l.value ->> 'checkout_date', q.created_at), '[]'::jsonb)
    into v_owed
    from public.staff_pay_requests q cross join lateral jsonb_array_elements(q.lines) l
   where q.payee_user_id = v_uid and q.property_id = c_prop and q.status <> 'cancelled' and l.value ->> 'kind' = 'advance'
     and public.s_advance_session_v1(q.id, (l.value ->> 'checkout_date')::date) is null;

  return jsonb_build_object('ok', true, 'payee_name', coalesce(v_name, 'Staff'), 'sessions', v_sessions, 'claims', v_claims,
                            'missing_reports', v_missing, 'requests', v_reqs, 'reports_owed', v_owed);
end $$;

-- 6. admin list --------------------------------------------------------------------------------------------------------------------------------
create or replace function public.staff_pay_admin_list_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'; v_rows jsonb; v_unreq jsonb; v_adv jsonb; v_payees jsonb;
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
                                                              'description', l ->> 'description', 'amount', l -> 'amount', 'guest', l ->> 'guest', 'checkout_date', l ->> 'checkout_date') order by l ->> 'date'), '[]'::jsonb)
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
  -- S94: checkouts with no report yet (30 days, a named guest) that no live request already pays ahead. Rate = turnover on that date, as create_v2 prices it.
  select coalesce(jsonb_agg(jsonb_build_object('checkout_date', m.d, 'guest', m.g, 'base', r.base, 'transport', r.transport) order by m.d), '[]'::jsonb)
    into v_adv
    from (select g.checkout_date d, min(nullif(split_part(btrim(g.guest_name), ' ', 1), '')) g
            from public.get_missed_cleanings(c_prop, 30) g where nullif(btrim(coalesce(g.guest_name, '')), '') is not null group by g.checkout_date) m
    cross join lateral public.s_pay_price_v1('turnover', m.d) r
   where not exists (select 1 from public.staff_pay_requests q, jsonb_array_elements(q.lines) l
                      where q.property_id = c_prop and q.status <> 'cancelled' and l ->> 'kind' = 'advance' and l ->> 'checkout_date' = m.d::text);
  -- S94: everyone who may be paid (current staff allowed to submit cleanings, not disabled), so pay-ahead can pick someone with no unpaid session
  select coalesce(jsonb_agg(jsonb_build_object('user_id', p.user_id,
      'name', coalesce((select nullif(btrim(c.cleaner_name), '') from public.cleaning_sessions c where c.property_id = c_prop and c.submitted_by_user_id = p.user_id order by c.cleaned_at desc limit 1),
                       (select nullif(btrim(u.raw_app_meta_data ->> 'display_name'), '') from auth.users u where u.id = p.user_id),
                       (select nullif(btrim(u.raw_user_meta_data ->> 'display_name'), '') from auth.users u where u.id = p.user_id), 'Staff'),
      'has_qr', exists (select 1 from public.staff_details d where d.user_id = p.user_id and d.payout_qrph is not null)) order by p.user_id), '[]'::jsonb)
    into v_payees
    from public.staff_access_profiles p
   where p.disabled_at is null and public.staff_access_allowed(p.role, 'submit_cleaning', p.disabled_at, null)
     and exists (select 1 from public.staff_property_access a where a.user_id = p.user_id and a.property_id = c_prop);
  return jsonb_build_object('ok', true, 'requests', v_rows, 'unrequested', v_unreq, 'advance_candidates', v_adv, 'payees', v_payees);
end $$;

-- 7. paid notice -------------------------------------------------------------------------------------------------------------------------------
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
    'date_to', (select max((l ->> 'date')::date) from jsonb_array_elements(v_r.lines) l),
    -- S94: paid ahead, report not filed yet: the checkout dates (ISO, oldest first) the paid notice asks her to still send
    'reports_owed', coalesce((select jsonb_agg(l ->> 'checkout_date' order by l ->> 'checkout_date') from jsonb_array_elements(v_r.lines) l
                               where l ->> 'kind' = 'advance' and public.s_advance_session_v1(v_r.id, (l ->> 'checkout_date')::date) is null), '[]'::jsonb));
end $$;

-- 8. meter follow-ups: settled sessions drop out --------------------------------------------------------------------------------------------------
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
    and cs.fee_paid_at is null -- S94: a settled session (paid in full) needs no photo follow-up
    and (
      cs.meter_photos_skipped
      or mr.vision_verdict in ('mismatch', 'not_a_meter', 'unreadable')
    )
  order by cs.cleaned_at desc;
end;
$function$;

-- 9. stored prechecks (written and read by the verify-meter-photo edge function with the service role) ------------------------------------------------
create table if not exists public.meter_photo_prechecks (
  object_name text primary key,
  meter       text not null check (meter in ('electric', 'water')),
  result      jsonb not null,
  checked_at  timestamptz not null default now()
);
alter table public.meter_photo_prechecks enable row level security;
revoke all on table public.meter_photo_prechecks from public, anon, authenticated;
grant select, insert, update, delete on table public.meter_photo_prechecks to service_role;
comment on table public.meter_photo_prechecks is 'S94: one meter-photo read per stored object, made when the photo is taken (verify-meter-photo mode precheck); the sweep reuses it instead of a second model call. service_role only.';

-- 10. the sweep runs every 10 minutes ---------------------------------------------------------------------------------------------------------------
do $$
declare v_id bigint;
begin
  if to_regclass('cron.job') is null then
    raise notice 's94: pg_cron is absent here (recovery baseline): verify-meter-photo-daily schedule left alone';
  else
    select jobid into v_id from cron.job where jobname = 'verify-meter-photo-daily';
    if v_id is null then raise exception 's94: cron job verify-meter-photo-daily not found' using errcode = '55000'; end if;
    perform cron.alter_job(v_id, schedule := '*/10 * * * *');
  end if;
  update public.job_heartbeats set expected_interval_seconds = 600 where job_name = 'verify-meter-photo-daily';
end $$;

-- 11. grants: state the end state ---------------------------------------------------------------------------------------------------------------
revoke all on function public.s_advance_session_v1(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.staff_pay_admin_create_v2(uuid, jsonb, uuid[], jsonb, text) from public, anon;
grant execute on function public.staff_pay_admin_create_v2(uuid, jsonb, uuid[], jsonb, text) to authenticated;
revoke all on function public.staff_pay_admin_create_v1(uuid, jsonb, uuid[], text) from public, anon;
grant execute on function public.staff_pay_admin_create_v1(uuid, jsonb, uuid[], text) to authenticated;
revoke all on function public.staff_pay_settle_v1(uuid, bigint, text, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.staff_pay_candidates_v1() from public, anon;
grant execute on function public.staff_pay_candidates_v1() to authenticated, service_role;
revoke all on function public.staff_pay_admin_list_v1() from public, anon;
grant execute on function public.staff_pay_admin_list_v1() to authenticated;
revoke all on function public.staff_pay_notice_v1(uuid, text) from public, anon, authenticated;
grant execute on function public.staff_pay_notice_v1(uuid, text) to service_role;
revoke all on function public.get_meter_photo_followups(uuid, integer) from public, anon;
grant execute on function public.get_meter_photo_followups(uuid, integer) to authenticated, service_role;

commit;
