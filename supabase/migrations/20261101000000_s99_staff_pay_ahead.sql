-- 20261101000000_s99_staff_pay_ahead.sql
-- Session 99, lane SQL: release s99_staff_pay_ahead_20261101 (contract: Cascade/docs/s99/CONTRACT-staff-pay-ahead.md, SQL lane; owner decision D-348).
-- A cleaner may include a check-out with no report yet in her OWN pay request, and the server keeps the reminder ledger for the phone push.
-- (1) staff_pay_request_create_v2(sessions, claim_ids, extras, advance, key): v1's body plus the advance block of staff_pay_admin_create_v2 (s94). Input
--     [{checkout_date:'YYYY-MM-DD', transport:boolean|null}]; per date: lock 'staff_pay_advance:'||date, must be in get_missed_cleanings(prop, 30) with a named guest
--     ('advance_not_owed'), held by no live request's advance line ('advance_taken' + ref), priced by s_pay_price_v1('turnover', date) ('no_rate', 'transport_not_allowed'),
--     a repeated date is 'bad_request'. Line {kind:'advance', checkout_date, date, type:'turnover', base, transport, amount, guest(first name)}; the 20-line cap and no_lines
--     count advance lines. Payee = auth.uid(). v1 is now a wrapper passing '[]'. The advance line then behaves exactly as the admin's: settle (cleanadv expense row) and
--     cleaning_sessions_link_advance (the report joins the request when filed) are s94 and need no change.
-- (2) staff_pay_candidates_v1 adds 'advance' [{checkout_date, base, transport}]: the same dates create_v2 would accept, no guest names. Every other key is unchanged.
-- (3) staff_report_reminders (request_id, checkout_date, stage 1|3, payee_user_id, claimed_at, sent_at): RLS on, no policy, service_role only.
-- (4) staff_report_reminders_due_v1(p_now): live requests (last 30 days) whose advance line still has no report (s_advance_session_v1 null); stage 1 from 1 day after the request,
--     stage 3 from 3 days, only the highest due stage with no row yet (never stage 1 after stage 3 was claimed); only 08:00-19:59 Manila; owed_dates = every date the payee still owes.
-- (5) staff_report_reminder_claim_v1 / _release_v1 / _sent_v1: the claim-before-send trio the push drain uses. service_role only. (A1) A claim never sent and older than 1 hour counts as not taken: due_v1 returns it again and claim_v1 takes it over.
-- Lock order in create_v2 (S2): idempotency lock -> cleans (id order, FOR UPDATE) -> attach session (FOR KEY SHARE, only when extras are present) -> per-date advance locks (date order) -> claims.
-- Guards: each replaced body must be the live one this was cut from (md5 of prosrc, CR stripped), else 55000 and nothing changes. staff_pay_request_create_v1 is the live body: its
-- 20261005 text with cleaned_at::date patched in place to the Manila form by 20261007110000 (the same patch reproduces the live candidates md5 6cdafb86..., checked offline);
-- staff_pay_candidates_v1 is the s94 body. Grants restated on every function (ML-21). To undo apply supabase/rollbacks/20261101_s99_staff_pay_ahead.sql.

begin;

do $$
declare v_got text; r record;
begin
  for r in select * from (values
      ('public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)', '374416fd95fcc1c0668ab5b486eb2f2d'),
      ('public.staff_pay_candidates_v1()', '2db19457e15a84197caef16c1d2f4123')) v(sig, md) loop
    select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v_got is distinct from r.md then
      raise exception 's99 staff pay ahead: % is not the body this release was cut from (md5 %): re-cut it from the live body', r.sig, v_got using errcode = '55000';
    end if;
  end loop;
  foreach v_got in array array['public.s_advance_session_v1(uuid,date)', 'public.s_pay_price_v1(text,date)', 'public.get_missed_cleanings(uuid,integer)', 'public.staff_pay_admin_create_v2(uuid,jsonb,uuid[],jsonb,text)'] loop
    if to_regprocedure(v_got) is null then
      raise exception 's99 staff pay ahead: % is missing (s94 / s82 not applied?)', v_got using errcode = '55000';
    end if;
  end loop;
