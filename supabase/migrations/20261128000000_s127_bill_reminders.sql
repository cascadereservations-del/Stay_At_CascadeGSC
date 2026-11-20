-- Session 127, lane B1 (SQL): release s127_bill_reminders_20261128. Contract: docs/s127/CONTRACT-B.md "Rules both lanes rely on", "Lane B1" and Addendum 1.
-- Four monthly bills (electric, water, internet, netflix) get a row on pay day, a Finance card (lane B2) and ONE proof-backed expense row when paid.
--
--   app_settings 'bill_schedule'                inserted only when absent: reading_day 21, pay_day 27, nudge_day 28 and the four bills. Account numbers, payee name, number and note are EMPTY here; the release block fills them
--                                                from a local file. Every function below reads it through bill_schedule_cfg_v1 and falls back key by key (a key of the wrong JSON type never raises).
--   app_settings policies                       The key holds account numbers and a payee number, but its name does not look secret, so the existing anon / staff read policies would show it to anyone with the public key.
--                                                Two RESTRICTIVE select policies hide that one key from anon and from every signed-in account except manage_staff (owner, admin). Every other key is untouched.
--   transactions_source_check                   gains 'bill' (the check listed eleven values live, refund among them, and 'bill' was not one). Rebuilt only after every literal the live check holds is shown to be in the known list, else 55000.
--                                                The new check is added NOT VALID and then validated in the same guarded block (the file is one transaction, so the table lock is still held to commit).
--   utility_bills                               one row per property, kind and month. service_role only. PAID is impossible without a stored screenshot or the typed override (utility_bills_paid_needs_proof).
--   bill_due_open_v1(uuid, date)                service_role. From pay_day opens the missing rows of that month and returns {new, nudge}; the estimate of a meter bill is the forecast of the cycle that CLOSED in that
--                                                month (p_on moved to that month's cycle day), not of the cycle that starts after it. nudge = rows still due or paying, once, on or after nudge_day (stamps nudged_at).
--                                                Catch-up: before pay_day it opens the PREVIOUS month's missing rows (the step missed the 27th to month end); it never nudges there.
--   bill_step_v1(uuid, text, bigint, text, jsonb) service_role. pay | cancel | skip | paid. paid writes the one transactions row (external_ref bill:<kind>:<period>, found again by that ref).
--                                                Actor gate: see the comment on the function (the telegram_staff_pay_step_v1 gate is the Finance group; SQL refuses a null id and a mapped, non-approving or disabled profile).
--                                                While a bill is paying, only the person who tapped pay may settle or skip it (bad_step for anyone else). A screenshot that settled a staff payment cannot settle a bill (duplicate_proof).
--                                                An existing ledger row for the ref is linked only when property, source 'bill' and amount all match; otherwise (and for a VOID row) 55000 with a plain message.
--   today_bills_v1(uuid)                        the lane A body plus "due": this month's rows of any status plus every unpaid (due or paying) row of any period, oldest period first (kind, label, period, status, estimate_php, paid_php).
--                                                Existing keys and gate unchanged. No account number is returned.
--   internal helpers                            bill_cfg_text_v1, bill_schedule_cfg_v1, bill_json_v1 (nobody can run them but the owner and the definer functions).
-- notices_v1 is NOT changed: the s91 body returns every active ops_notices row (audience staff or all, not expired, dated today to 30 days ahead) to every role with read_operations, and maps notice_type 'reminder' to type 'note'
--   with source 'manual' when the row has no source. Tested in supabase/tests/database/s127_bill_reminders.sql for cleaner, laundry and admin.
-- Refusal reasons of bill_step_v1: not_finance, not_found, already_paid (carries bill), bad_step, duplicate_proof, bad_amount, confirm_amount.
-- Money rule: a read amount is accepted without a question only inside a band (fixed bills: amount .. amount + 50; meter bills: half .. double the estimate); outside it bill_step_v1 answers confirm_amount unless the proof carries confirmed true.
-- Guard (55000, nothing changes): today_bills_v1 must be the lane A body or this release (md5 of prosrc, CR stripped).
-- Rollback: supabase/rollbacks/20261128_s127_bill_reminders.sql (refuses once a bill is paid or a bill ledger row exists; puts the lane A today_bills_v1 back, drops the new objects).

begin;

-- 1. guards -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.today_bills_v1(uuid)');
  if v is distinct from 'f7cfd2f8ddd001229df63601b636c5b7' and v is distinct from 'fda3eee593ec93968cddfd039c5d81f9' then
    raise exception using errcode = '55000', message = 's127 bills: public.today_bills_v1(uuid) is neither the lane A body nor this release (md5 ' || coalesce(v, 'null') || '): re-cut it from the live body';
  end if;
end $g$;

-- 2. settings ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
insert into public.app_settings(key, value)
select 'bill_schedule', '{"reading_day":21,"pay_day":27,"nudge_day":28,"bills":{"electric":{"label":"Electricity (SOCOTECO II)","account":"","account_name":""},"water":{"label":"Water (Gensan Water District)","account":"","account_name":""},"internet":{"label":"Internet","amount":1500,"pay_to_name":"","pay_to_number":"","note":""},"netflix":{"label":"Netflix","amount":449}}}'::jsonb
 where not exists (select 1 from public.app_settings a where a.key = 'bill_schedule');

-- the key is not anon-readable and not readable by cleaners: it holds account numbers (restrictive = ANDed with every permissive policy)
drop policy if exists app_settings_bill_schedule_closed_anon on public.app_settings;
create policy app_settings_bill_schedule_closed_anon on public.app_settings as restrictive for select to anon using (key <> 'bill_schedule');
drop policy if exists app_settings_bill_schedule_closed_staff on public.app_settings;
create policy app_settings_bill_schedule_closed_staff on public.app_settings as restrictive for select to authenticated
  using (key <> 'bill_schedule' or coalesce(public.current_staff_authorized('manage_staff'), false));

-- 3. the ledger accepts source 'bill' ------------------------------------------------------------------------------------------------------------------------------------------------------------
do $c$
declare
  v_def text; v_bad text;
  v_known constant text[] := array['telegram', 'ocr', 'booking', 'manual', 'import', 'airbnb', 'airbnb_email', 'airbnb_payout_email', 'direct_booking', 'cleaner_fee', 'refund'];
begin
  select pg_get_constraintdef(c.oid) into v_def from pg_constraint c where c.conrelid = 'public.transactions'::regclass and c.conname = 'transactions_source_check';
  if v_def is null or v_def like '%''bill''%' then return; end if;
  select string_agg(m[1], ', ') into v_bad from regexp_matches(v_def, '''([^'']+)''', 'g') m where m[1] <> all (v_known);
  if v_bad is not null then
    raise exception using errcode = '55000', message = 's127 bills: transactions_source_check holds values this release does not know (' || v_bad || '): re-cut the list from the live constraint';
  end if;
  execute 'alter table public.transactions drop constraint transactions_source_check';
  execute 'alter table public.transactions add constraint transactions_source_check check (source = any (array[''telegram'', ''ocr'', ''booking'', ''manual'', ''import'', ''airbnb'', ''airbnb_email'', ''airbnb_payout_email'', ''direct_booking'', ''cleaner_fee'', ''refund'', ''bill''])) not valid';
  execute 'alter table public.transactions validate constraint transactions_source_check';
end $c$;

-- 4. the table -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
create table if not exists public.utility_bills (
  id uuid primary key default gen_random_uuid(),
  ref text generated always as (upper(left(id::text, 8))) stored,
  property_id uuid not null references public.properties(id),
  kind text not null check (kind in ('electric', 'water', 'internet', 'netflix')),
  period text not null check (period ~ '^\d{4}-\d{2}$'),
  estimate_php numeric(12,2) check (estimate_php is null or estimate_php >= 0), -- null = no estimate yet (a meter bill with no counted reading); never 0
  status text not null default 'due' check (status in ('due', 'paying', 'paid', 'skipped')),
  finance_chat_id bigint, finance_message_id bigint,
  paying_by_tg bigint, paying_by_name text, paying_at timestamptz,
  proof_file_unique_id text, proof_file_id text, proof_sha256 text,
  proof_amount numeric(12,2), proof_reference text, proof_read jsonb,
  proof_verdict text check (proof_verdict is null or proof_verdict in ('read', 'typed')),
  paid_php numeric(12,2) check (paid_php is null or paid_php > 0),
  paid_at timestamptz, paid_by_tg bigint, paid_by_name text,
  txn_id uuid references public.transactions(id) on delete set null,
  nudged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (property_id, kind, period),
  constraint utility_bills_paid_needs_proof check (status <> 'paid' or (
    paid_php > 0 and paid_at is not null and paid_by_name is not null and proof_verdict is not null
    and (proof_verdict = 'typed' or proof_sha256 is not null)))
);
create unique index if not exists utility_bills_proof_file_uq on public.utility_bills(proof_file_unique_id) where proof_file_unique_id is not null;
create unique index if not exists utility_bills_proof_sha_uq  on public.utility_bills(proof_sha256) where proof_sha256 is not null;
alter table public.utility_bills enable row level security;
revoke all on public.utility_bills from public, anon, authenticated;
grant all on public.utility_bills to service_role;
drop trigger if exists set_utility_bills_updated_at on public.utility_bills;
create trigger set_utility_bills_updated_at before update on public.utility_bills for each row execute function public.set_updated_at();
drop trigger if exists admin_audit_row on public.utility_bills;
create trigger admin_audit_row after insert or update on public.utility_bills for each row execute function public.admin_audit_row_v1();
comment on table public.utility_bills is
  's127 bill reminders: one row per property, bill kind and month (period YYYY-MM, the month billed). estimate_php is what the Finance card shows before payment; paid_php is what was actually paid, read from the proof screenshot (billers add a fee). PAID is impossible without a stored screenshot or the typed override.';

-- 5. internal helpers -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- a text setting: a non-blank JSON string, else the default
create or replace function public.bill_cfg_text_v1(p_val jsonb, p_default text)
returns jsonb language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_val) = 'string' and btrim(p_val #>> '{}') <> '' then p_val else to_jsonb(p_default) end;
$$;

-- the stored setting wins key by key; a key of the wrong JSON type (or a setting that is not an object) falls back to its default. Days are cut to a whole number and held to 1..28 so every month has them.
-- Never raises. amount is null for the two meter bills.
create or replace function public.bill_schedule_cfg_v1()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'reading_day', case when jsonb_typeof(s.v -> 'reading_day') = 'number' then to_jsonb(least(28, greatest(1, trunc((s.v ->> 'reading_day')::numeric)))) else to_jsonb(21) end,
    'pay_day',     case when jsonb_typeof(s.v -> 'pay_day')     = 'number' then to_jsonb(least(28, greatest(1, trunc((s.v ->> 'pay_day')::numeric))))     else to_jsonb(27) end,
    'nudge_day',   case when jsonb_typeof(s.v -> 'nudge_day')   = 'number' then to_jsonb(least(28, greatest(1, trunc((s.v ->> 'nudge_day')::numeric))))   else to_jsonb(28) end,
    'bills', jsonb_build_object(
      'electric', jsonb_build_object('label', public.bill_cfg_text_v1(s.v #> '{bills,electric,label}', 'Electricity (SOCOTECO II)'),
                                     'account', public.bill_cfg_text_v1(s.v #> '{bills,electric,account}', ''), 'account_name', public.bill_cfg_text_v1(s.v #> '{bills,electric,account_name}', ''),
                                     'pay_to_name', to_jsonb(''::text), 'pay_to_number', to_jsonb(''::text), 'note', to_jsonb(''::text), 'amount', null),
      'water',    jsonb_build_object('label', public.bill_cfg_text_v1(s.v #> '{bills,water,label}', 'Water (Gensan Water District)'),
                                     'account', public.bill_cfg_text_v1(s.v #> '{bills,water,account}', ''), 'account_name', public.bill_cfg_text_v1(s.v #> '{bills,water,account_name}', ''),
                                     'pay_to_name', to_jsonb(''::text), 'pay_to_number', to_jsonb(''::text), 'note', to_jsonb(''::text), 'amount', null),
      'internet', jsonb_build_object('label', public.bill_cfg_text_v1(s.v #> '{bills,internet,label}', 'Internet'),
                                     'account', to_jsonb(''::text), 'account_name', to_jsonb(''::text),
                                     'pay_to_name', public.bill_cfg_text_v1(s.v #> '{bills,internet,pay_to_name}', ''), 'pay_to_number', public.bill_cfg_text_v1(s.v #> '{bills,internet,pay_to_number}', ''),
                                     'note', public.bill_cfg_text_v1(s.v #> '{bills,internet,note}', ''), 'amount', public.utility_cfg_num_v1(s.v #> '{bills,internet,amount}', to_jsonb(1500))),
      'netflix',  jsonb_build_object('label', public.bill_cfg_text_v1(s.v #> '{bills,netflix,label}', 'Netflix'),
                                     'account', to_jsonb(''::text), 'account_name', to_jsonb(''::text), 'pay_to_name', to_jsonb(''::text), 'pay_to_number', to_jsonb(''::text), 'note', to_jsonb(''::text),
                                     'amount', public.utility_cfg_num_v1(s.v #> '{bills,netflix,amount}', to_jsonb(449)))))
    from (select coalesce((select a.value from public.app_settings a where a.key = 'bill_schedule' and jsonb_typeof(a.value) = 'object'), '{}'::jsonb) v) s;
$$;

-- one bill as the Telegram lane reads it: the row's own state plus the settings text (label, account, pay-to, note; empty string when not set)
create or replace function public.bill_json_v1(b public.utility_bills)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', b.id, 'ref', b.ref, 'kind', b.kind, 'period', b.period, 'label', c -> 'bills' -> b.kind ->> 'label', 'status', b.status,
    'estimate_php', b.estimate_php, 'paid_php', b.paid_php, 'paid_at', b.paid_at, 'paid_by_name', b.paid_by_name, 'paying_by_name', b.paying_by_name,
    'finance_chat_id', b.finance_chat_id, 'finance_message_id', b.finance_message_id,
    'account', c -> 'bills' -> b.kind ->> 'account', 'account_name', c -> 'bills' -> b.kind ->> 'account_name',
    'pay_to_name', c -> 'bills' -> b.kind ->> 'pay_to_name', 'pay_to_number', c -> 'bills' -> b.kind ->> 'pay_to_number', 'note', c -> 'bills' -> b.kind ->> 'note')
    from (select public.bill_schedule_cfg_v1() c) x;
$$;

-- 6. bill_due_open_v1 -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.bill_due_open_v1(p_property_id uuid, p_on date)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cfg jsonb := public.bill_schedule_cfg_v1();
  v_ucfg jsonb := public.utility_billing_cfg_v1();
  v_pay integer := (v_cfg ->> 'pay_day')::integer;
  v_nudge integer := (v_cfg ->> 'nudge_day')::integer;
  v_period text; v_m date; v_catch boolean; v_ec date; v_wc date;
  v_ids uuid[]; v_nids uuid[]; v_new jsonb; v_nud jsonb;
begin
  if p_property_id is null or p_on is null then
    return jsonb_build_object('new', '[]'::jsonb, 'nudge', '[]'::jsonb);
  end if;
  -- on or after pay_day the month billed is this month; before it, the PREVIOUS month, and only its missing rows open (catch-up for a step that missed the 27th to month end; no nudge)
  v_catch := extract(day from p_on)::integer < v_pay;
  v_m := case when v_catch then (date_trunc('month', p_on) - interval '1 month')::date else date_trunc('month', p_on)::date end;
  v_period := to_char(v_m, 'YYYY-MM');
  if v_catch and (select count(*) from public.utility_bills b where b.property_id = p_property_id and b.period = v_period) >= 4 then
    return jsonb_build_object('new', '[]'::jsonb, 'nudge', '[]'::jsonb);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('bill_due_open:' || p_property_id::text || ':' || v_period, 0));
  -- the bill paid on pay day covers the cycle that closed in the month billed: ask the estimate about that month's cycle day (the cycle (from, to] ending on it), not about p_on, which is already in the next cycle
  v_ec := public.utility_cycle_day_v1(v_m, (v_ucfg -> 'electric' ->> 'cycle_day')::integer);
  v_wc := public.utility_cycle_day_v1(v_m, (v_ucfg -> 'water' ->> 'cycle_day')::integer);

  with ins as (
    insert into public.utility_bills(property_id, kind, period, estimate_php)
    select p_property_id, k.kind, v_period,
           case k.kind
             when 'electric' then (public.utility_bill_estimate_v1(p_property_id, v_ec) -> 'electric' ->> 'forecast_php')::numeric
             when 'water'    then (public.utility_bill_estimate_v1(p_property_id, v_wc) -> 'water' ->> 'forecast_php')::numeric
             else (v_cfg -> 'bills' -> k.kind ->> 'amount')::numeric end
      from unnest(array['electric', 'water', 'internet', 'netflix']) as k(kind)
    on conflict (property_id, kind, period) do nothing
    returning id)
  select array_agg(i.id) into v_ids from ins i;
  v_ids := coalesce(v_ids, '{}');

  -- the one second nudge: this month's rows still unpaid that this call did not just open
  if not v_catch and extract(day from p_on)::integer >= v_nudge then
    with n as (
      update public.utility_bills b set nudged_at = now()
       where b.property_id = p_property_id and b.period = v_period and b.status in ('due', 'paying') and b.nudged_at is null and b.id <> all (v_ids)
      returning b.id)
    select array_agg(n.id) into v_nids from n;
  end if;
  v_nids := coalesce(v_nids, '{}');

  select coalesce(jsonb_agg(public.bill_json_v1(b) order by array_position(array['electric', 'water', 'internet', 'netflix'], b.kind)), '[]'::jsonb) into v_new from public.utility_bills b where b.id = any (v_ids);
  select coalesce(jsonb_agg(public.bill_json_v1(b) order by array_position(array['electric', 'water', 'internet', 'netflix'], b.kind)), '[]'::jsonb) into v_nud from public.utility_bills b where b.id = any (v_nids);
  return jsonb_build_object('new', v_new, 'nudge', v_nud);
end;
$$;

-- 7. bill_step_v1 ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Finance gate. telegram_staff_pay_step_v1 has no SQL gate: the Finance group is the gate (D-302), and staff_pay_settle_v1 only resolves a named profile with approve_payment when there is one.
-- The same rule here: no Telegram id is refused; an id that maps to a staff profile must hold approve_payment (owner, admin, finance) and not be disabled; an id with no profile is a Finance group member the
-- edge function already admitted. Refusal: {"ok":false,"reason":"not_finance"}.
create or replace function public.bill_step_v1(p_id uuid, p_step text, p_actor_tg bigint, p_actor_name text, p_proof jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_b public.utility_bills%rowtype;
  v_actor text := coalesce(nullif(btrim(p_actor_name), ''), 'Finance');
  v_role text; v_dis timestamptz;
  v_typed boolean; v_amt numeric; v_other text; v_ref text; v_label text; v_txn uuid; v_verdict text;
  v_t record; v_why text; v_con text;
begin
  if p_actor_tg is null then return jsonb_build_object('ok', false, 'reason', 'not_finance'); end if;
  select p.role, p.disabled_at into v_role, v_dis from public.staff_access_profiles p where p.telegram_user_id = p_actor_tg;
  if found and not public.staff_access_allowed(v_role, 'approve_payment', v_dis, null) then
    return jsonb_build_object('ok', false, 'reason', 'not_finance');
  end if;
  if p_step is null or p_step not in ('pay', 'cancel', 'skip', 'paid') then return jsonb_build_object('ok', false, 'reason', 'bad_step'); end if;

  select * into v_b from public.utility_bills where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_json_v1(v_b)); end if;
  -- while the bill is paying, only the person who tapped pay may settle or skip it (the Telegram lane checks the same; this closes it for any other caller)
  if v_b.status = 'paying' and p_step in ('skip', 'paid') and v_b.paying_by_tg is distinct from p_actor_tg then
    return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b));
  end if;

  case p_step
    when 'pay' then
      if v_b.status = 'due' then
        update public.utility_bills set status = 'paying', paying_by_tg = p_actor_tg, paying_by_name = v_actor, paying_at = now() where id = v_b.id returning * into v_b;
      elsif not (v_b.status = 'paying' and v_b.paying_by_tg is not distinct from p_actor_tg) then -- the same person tapping again re-opens her own question
        return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b));
      end if;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b));

    when 'cancel' then
      if v_b.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b)); end if;
      update public.utility_bills set status = 'due', paying_by_tg = null, paying_by_name = null, paying_at = null where id = v_b.id returning * into v_b;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b));

    when 'skip' then
      if v_b.status <> 'skipped' then
        update public.utility_bills set status = 'skipped' where id = v_b.id returning * into v_b;
      end if;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b));

    else -- 'paid'
      if v_b.status = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b)); end if;
      if p_proof is null or jsonb_typeof(p_proof) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b)); end if;
      v_typed := coalesce(p_proof -> 'typed' = 'true'::jsonb, false) or coalesce(p_proof ->> 'verdict' = 'typed', false);
      v_amt := case jsonb_typeof(p_proof -> 'amount')
                 when 'number' then (p_proof ->> 'amount')::numeric
                 when 'string' then case when (p_proof ->> 'amount') ~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' then (p_proof ->> 'amount')::numeric end
               end;
      v_amt := round(v_amt, 2);
      if v_amt is null or v_amt <= 0 or v_amt > 100000 then return jsonb_build_object('ok', false, 'reason', 'bad_amount'); end if;
      if not v_typed and (coalesce(p_proof ->> 'sha256', '') = '' or coalesce(p_proof ->> 'file_unique_id', '') = '') then
        return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b));
      end if;
      if not v_typed then
        select o.ref into v_other from public.utility_bills o
         where o.id <> v_b.id and (o.proof_file_unique_id = p_proof ->> 'file_unique_id' or o.proof_sha256 = p_proof ->> 'sha256') limit 1;
        if not found then -- a screenshot that settled a staff payment cannot settle a bill either
          select o.ref into v_other from public.staff_pay_requests o
           where o.proof_file_unique_id = p_proof ->> 'file_unique_id' or o.proof_sha256 = p_proof ->> 'sha256' limit 1;
        end if;
        if found then return jsonb_build_object('ok', false, 'reason', 'duplicate_proof', 'other_ref', v_other); end if;
      end if;
      -- amount band (Addendum 1): fixed bills amount .. amount + 50, meter bills half .. double the estimate; an unknown estimate has no band, so it always asks
      if coalesce(p_proof -> 'confirmed' = 'true'::jsonb, false) is false and not coalesce(
           case when v_b.kind in ('internet', 'netflix') then v_amt between v_b.estimate_php and v_b.estimate_php + 50
                else v_amt between v_b.estimate_php / 2 and v_b.estimate_php * 2 end, false) then
        return jsonb_build_object('ok', false, 'reason', 'confirm_amount', 'read', v_amt);
      end if;

      v_verdict := case when v_typed then 'typed' else 'read' end;
      v_ref := 'bill:' || v_b.kind || ':' || v_b.period;
      v_label := public.bill_schedule_cfg_v1() -> 'bills' -> v_b.kind ->> 'label';
      perform set_config('cascade.audit_reason', 'bill ' || v_b.ref || ' paid by ' || v_actor, true);
      -- found again by its ref (the unique index counts void rows too): a second pass never writes twice, and a row that is not this bill's is never linked
      select t.id, t.status, t.property_id, t.source, t.gross_amount into v_t from public.transactions t where t.external_ref = v_ref;
      if found then
        if v_t.status = 'void' then
          raise exception using errcode = '55000', message = 'The ledger already holds a voided row for ' || v_ref || ' (id ' || v_t.id || '). Delete that row or give it another reference, then log the bill again.';
        end if;
        v_why := concat_ws(', ', case when v_t.property_id is distinct from v_b.property_id then 'another property' end,
                                 case when v_t.source is distinct from 'bill' then 'source ' || coalesce(v_t.source, 'none') end,
                                 case when v_t.gross_amount is distinct from v_amt then 'amount ' || coalesce(v_t.gross_amount::text, 'none') end);
        if v_why <> '' then
          raise exception using errcode = '55000', message = 'The ledger already holds a row for ' || v_ref || ' (id ' || v_t.id || ') that does not match this bill: ' || v_why || '. Fix or delete that row, then log the bill again.';
        end if;
        v_txn := v_t.id;
      end if;
      begin
      if v_txn is null then
        insert into public.transactions(property_id, txn_type, category, status, source, gross_amount, payee_name, transaction_date, external_ref, notes, logged_by)
        values (v_b.property_id, 'expense', 'utilities', 'confirmed', 'bill', v_amt, v_label, public.manila_today(), v_ref,
                'Utility bill ' || v_b.kind || ' ' || v_b.period || ' (' || v_label || '). Bill ' || v_b.ref || '.', 'Telegram: ' || v_actor)
        returning id into v_txn;
      end if;
      update public.utility_bills set
        status = 'paid', paid_php = v_amt, paid_at = now(), paid_by_tg = p_actor_tg, paid_by_name = v_actor, txn_id = v_txn,
        paying_by_tg = coalesce(paying_by_tg, p_actor_tg), paying_by_name = coalesce(paying_by_name, v_actor), paying_at = coalesce(paying_at, now()),
        proof_file_unique_id = case when v_typed then null else p_proof ->> 'file_unique_id' end,
        proof_file_id = case when v_typed then null else nullif(p_proof ->> 'file_id', '') end,
        proof_sha256 = case when v_typed then null else p_proof ->> 'sha256' end,
        proof_amount = v_amt,
        proof_reference = case when v_typed then null else nullif(p_proof ->> 'reference', '') end,
        proof_read = jsonb_build_object('read', p_proof -> 'read', 'verdict', v_verdict),
        proof_verdict = v_verdict
       where id = v_b.id returning * into v_b;
      exception when unique_violation then -- the sub-transaction undoes the ledger insert too
        get stacked diagnostics v_con = constraint_name;
        if v_con in ('utility_bills_proof_file_uq', 'utility_bills_proof_sha_uq') then
          select o.ref into v_other from public.utility_bills o where o.id <> v_b.id and (o.proof_file_unique_id = p_proof ->> 'file_unique_id' or o.proof_sha256 = p_proof ->> 'sha256') limit 1;
          return jsonb_build_object('ok', false, 'reason', 'duplicate_proof', 'other_ref', v_other);
        end if;
        raise exception using errcode = '55000', message = 'The ledger already holds a row for ' || v_ref || ' that was written a moment ago. Check it, then log the bill again.';
      end;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b), 'paid_php', v_amt);
  end case;
