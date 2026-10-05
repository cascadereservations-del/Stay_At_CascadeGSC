-- Session 70 (SPEC-37, D-296.4, D-298): release staff_pay_requests_20261005. A staff member picks her unpaid cleans and expense
-- claims in the Cascade Staff app; the request is posted to Finance as a photo card with an amount QR; Finance pays, says so,
-- sends the transfer screenshot; a matching screenshot (or an explicit "amount is right" tap) settles the EXISTING ledger.
--   cleaner_rate_schedule.transport_rate  PHP 150 per clean, a per-clean toggle from the 2026-09-30 row (500/1000/150); null on
--                                         the 650 era so a 650 base can never take a second 150 (the double-pay trap).
--   staff_details.payout_qrph             the decoded QR Ph payload of a person's payout account. Written only through
--                                         save_staff_details_v1 (history stores a masked marker, never the payload); read by
--                                         notify-cleaner-payment through a column grant for service_role. The value is NOT here.
--   staff_pay_requests                    one row per request: lines snapshot, card state, proof, who paid. service_role only.
--   cleaning_sessions / cleaning_expense_claims .pay_request_id   the lock; moves only inside the definer RPCs (guard trigger).
--   cleaning_expense_claims.receipt_path  optional receipt photo (private cleaning-photos bucket).
--   staff_pay_rate_v1 / staff_pay_settle_v1   internal helpers, no grant to any API role.
--   staff_pay_candidates_v1 / staff_pay_request_create_v1   staff app (authenticated, submit_cleaning).
--   telegram_staff_pay_step_v1            Telegram taps and the screenshot (service_role only).
--   save_staff_details_v1                 live body (md5(prosrc) aff77cec89cc6b9130a6e41c0014819a, read 2026-10-05) plus one patch
--                                         key, payout_qrph, and a masked history snapshot.
-- No new telegram_pending kind: the screenshot question rides on awaiting_reply (flow payreq_proof).
-- Ledger rows are identical to bookCleaningFee's (cleanfee:<session>) and the claim path (claim:<id>): no second ledger.

begin;

-- 3.1 Rate: transport is its own rate from 2026-09-30 (D-298.1) ---------------------------------------------------------------
alter table public.cleaner_rate_schedule add column if not exists transport_rate numeric(10,2) check (transport_rate is null or transport_rate >= 0);
comment on column public.cleaner_rate_schedule.transport_rate is
  'D-296.4: per-clean transport allowance, added only when staff tick it in a payment request. Null = the base already includes transport (the 650 era), so no toggle.';
-- The properties guard keeps a baseline database (CI) without production rows from failing the foreign key.
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150,
  'D-296.4 / D-298.1 (2026-10-04): after the last 650 payment (Sep 28 check-out), PHP 500 per turnover or mid-stay, PHP 1,000 per deep clean; PHP 150 transport is a per-clean toggle (650 only when it applies). SPEC-37.'