end $$;

-- 1. create v2 (v1 body + advance block) and the v1 wrapper ----------------------------------------------------------------------------------------
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
  if jsonb_array_length(v_extras) > 0 then
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

create or replace function public.staff_pay_request_create_v1(p_sessions jsonb, p_claim_ids uuid[], p_extras jsonb, p_idempotency_key text)
returns jsonb
language sql volatile security definer set search_path = '' as $$
  select public.staff_pay_request_create_v2(p_sessions, p_claim_ids, p_extras, '[]'::jsonb, p_idempotency_key);
$$;

-- 2. candidates: the advance list --------------------------------------------------------------------------------------------------------------------
create or replace function public.staff_pay_candidates_v1()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_uid uuid := auth.uid();
  v_name text; v_sessions jsonb; v_claims jsonb; v_missing jsonb; v_reqs jsonb; v_owed jsonb; v_adv jsonb;
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

  -- S99 (D-348): check-outs she may include in her own request before the report exists. Same rule create_v2 enforces: in get_missed_cleanings (30 days) with a named guest,
  -- held by no live request's advance line, turnover rate on that date (a date with no rate row is left out). Dates and prices only, no guest names (D-289 spirit).
  select coalesce(jsonb_agg(jsonb_build_object('checkout_date', m.d, 'base', r.base, 'transport', r.transport) order by m.d), '[]'::jsonb)
    into v_adv
    from (select distinct g.checkout_date d from public.get_missed_cleanings(c_prop, 30) g where nullif(btrim(coalesce(g.guest_name, '')), '') is not null) m
    cross join lateral public.s_pay_price_v1('turnover', m.d) r
   where not exists (select 1 from public.staff_pay_requests q, jsonb_array_elements(q.lines) l
                      where q.property_id = c_prop and q.status <> 'cancelled' and l ->> 'kind' = 'advance' and l ->> 'checkout_date' = m.d::text);

  return jsonb_build_object('ok', true, 'payee_name', coalesce(v_name, 'Staff'), 'sessions', v_sessions, 'claims', v_claims,
                            'missing_reports', v_missing, 'requests', v_reqs, 'reports_owed', v_owed, 'advance', v_adv);
end $$;

-- 3. reminder ledger ------------------------------------------------------------------------------------------------------------------------------
create table if not exists public.staff_report_reminders (
  request_id uuid not null references public.staff_pay_requests(id) on delete cascade,
  checkout_date date not null,
  stage smallint not null check (stage in (1, 3)),
  payee_user_id uuid not null,
  claimed_at timestamptz not null default now(),
  sent_at timestamptz,
  primary key (request_id, checkout_date, stage)
);
alter table public.staff_report_reminders enable row level security;
revoke all on table public.staff_report_reminders from public, anon, authenticated, service_role; -- S1 (ML-21): prod default privileges hand service_role ALL (truncate, references, trigger) on a new table
grant select, insert, update, delete on table public.staff_report_reminders to service_role;
comment on table public.staff_report_reminders is 'S99 (D-348): one row per (request, checkout date, stage 1|3) claimed before a "send the cleaning report" push; sent_at is stamped after the push. Rows go with the request. RLS on, no policy: service_role only.';

