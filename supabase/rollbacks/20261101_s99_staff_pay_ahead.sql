-- Compensating rollback for release s99_staff_pay_ahead_20261101 (session 99).
-- Restores staff_pay_request_create_v1 to the live body it was cut from (md5 374416fd95fcc1c0668ab5b486eb2f2d) and staff_pay_candidates_v1 to the s94 body (md5 2db19457e15a84197caef16c1d2f4123),
-- then drops create_v2, the reminder functions and the staff_report_reminders table (reminder rows are lost; they only gate a push, nothing else reads them).
-- Refuses while a cleaner-made request (created_by_user_id null) with an advance line is still open: cancel or settle it first. Admin-made advance lines (s94) are unaffected.
-- Roll the Staff app back first. Apply with run-sql-on-host.sh.

begin;

do $$
begin
  if exists (select 1 from public.staff_pay_requests q, jsonb_array_elements(q.lines) l
              where q.created_by_user_id is null and q.status in ('requested', 'paying') and l ->> 'kind' = 'advance') then
    raise exception 's99 rollback: a cleaner-made request with an advance line is still open: cancel or settle it first' using errcode = '55000';
  end if;
end $$;

create or replace function public.staff_pay_request_create_v1(p_sessions jsonb, p_claim_ids uuid[], p_extras jsonb, p_idempotency_key text)
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
  if jsonb_array_length(v_cleans) + jsonb_array_length(v_claims) + jsonb_array_length(v_extras) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_lines');
  end if;
  if jsonb_array_length(v_cleans) + jsonb_array_length(v_claims) + jsonb_array_length(v_extras) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'too_many_lines');
  end if;
  if v_total <= 0 then return jsonb_build_object('ok', false, 'reason', 'bad_total'); end if;
  if jsonb_array_length(v_extras) > 0 then
    v_attach := v_latest_sid;
    if v_attach is null then
      select id into v_attach from public.cleaning_sessions where property_id = c_prop and submitted_by_user_id = v_uid order by cleaned_at desc limit 1;
    end if;
    if v_attach is null then return jsonb_build_object('ok', false, 'reason', 'extra_needs_a_clean'); end if;
  end if;

  -- 6. write: the extras become claims, then the request, then the links
  for v_e in select value from jsonb_array_elements(v_extras) loop
    insert into public.cleaning_expense_claims(property_id, cleaning_session_id, submitted_by_user_id, expense_date, description, amount, receipt_path)
    values (c_prop, v_attach, v_uid, (now() at time zone 'Asia/Manila')::date, v_e->>'description', (v_e->>'amount')::numeric, v_e->>'receipt_path')
    returning id into v_cid;
    v_claim_ids := v_claim_ids || v_cid;
    v_claims := v_claims || jsonb_build_object('kind', 'claim', 'claim_id', v_cid, 'date', (now() at time zone 'Asia/Manila')::date,
      'description', v_e->>'description', 'amount', (v_e->>'amount')::numeric, 'receipt', (v_e->>'receipt_path') is not null);
  end loop;
  v_lines := v_cleans || v_claims;
  insert into public.staff_pay_requests(property_id, payee_user_id, payee_name, idempotency_key, lines, total_amount)
  values (c_prop, v_uid, v_name, p_idempotency_key, v_lines, v_total) returning * into v_req;
  update public.cleaning_sessions set pay_request_id = v_req.id where id = any(v_clean_ids);
  update public.cleaning_expense_claims set pay_request_id = v_req.id where id = any(v_claim_ids);

  return jsonb_build_object('ok', true, 'request_id', v_req.id, 'ref', v_req.ref, 'status', v_req.status, 'total', v_req.total_amount,
                            'payee_name', v_req.payee_name, 'lines', v_req.lines, 'finance_message_id', null);
end $$;

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

drop function if exists public.staff_report_reminder_sent_v1(uuid, date, smallint);
drop function if exists public.staff_report_reminder_release_v1(uuid, date, smallint);
drop function if exists public.staff_report_reminder_claim_v1(uuid, date, smallint);
drop function if exists public.staff_report_reminders_due_v1(timestamptz);
drop table if exists public.staff_report_reminders;
drop function if exists public.staff_pay_request_create_v2(jsonb, uuid[], jsonb, jsonb, text);

revoke all on function public.staff_pay_request_create_v1(jsonb, uuid[], jsonb, text) from public, anon;
grant execute on function public.staff_pay_request_create_v1(jsonb, uuid[], jsonb, text) to authenticated;
revoke all on function public.staff_pay_candidates_v1() from public, anon;
grant execute on function public.staff_pay_candidates_v1() to authenticated, service_role;

commit;