end;
$$;

-- 8. today_bills_v1: the lane A body plus "due" -------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.today_bills_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if auth.uid() is null or p_property_id is null or not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'not authorized';
  end if;
  v := public.utility_bill_estimate_v1(p_property_id, public.manila_today());
  return jsonb_build_object(
    'since', (v -> 'electric' ->> 'cycle_from')::date,
    'last_reading_at', v -> 'electric' -> 'last_reading_at',
    'electric', jsonb_build_object('php', v -> 'electric' -> 'so_far_php', 'kwh', v -> 'electric' -> 'kwh'),
    'water', jsonb_build_object('php', v -> 'water' -> 'so_far_php', 'm3', v -> 'water' -> 'm3'),
    'due', coalesce((select jsonb_agg(jsonb_build_object('kind', b.kind, 'label', public.bill_schedule_cfg_v1() -> 'bills' -> b.kind ->> 'label', 'period', b.period,
                                                         'status', b.status, 'estimate_php', b.estimate_php, 'paid_php', b.paid_php)
                                      order by b.period, array_position(array['electric', 'water', 'internet', 'netflix'], b.kind))
                       from public.utility_bills b where b.property_id = p_property_id
                        and (b.status in ('due', 'paying') or b.period = to_char(public.manila_today(), 'YYYY-MM'))), '[]'::jsonb));