-- 4. what is due -------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.staff_report_reminders_due_v1(p_now timestamptz default now())
returns table(request_id uuid, ref text, payee_user_id uuid, checkout_date date, stage smallint, owed_dates date[])
language sql stable security definer set search_path = '' as $$
  with owed as (
    select q.id as rid, q.ref as qref, q.payee_user_id as pid, q.created_at as made_at, (l.value ->> 'checkout_date')::date as d
      from public.staff_pay_requests q cross join lateral jsonb_array_elements(q.lines) l
     where q.status <> 'cancelled' and l.value ->> 'kind' = 'advance'
       and q.created_at > p_now - interval '30 days' and q.created_at <= p_now
       and public.s_advance_session_v1(q.id, (l.value ->> 'checkout_date')::date) is null),
  due as (
    select o.*, (case when p_now >= o.made_at + interval '3 days' then 3 when p_now >= o.made_at + interval '1 day' then 1 end)::smallint as stg
      from owed o)
  select u.rid, u.qref, u.pid, u.d, u.stg,
         (select array_agg(distinct o2.d order by o2.d) from owed o2 where o2.pid = u.pid)
    from due u
   where u.stg is not null
     and extract(hour from p_now at time zone 'Asia/Manila') between 8 and 19
     and not exists (select 1 from public.staff_report_reminders x where x.request_id = u.rid and x.checkout_date = u.d and x.stage >= u.stg
                      and not (x.sent_at is null and x.claimed_at < p_now - interval '1 hour')) -- A1: an unsent claim older than an hour counts as not taken
   order by u.pid, u.rid, u.d;
$$;

-- 5. claim before send ------------------------------------------------------------------------------------------------------------------------------
create or replace function public.staff_report_reminder_claim_v1(p_request_id uuid, p_checkout_date date, p_stage smallint)
returns boolean
language sql volatile security definer set search_path = '' as $$
  with i as (
    insert into public.staff_report_reminders(request_id, checkout_date, stage, payee_user_id)
    select r.id, p_checkout_date, p_stage, r.payee_user_id from public.staff_pay_requests r where r.id = p_request_id
    on conflict (request_id, checkout_date, stage) do update set claimed_at = now(), payee_user_id = excluded.payee_user_id
      where public.staff_report_reminders.sent_at is null and public.staff_report_reminders.claimed_at < now() - interval '1 hour'
    returning 1) -- A1: true when inserted, or taken over from a claim that was never sent and is over an hour old
  select exists (select 1 from i);
$$;
create or replace function public.staff_report_reminder_release_v1(p_request_id uuid, p_checkout_date date, p_stage smallint)
returns void
language sql volatile security definer set search_path = '' as $$
  delete from public.staff_report_reminders where request_id = p_request_id and checkout_date = p_checkout_date and stage = p_stage and sent_at is null;
$$;
create or replace function public.staff_report_reminder_sent_v1(p_request_id uuid, p_checkout_date date, p_stage smallint)
returns void
language sql volatile security definer set search_path = '' as $$
  update public.staff_report_reminders set sent_at = now() where request_id = p_request_id and checkout_date = p_checkout_date and stage = p_stage and sent_at is null;
$$;

-- 6. grants: state the end state (ML-21) ---------------------------------------------------------------------------------------------------------------
revoke all on function public.staff_pay_request_create_v2(jsonb, uuid[], jsonb, jsonb, text) from public, anon, authenticated, service_role;
grant execute on function public.staff_pay_request_create_v2(jsonb, uuid[], jsonb, jsonb, text) to authenticated;
revoke all on function public.staff_pay_request_create_v1(jsonb, uuid[], jsonb, text) from public, anon, authenticated, service_role;
grant execute on function public.staff_pay_request_create_v1(jsonb, uuid[], jsonb, text) to authenticated;
revoke all on function public.staff_pay_candidates_v1() from public, anon, authenticated, service_role;
grant execute on function public.staff_pay_candidates_v1() to authenticated, service_role;
revoke all on function public.staff_report_reminders_due_v1(timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.staff_report_reminders_due_v1(timestamptz) to service_role;
revoke all on function public.staff_report_reminder_claim_v1(uuid, date, smallint) from public, anon, authenticated, service_role;
grant execute on function public.staff_report_reminder_claim_v1(uuid, date, smallint) to service_role;
revoke all on function public.staff_report_reminder_release_v1(uuid, date, smallint) from public, anon, authenticated, service_role;
grant execute on function public.staff_report_reminder_release_v1(uuid, date, smallint) to service_role;
revoke all on function public.staff_report_reminder_sent_v1(uuid, date, smallint) from public, anon, authenticated, service_role;
grant execute on function public.staff_report_reminder_sent_v1(uuid, date, smallint) to service_role;

commit;