where exists (select 1 from public.properties where id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
  and not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');

-- 3.2 Payout QR payload ---------------------------------------------------------------------------------------------------------
alter table public.staff_details add column if not exists payout_qrph text
  check (payout_qrph is null or (payout_qrph ~ '^000201' and payout_qrph ~ '6304[0-9A-F]{4}$' and char_length(payout_qrph) <= 512));
comment on column public.staff_details.payout_qrph is
  'SPEC-37: the decoded QR Ph payload of this person''s payout account (contains the account number). Read only by notify-cleaner-payment (service role) to rebuild an amount-set QR per request. Never logged, never in a repo or the vault.';
-- staff_details was created with every grant revoked from service_role, so the poster needs this one column pair.
grant select (user_id, payout_qrph) on public.staff_details to service_role;

-- 3.3 The request and the two links ---------------------------------------------------------------------------------------------
create table if not exists public.staff_pay_requests (
  id uuid primary key default gen_random_uuid(),
  ref text generated always as (upper(left(id::text, 8))) stored,
  property_id uuid not null references public.properties(id),
  payee_user_id uuid not null references public.staff_access_profiles(user_id),
  payee_name text not null,
  idempotency_key text not null check (char_length(idempotency_key) between 8 and 80),
  status text not null default 'requested' check (status in ('requested','paying','paid','cancelled')),
  lines jsonb not null check (jsonb_typeof(lines) = 'array' and jsonb_array_length(lines) between 1 and 20),
  total_amount numeric(12,2) not null check (total_amount > 0),
  finance_chat_id bigint, finance_message_id bigint, ops_chat_id bigint, ops_message_id bigint,
  paying_by_tg bigint, paying_by_name text, paying_at timestamptz,
  sent_said_at timestamptz,
  proof_file_unique_id text, proof_file_id text, proof_sha256 text,
  proof_amount numeric(12,2), proof_reference text, proof_read jsonb,
  proof_verdict text check (proof_verdict is null or proof_verdict in ('match','override')),
  paid_at timestamptz, paid_by_tg bigint, paid_by_name text,
  paid_by_user_id uuid references public.staff_access_profiles(user_id), -- set when the Telegram id maps (D-298.2)
  cancelled_at timestamptz, cancelled_by_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (payee_user_id, idempotency_key),
  constraint staff_pay_paid_needs_proof check (status <> 'paid' or (
    proof_file_unique_id is not null and proof_sha256 is not null and proof_verdict is not null
    and paid_at is not null and paid_by_name is not null))
);
create unique index if not exists staff_pay_proof_file_uq on public.staff_pay_requests(proof_file_unique_id) where proof_file_unique_id is not null;
create unique index if not exists staff_pay_proof_sha_uq  on public.staff_pay_requests(proof_sha256) where proof_sha256 is not null;
create unique index if not exists staff_pay_proof_ref_uq  on public.staff_pay_requests(proof_reference) where proof_reference is not null;
create index if not exists staff_pay_open_idx on public.staff_pay_requests(property_id, created_at desc) where status in ('requested','paying');
alter table public.staff_pay_requests enable row level security;
revoke all on public.staff_pay_requests from public, anon, authenticated;
grant all on public.staff_pay_requests to service_role;
drop trigger if exists set_staff_pay_requests_updated_at on public.staff_pay_requests;
create trigger set_staff_pay_requests_updated_at before update on public.staff_pay_requests for each row execute function public.set_updated_at();
drop trigger if exists admin_audit_row on public.staff_pay_requests;
create trigger admin_audit_row after insert or update on public.staff_pay_requests for each row execute function public.admin_audit_row_v1();
comment on table public.staff_pay_requests is
  'SPEC-37 / D-296..D-298: a staff payment request. lines is the immutable snapshot the cards are drawn from. PAID is impossible without a stored screenshot (staff_pay_paid_needs_proof).';

alter table public.cleaning_sessions       add column if not exists pay_request_id uuid references public.staff_pay_requests(id) on delete set null;
alter table public.cleaning_expense_claims add column if not exists pay_request_id uuid references public.staff_pay_requests(id) on delete set null;
create index if not exists cleaning_sessions_pay_request_idx on public.cleaning_sessions(pay_request_id) where pay_request_id is not null;
create index if not exists cleaning_claims_pay_request_idx  on public.cleaning_expense_claims(pay_request_id) where pay_request_id is not null;
-- D-298.3: optional, preferred receipt photo. Path in the private cleaning-photos bucket, uploaded by the existing upload-photo function.
alter table public.cleaning_expense_claims add column if not exists receipt_path text
  check (receipt_path is null or receipt_path ~ '^6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/[0-9a-f-]{36}/');

-- cleaning_staff_update lets a cleaner UPDATE her own session rows (any column) and cleaning_staff_insert lets her INSERT one.
-- The lock must only move inside the definer RPCs, which run as their owner.
create or replace function public.cleaning_sessions_pay_request_guard() returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user in ('anon', 'authenticated') then -- only the API roles can write directly; the definer RPCs run as their owner
    if tg_op = 'INSERT' then
      if new.pay_request_id is not null then
        raise exception using errcode = '42501', message = 'pay_request_id moves only through the payment request RPCs';
      end if;
    elsif new.pay_request_id is distinct from old.pay_request_id then
      raise exception using errcode = '42501', message = 'pay_request_id moves only through the payment request RPCs';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists cleaning_sessions_pay_request_guard on public.cleaning_sessions;
create trigger cleaning_sessions_pay_request_guard before insert or update of pay_request_id on public.cleaning_sessions
  for each row execute function public.cleaning_sessions_pay_request_guard();

-- 4. RPCs -----------------------------------------------------------------------------------------------------------------------

-- The rate row in force on a date: base for turnover and mid-stay, general (deep clean) and the optional transport.
create or replace function public.staff_pay_rate_v1(p_date date)
returns table(regular numeric, general numeric, transport numeric)
language sql stable security definer set search_path = '' as $$
  select r.regular_rate, coalesce(r.general_rate, r.regular_rate), r.transport_rate
    from public.cleaner_rate_schedule r
   where r.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and r.effective_from <= p_date
   order by r.effective_from desc limit 1;
$$;
revoke all on function public.staff_pay_rate_v1(date) from public, anon, authenticated, service_role;

create or replace function public.staff_pay_candidates_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
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
    from (select cs.id, cs.cleaning_type, cs.cleaned_at, coalesce(cs.checkout_date, cs.checkin_date, cs.cleaned_at::date) as d
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
end $$;
revoke all on function public.staff_pay_candidates_v1() from public, anon;
grant execute on function public.staff_pay_candidates_v1() to authenticated;

-- Validates everything first and writes last, so every {ok:false} leaves no row behind.
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
    v_date := coalesce(v_s.checkout_date, v_s.checkin_date, v_s.cleaned_at::date);
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
revoke all on function public.staff_pay_request_create_v1(jsonb, uuid[], jsonb, text) from public, anon;
grant execute on function public.staff_pay_request_create_v1(jsonb, uuid[], jsonb, text) to authenticated;

-- Settle: pass 1 locks and checks every session and claim and refuses the whole settle on any conflict (nothing written);
-- pass 2 writes the same ledger rows bookCleaningFee and the claim path write, then the request. The caller holds the request lock.
create or replace function public.staff_pay_settle_v1(p_id uuid, p_actor_tg bigint, p_actor text, p_verdict text, p_proof jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_r public.staff_pay_requests%rowtype;
  v_l jsonb; v_s public.cleaning_sessions%rowtype; v_c public.cleaning_expense_claims%rowtype;
  v_txn uuid; v_uid uuid; v_label text;
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
              'Telegram: ' || p_actor)
      returning id into v_txn;
      update public.cleaning_sessions set fee_amount = (v_l->>'amount')::numeric, fee_paid_at = now(), fee_txn_id = v_txn where id = v_s.id;
    else
      select * into v_c from public.cleaning_expense_claims where id = (v_l->>'claim_id')::uuid;
      insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
      values (v_r.property_id, 'expense', 'supplies', 'confirmed', 'cleaner_fee', (v_l->>'amount')::numeric, v_r.payee_name, v_c.expense_date,
              'claim:' || v_c.id,
              'Staff expense - ' || v_c.description || '. Pay request ' || v_r.ref || '.',
              'Telegram: ' || p_actor);
      update public.cleaning_expense_claims
         set status = 'paid', reviewed_at = now(), reviewed_by_user_id = v_uid,
             review_note = 'Paid in request ' || v_r.ref || ', confirmed by ' || p_actor || ' in Telegram'
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
revoke all on function public.staff_pay_settle_v1(uuid, bigint, text, text, jsonb) from public, anon, authenticated, service_role;

create or replace function public.telegram_staff_pay_step_v1(p_request_id uuid, p_step text, p_actor_tg bigint, p_actor_name text, p_proof jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_r public.staff_pay_requests%rowtype;
  v_actor text := coalesce(nullif(btrim(p_actor_name), ''), 'Finance');
  v_other text; v_verdict text; v_status text;
begin
  select * into v_r from public.staff_pay_requests where id = p_request_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  case p_step
    when 'pay' then
      if v_r.status <> 'requested' then return jsonb_build_object('ok', false, 'reason', 'not_open', 'status', v_r.status, 'ref', v_r.ref); end if;
      update public.staff_pay_requests set status = 'paying', paying_by_tg = p_actor_tg, paying_by_name = v_actor, paying_at = now() where id = v_r.id;
      v_status := 'paying';

    when 'not_sent' then
      if v_r.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', v_r.status, 'ref', v_r.ref); end if;
      if v_r.proof_file_unique_id is not null then return jsonb_build_object('ok', false, 'reason', 'proof_already_sent', 'status', v_r.status, 'ref', v_r.ref); end if;
      update public.staff_pay_requests set status = 'requested', paying_by_tg = null, paying_by_name = null, paying_at = null, sent_said_at = null where id = v_r.id;
      v_status := 'requested';

    when 'sent' then
      if v_r.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', v_r.status, 'ref', v_r.ref); end if;
      update public.staff_pay_requests set sent_said_at = coalesce(sent_said_at, now()) where id = v_r.id;
      v_status := 'paying';

    when 'proof' then
      if v_r.status <> 'paying' or v_r.sent_said_at is null then
        return jsonb_build_object('ok', false, 'reason', 'not_waiting_for_proof', 'status', v_r.status, 'ref', v_r.ref);
      end if;
      if p_proof is null or coalesce(p_proof->>'file_unique_id', '') = '' or coalesce(p_proof->>'sha256', '') = '' then
        return jsonb_build_object('ok', false, 'reason', 'bad_proof', 'status', v_r.status, 'ref', v_r.ref);
      end if;
      v_verdict := coalesce(nullif(p_proof->>'verdict', ''), 'unread');
      select o.ref into v_other from public.staff_pay_requests o
       where o.id <> v_r.id
         and (o.proof_file_unique_id = p_proof->>'file_unique_id' or o.proof_sha256 = p_proof->>'sha256'
              or (nullif(p_proof->>'reference', '') is not null and o.proof_reference = p_proof->>'reference'))
       limit 1;
      if found then
        return jsonb_build_object('ok', false, 'reason', 'duplicate_proof', 'other_ref', v_other, 'status', v_r.status, 'ref', v_r.ref);
      end if;
      if v_verdict = 'match' then
        return public.staff_pay_settle_v1(v_r.id, p_actor_tg, v_actor, 'match', p_proof);
      end if;
      update public.staff_pay_requests set
        proof_file_unique_id = p_proof->>'file_unique_id', proof_file_id = nullif(p_proof->>'file_id', ''), proof_sha256 = p_proof->>'sha256',
        proof_amount = case when jsonb_typeof(p_proof->'amount') = 'number' then (p_proof->>'amount')::numeric end,
        proof_reference = nullif(p_proof->>'reference', ''),
        proof_read = jsonb_build_object('read', p_proof->'read', 'verdict', v_verdict)
       where id = v_r.id;
      return jsonb_build_object('ok', true, 'status', 'paying', 'ref', v_r.ref, 'total', v_r.total_amount, 'verdict', v_verdict);

    when 'override' then
      if v_r.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', v_r.status, 'ref', v_r.ref); end if;
      if v_r.proof_file_unique_id is null then return jsonb_build_object('ok', false, 'reason', 'no_screenshot', 'status', v_r.status, 'ref', v_r.ref); end if;
      return public.staff_pay_settle_v1(v_r.id, p_actor_tg, v_actor, 'override', null);

    when 'cancel' then
      if v_r.status = 'paying' and v_r.sent_said_at is not null then
        return jsonb_build_object('ok', false, 'reason', 'money_may_be_sent', 'status', v_r.status, 'ref', v_r.ref);
      end if;
      if v_r.status not in ('requested', 'paying') then
        return jsonb_build_object('ok', false, 'reason', 'not_open', 'status', v_r.status, 'ref', v_r.ref);
      end if;
      update public.staff_pay_requests set status = 'cancelled', cancelled_at = now(), cancelled_by_name = v_actor where id = v_r.id;
      update public.cleaning_sessions set pay_request_id = null where pay_request_id = v_r.id;
      update public.cleaning_expense_claims set pay_request_id = null where pay_request_id = v_r.id;
      v_status := 'cancelled';

    else
      return jsonb_build_object('ok', false, 'reason', 'bad_step');
  end case;

  return jsonb_build_object('ok', true, 'status', v_status, 'ref', v_r.ref, 'total', v_r.total_amount);
end $$;
revoke all on function public.telegram_staff_pay_step_v1(uuid, text, bigint, text, jsonb) from public, anon, authenticated;
grant execute on function public.telegram_staff_pay_step_v1(uuid, text, bigint, text, jsonb) to service_role;

-- 7.E save_staff_details_v1: the live body plus one patch key. History stores a masked marker for the QR, never the payload,
-- because the audit feed shows before/after states to owner and admin and the payload carries an account number. -----------------
create or replace function public.save_staff_details_v1(p_user_id uuid, p_patch jsonb, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_row public.staff_details%rowtype;
begin
  if not public.current_staff_authorized('manage_staff') then
    raise exception using errcode = '42501', message = 'manage_staff denied';
  end if;
  if not exists (select 1 from public.staff_access_profiles where user_id = p_user_id) then
    raise exception using errcode = 'P0002', message = 'staff member not found';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception using errcode = '22023', message = 'patch must be an object'; end if;
  insert into public.staff_details(user_id) values (p_user_id) on conflict (user_id) do nothing;
  select * into v_row from public.staff_details where user_id = p_user_id for update;
  if p_expected_version is not null and v_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'stale version: staff details changed since they were loaded';
  end if;
  v_before := (to_jsonb(v_row) - 'payout_qrph') || jsonb_build_object('payout_qrph', case when v_row.payout_qrph is null then null else '[set ' || right(v_row.payout_qrph, 4) || ']' end);
  update public.staff_details set
    contact_number = case when p_patch ? 'contact_number' then nullif(btrim(p_patch->>'contact_number'), '') else contact_number end,
    alternate_contact = case when p_patch ? 'alternate_contact' then nullif(btrim(p_patch->>'alternate_contact'), '') else alternate_contact end,
    address = case when p_patch ? 'address' then nullif(btrim(p_patch->>'address'), '') else address end,
    id_type = case when p_patch ? 'id_type' then nullif(p_patch->>'id_type', '') else id_type end,
    id_number = case when p_patch ? 'id_number' then nullif(btrim(p_patch->>'id_number'), '') else id_number end,
    id_drive_url = case when p_patch ? 'id_drive_url' then nullif(btrim(p_patch->>'id_drive_url'), '') else id_drive_url end,
    emergency_contact_name = case when p_patch ? 'emergency_contact_name' then nullif(btrim(p_patch->>'emergency_contact_name'), '') else emergency_contact_name end,
    emergency_contact_number = case when p_patch ? 'emergency_contact_number' then nullif(btrim(p_patch->>'emergency_contact_number'), '') else emergency_contact_number end,
    start_date = case when p_patch ? 'start_date' then nullif(p_patch->>'start_date', '')::date else start_date end,
    fee_turnover = case when p_patch ? 'fee_turnover' then nullif(p_patch->>'fee_turnover', '')::numeric else fee_turnover end,
    fee_transport = case when p_patch ? 'fee_transport' then nullif(p_patch->>'fee_transport', '')::numeric else fee_transport end,
    fee_deep_clean = case when p_patch ? 'fee_deep_clean' then nullif(p_patch->>'fee_deep_clean', '')::numeric else fee_deep_clean end,
    payout_qrph = case when p_patch ? 'payout_qrph' then nullif(btrim(p_patch->>'payout_qrph'), '') else payout_qrph end,
    updated_by = auth.uid(), updated_at = now(), version = version + 1
  where user_id = p_user_id returning * into v_row;
  insert into public.staff_details_history(user_id, changed_by, before_state, after_state, reason)
  values (p_user_id, auth.uid(), v_before,
          (to_jsonb(v_row) - 'payout_qrph') || jsonb_build_object('payout_qrph', case when v_row.payout_qrph is null then null else '[set ' || right(v_row.payout_qrph, 4) || ']' end),
          p_reason);
  return jsonb_build_object('ok', true, 'userId', p_user_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;
revoke all on function public.save_staff_details_v1(uuid, jsonb, integer, text) from public, anon, service_role;
grant execute on function public.save_staff_details_v1(uuid, jsonb, integer, text) to authenticated;

-- forward check: everything this release adds is present and closed to the API roles
do $$
begin
  if to_regclass('public.staff_pay_requests') is null then raise exception 'staff_pay_requests missing'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.staff_pay_requests'::regclass) then raise exception 'staff_pay_requests RLS not enabled'; end if;
  if has_function_privilege('anon', 'public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)', 'execute') then raise exception 'anon can create a pay request'; end if;
  if has_function_privilege('authenticated', 'public.telegram_staff_pay_step_v1(uuid,text,bigint,text,jsonb)', 'execute') then raise exception 'authenticated can run the Telegram step'; end if;
  if not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'save_staff_details_v1' and prosrc like '%payout_qrph%') then raise exception 'save_staff_details_v1 lacks payout_qrph'; end if;
end $$;

commit;