end;
$$;

-- 9. grants (ML-21) -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.bill_cfg_text_v1(jsonb, text) from public, anon, authenticated, service_role;
revoke all on function public.bill_schedule_cfg_v1() from public, anon, authenticated, service_role;
revoke all on function public.bill_json_v1(public.utility_bills) from public, anon, authenticated, service_role;
revoke all on function public.bill_due_open_v1(uuid, date) from public, anon, authenticated;
grant execute on function public.bill_due_open_v1(uuid, date) to service_role;
revoke all on function public.bill_step_v1(uuid, text, bigint, text, jsonb) from public, anon, authenticated;
grant execute on function public.bill_step_v1(uuid, text, bigint, text, jsonb) to service_role;
revoke all on function public.today_bills_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.today_bills_v1(uuid) to authenticated;

comment on function public.bill_due_open_v1(uuid, date) is 's127 bills: service_role. From pay_day opens the month''s missing bill rows and returns {new, nudge}; a second call the same day returns nothing new; nudge once on or after nudge_day.';
comment on function public.bill_step_v1(uuid, text, bigint, text, jsonb) is 's127 bills: service_role. pay | cancel | skip | paid. paid needs a read screenshot (sha256 + file_unique_id) or typed true, writes one transactions row bill:<kind>:<period>. Refusals: not_finance, not_found, already_paid, bad_step, duplicate_proof, bad_amount, confirm_amount.';
comment on function public.today_bills_v1(uuid) is 's127: the electricity and water bill so far for the Today tab plus this month''s bill rows and every unpaid one of an earlier month (due). Every active staff role of the property (read_operations); anyone else 42501. Money by design (Lloyd 2026-11-20); no account number.';

-- forward check: everything this release adds is present and closed to the API roles ----------------------------------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.utility_bills') is null then raise exception 'utility_bills missing'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.utility_bills'::regclass) then raise exception 'utility_bills RLS not enabled'; end if;
  if has_table_privilege('anon', 'public.utility_bills', 'select') or has_table_privilege('authenticated', 'public.utility_bills', 'select') then raise exception 'an API role can read utility_bills'; end if;
  if has_function_privilege('anon', 'public.bill_step_v1(uuid,text,bigint,text,jsonb)', 'execute') or has_function_privilege('authenticated', 'public.bill_step_v1(uuid,text,bigint,text,jsonb)', 'execute') then raise exception 'an API role can run bill_step_v1'; end if;
  if has_function_privilege('anon', 'public.bill_due_open_v1(uuid,date)', 'execute') or has_function_privilege('authenticated', 'public.bill_due_open_v1(uuid,date)', 'execute') then raise exception 'an API role can run bill_due_open_v1'; end if;
  if not exists (select 1 from public.app_settings where key = 'bill_schedule') then raise exception 'bill_schedule setting missing'; end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.transactions'::regclass and conname = 'transactions_source_check' and pg_get_constraintdef(oid) like '%''bill''%') then raise exception 'transactions_source_check lacks bill'; end if;
end $$;

commit;
