-- Session 127, release B (SQL, Staff app): release s127_bill_reminders_20261128. Contract: docs/s127/CONTRACT-B-APP.md (Roles, Lane S) over docs/s127/CONTRACT-B.md (Rules both lanes rely on, Addendum 1 and 3).
-- Four monthly bills (electric, water, internet, netflix) get a row on their reminder day, a card in the Staff app (Today, To pay) and ONE proof-backed expense row when paid. Telegram is out of this release:
-- the actor is the signed-in staff user (auth.uid()).
--
--   app_settings 'bill_schedule'                inserted only when absent: reading_day 21, pay_day 27, nudge_day 28 and the four bills. Account numbers, payee name, number and note are EMPTY here; the release block fills them
--                                                from a local file. Every function below reads it through bill_schedule_cfg_v1 and falls back key by key (a key of the wrong JSON type never raises).
--                                                A bill may carry remind_day (1..28; default pay_day): the day its row opens and the day it is due by.
--   app_settings policies                       The key holds account numbers and a payee number, but its name does not look secret, so the existing anon / staff read policies would show it to anyone with the public key.
--                                                Two RESTRICTIVE select policies hide that one key from anon and from every signed-in account except manage_staff (owner, admin). Every other key is untouched.
--   transactions_source_check                   gains 'bill'. Rebuilt only after every literal the live check holds is shown to be in the known list, else 55000. Added NOT VALID, then validated in the same guarded block.
--   utility_bills                               one row per property, kind and month. service_role only. PAID is impossible without a stored screenshot or the typed override (utility_bills_paid_needs_proof).
--                                                paying_by / paid_by are the staff user ids, paying_by_name / paid_by_name the display names, proof_path the stored screenshot (private cleaning-photos bucket), notice_id the Today notice.
--   Staff app functions (authenticated only; each checks the role in its body, else {ok:false, reason:'not_authorized'}):
--     today_bills_v1(uuid)                      read_operations. The lane A body plus "due": [bill entry]. No account, payee or note data.
--     bill_pay_open_v1 / bill_pay_settle_v1 / bill_pay_cancel_v1 / bill_pay_skip_v1 / bill_proof_v1     approve_payment (owner, admin, finance).
--     bill_schedule_get_v1 / bill_schedule_set_v1                                                          manage_staff (owner, admin).
--   internal (granted to nobody; the definer functions and the cron job run as the owner):
--     bill_step_v1 (core pay | cancel | skip | paid with the one transactions row), bill_due_open_v1, bill_daily_v1 (the 08:00 Manila job), bill_push_v1, bill_reply_v1, bill_entry_v1, bill_pay_info_v1,
--     bill_can_v1, bill_actor_name_v1, bill_json_v1, bill_schedule_cfg_v1, bill_cfg_one_v1, bill_cfg_day_v1, bill_cfg_text_v1.
--   pg_cron job 'bill-daily-0800-manila'        0 0 * * * (00:00 UTC = 08:00 Manila). Opens the bills, writes the Today notices (ops_notices type reminder, source system, no amount: notices_v1 hides amounts), keeps unpaid ones dated
--                                                today, asks notify-staff-inbox for a push (same call ops_notices_push_trg makes). The first run never opens a month before 2026-11 (October stays closed).
-- notices_v1 is NOT changed: it returns every active ops_notices row (audience staff or all, not expired, dated today to 30 days ahead) to every role with read_operations, type 'reminder' as 'note'.
-- Money rule: a read amount is accepted without a question only inside a band (fixed bills: amount .. amount + 50; meter bills: half .. double the estimate); outside it the answer is confirm_amount unless confirmed true.
-- Guard (55000, nothing changes): today_bills_v1 must be the lane A body or this release (md5 of prosrc, CR stripped).
-- Rollback: supabase/rollbacks/20261128_s127_bill_reminders.sql (refuses once a bill is paid or a bill ledger row exists; puts the lane A today_bills_v1 back, unschedules the job, drops the new objects).

begin;

-- 1. guards -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.today_bills_v1(uuid)');
  if v is distinct from 'f7cfd2f8ddd001229df63601b636c5b7' and v is distinct from '70302291441c8493c622ae66befe6b79' then
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
  paying_by uuid references public.staff_access_profiles(user_id) on delete set null, paying_by_name text, paying_at timestamptz,
  proof_file_unique_id text, proof_file_id text, proof_sha256 text,
  proof_amount numeric(12,2), proof_reference text, proof_read jsonb,
  proof_verdict text check (proof_verdict is null or proof_verdict in ('read', 'typed')),
  proof_path text check (proof_path is null or (char_length(proof_path) <= 300 and position('..' in proof_path) = 0)),
  paid_php numeric(12,2) check (paid_php is null or paid_php > 0),
  paid_at timestamptz, paid_by uuid references public.staff_access_profiles(user_id) on delete set null, paid_by_name text,
  txn_id uuid references public.transactions(id) on delete set null,
  notice_id uuid references public.ops_notices(id) on delete set null,
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
  's127 bill reminders: one row per property, bill kind and month (period YYYY-MM, the month billed). estimate_php is what the card shows before payment; paid_php is what was actually paid, read from the proof screenshot (billers add a fee). PAID is impossible without a stored screenshot or the typed override.';

-- 5. internal helpers (granted to nobody) --------------------------------------------------------------------------------------------------------------------------------------------------
-- a text setting: a non-blank JSON string, else the default
create or replace function public.bill_cfg_text_v1(p_val jsonb, p_default text)
returns jsonb language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_val) = 'string' and btrim(p_val #>> '{}') <> '' then p_val else to_jsonb(p_default) end;
$$;

-- a day setting: a JSON number cut to a whole number and held to 1..28 (every month has those days), else the default
create or replace function public.bill_cfg_day_v1(p_val jsonb, p_default integer)
returns jsonb language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_val) = 'number' then to_jsonb(least(28, greatest(1, trunc((p_val #>> '{}')::numeric)))::integer) else to_jsonb(p_default) end;
$$;

-- one bill of the setting, key by key. p_amount is null for the two meter bills. remind_day falls back to pay_day.
create or replace function public.bill_cfg_one_v1(p jsonb, p_label text, p_amount jsonb, p_pd integer)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'label', public.bill_cfg_text_v1(p -> 'label', p_label),
    'account', public.bill_cfg_text_v1(p -> 'account', ''), 'account_name', public.bill_cfg_text_v1(p -> 'account_name', ''),
    'pay_to_name', public.bill_cfg_text_v1(p -> 'pay_to_name', ''), 'pay_to_number', public.bill_cfg_text_v1(p -> 'pay_to_number', ''),
    'note', public.bill_cfg_text_v1(p -> 'note', ''), 'amount', p_amount, 'remind_day', public.bill_cfg_day_v1(p -> 'remind_day', p_pd));
$$;

-- the stored setting wins key by key; a key of the wrong JSON type (or a setting that is not an object) falls back to its default. Never raises.
create or replace function public.bill_schedule_cfg_v1()
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'reading_day', public.bill_cfg_day_v1(s.v -> 'reading_day', 21), 'pay_day', to_jsonb(s.pd), 'nudge_day', public.bill_cfg_day_v1(s.v -> 'nudge_day', 28),
    'bills', jsonb_build_object(
      'electric', public.bill_cfg_one_v1(s.v #> '{bills,electric}', 'Electricity (SOCOTECO II)', null, s.pd),
      'water',    public.bill_cfg_one_v1(s.v #> '{bills,water}', 'Water (Gensan Water District)', null, s.pd),
      'internet', public.bill_cfg_one_v1(s.v #> '{bills,internet}', 'Internet', public.utility_cfg_num_v1(s.v #> '{bills,internet,amount}', to_jsonb(1500)), s.pd),
      'netflix',  public.bill_cfg_one_v1(s.v #> '{bills,netflix}', 'Netflix', public.utility_cfg_num_v1(s.v #> '{bills,netflix,amount}', to_jsonb(449)), s.pd)))
    from (select a.v, (public.bill_cfg_day_v1(a.v -> 'pay_day', 27) #>> '{}')::integer pd
            from (select coalesce((select x.value from public.app_settings x where x.key = 'bill_schedule' and jsonb_typeof(x.value) = 'object'), '{}'::jsonb) v) a) s;
$$;

-- one bill with its settings text, for the daily job (never reaches an API role)
create or replace function public.bill_json_v1(b public.utility_bills)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', b.id, 'ref', b.ref, 'kind', b.kind, 'period', b.period, 'label', c -> 'bills' -> b.kind ->> 'label', 'status', b.status,
    'estimate_php', b.estimate_php, 'paid_php', b.paid_php, 'paid_at', b.paid_at, 'paid_by_name', b.paid_by_name, 'paying_by_name', b.paying_by_name,
    'account', c -> 'bills' -> b.kind ->> 'account', 'account_name', c -> 'bills' -> b.kind ->> 'account_name',
    'pay_to_name', c -> 'bills' -> b.kind ->> 'pay_to_name', 'pay_to_number', c -> 'bills' -> b.kind ->> 'pay_to_number', 'note', c -> 'bills' -> b.kind ->> 'note',
    'remind_day', (c -> 'bills' -> b.kind ->> 'remind_day')::integer)
    from (select public.bill_schedule_cfg_v1() c) x;
$$;

-- the display name of a staff user, as staff_pay_admin_settle_v1 builds it
create or replace function public.bill_actor_name_v1(p_uid uuid)
returns text language sql stable set search_path = '' as $$
  select left(coalesce((select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                                        initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')), 'Finance')
                          from auth.users u where u.id = p_uid), 'Finance'), 30);
$$;

-- approve_payment for the signed-in user on a property; a missing bill (null property) is judged on the user's own first property so "not found" is never shown to someone who could not pay anything
create or replace function public.bill_can_v1(p_property_id uuid)
returns boolean language sql stable set search_path = '' as $$
  select auth.uid() is not null and public.current_staff_authorized('approve_payment',
    coalesce(p_property_id, (select s.property_id from public.staff_property_access s where s.user_id = auth.uid() order by s.property_id limit 1)));
$$;

-- what the pay sheet and the edit sheet show about WHERE to pay: electric and water pay an account; internet and Netflix pay a number (a GCash number for internet). The note has the month filled in.
create or replace function public.bill_pay_info_v1(p_cfg jsonb, p_kind text, p_period text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'payee_name', case when p_kind in ('electric', 'water') then p_cfg -> 'bills' -> p_kind ->> 'account_name' else p_cfg -> 'bills' -> p_kind ->> 'pay_to_name' end,
    'number_label', case when p_kind = 'internet' then 'GCash number' else 'Account number' end,
    'number', case when p_kind in ('electric', 'water') then p_cfg -> 'bills' -> p_kind ->> 'account' else p_cfg -> 'bills' -> p_kind ->> 'pay_to_number' end,
    'note', case when btrim(p_cfg -> 'bills' -> p_kind ->> 'note') = '' then (p_cfg -> 'bills' -> p_kind ->> 'label') || ' ' || m.t
                 else replace(p_cfg -> 'bills' -> p_kind ->> 'note', '{month}', m.t) end,
    'amount_fixed', p_kind in ('internet', 'netflix'), 'remind_day', (p_cfg -> 'bills' -> p_kind ->> 'remind_day')::integer)
    from (select to_char(to_date(p_period || '-01', 'YYYY-MM-DD'), 'FMMonth YYYY') t) m;
$$;

-- one bill as the Staff app reads it. No account, payee or note data. can_pay: approve_payment and the bill is due, or it is paying by this user.
create or replace function public.bill_entry_v1(b public.utility_bills, p_cfg jsonb, p_approve boolean, p_uid uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', b.id, 'kind', b.kind, 'label', p_cfg -> 'bills' -> b.kind ->> 'label', 'period', b.period, 'status', b.status,
    'estimate_php', b.estimate_php, 'paid_php', b.paid_php, 'is_estimate', b.kind in ('electric', 'water'),
    'due_day', (p_cfg -> 'bills' -> b.kind ->> 'remind_day')::integer,
    'paying_by_name', case when b.status = 'paying' then b.paying_by_name end,
    'paid_by_name', case when b.status = 'paid' then b.paid_by_name end, 'paid_at', b.paid_at,
    'can_pay', coalesce(p_approve, false) and (b.status = 'due' or (b.status = 'paying' and b.paying_by is not distinct from p_uid)));
$$;

-- an answer of the core with the bill re-read and shaped as an entry for the signed-in caller
create or replace function public.bill_reply_v1(p_res jsonb, p_id uuid)
returns jsonb language sql stable set search_path = '' as $$
  select case when p_res ? 'bill' then coalesce((select jsonb_set(p_res, '{bill}', public.bill_entry_v1(b, public.bill_schedule_cfg_v1(), true, auth.uid())) from public.utility_bills b where b.id = p_id), p_res) else p_res end;
$$;

-- a web push for one notice: the same call ops_notices_push_trg makes. Only the Cascade property; where pg_net or the vault secret is absent (a rehearsal copy) nothing is sent; a failure never stops the caller.
create or replace function public.bill_push_v1(p_property_id uuid, p_notice_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  if p_notice_id is null or p_property_id is distinct from '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid
     or to_regnamespace('net') is null or to_regclass('vault.decrypted_secrets') is null then return; end if;
  begin
    execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret' limit 1$q$ into v_secret;
    if coalesce(v_secret, '') <> '' then
      perform net.http_post(
        url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/notify-staff-inbox',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cascade-cron-secret', v_secret),
        body := jsonb_build_object('kind', 'notice', 'notice_id', p_notice_id),
        timeout_milliseconds := 20000);
    end if;
  exception when others then
    raise warning 'bill_push_v1: could not queue the notice push (%)', sqlstate;
  end;
end $$;

-- 6. bill_due_open_v1 -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Each bill opens on its own remind_day (default pay_day): on or after it, this month's row; before it, the PREVIOUS month's missing row (catch-up for a run that missed the day; no nudge). p_min_period
-- (YYYY-MM) is a floor: no row is opened for an earlier month. The estimate of a meter bill is the forecast of the cycle that CLOSED in the month billed (that month's cycle day), not of the cycle that starts after it.
-- nudge = this month's rows still due or paying, once, on or after nudge_day and pay_day (stamps nudged_at); nothing in the Staff app uses it, the notice simply stays until the bill is paid or skipped.
create or replace function public.bill_due_open_v1(p_property_id uuid, p_on date, p_min_period text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cfg jsonb := public.bill_schedule_cfg_v1();
  v_ucfg jsonb := public.utility_billing_cfg_v1();
  v_pay integer := (v_cfg ->> 'pay_day')::integer;
  v_nudge integer := (v_cfg ->> 'nudge_day')::integer;
  v_day integer;
  v_ids uuid[]; v_nids uuid[]; v_new jsonb; v_nud jsonb;
begin
  if p_property_id is null or p_on is null then
    return jsonb_build_object('new', '[]'::jsonb, 'nudge', '[]'::jsonb);
  end if;
  v_day := extract(day from p_on)::integer;
  perform pg_advisory_xact_lock(hashtextextended('bill_due_open:' || p_property_id::text, 0));

  with k as (
    select x.kind, to_char(m.d, 'YYYY-MM') period, m.d
      from (select kk.kind, (v_cfg -> 'bills' -> kk.kind ->> 'remind_day')::integer rd from unnest(array['electric', 'water', 'internet', 'netflix']) as kk(kind)) x,
           lateral (select case when v_day >= x.rd then date_trunc('month', p_on)::date else (date_trunc('month', p_on) - interval '1 month')::date end d) m),
  ins as (
    insert into public.utility_bills(property_id, kind, period, estimate_php)
    select p_property_id, k.kind, k.period,
           case k.kind
             when 'electric' then (public.utility_bill_estimate_v1(p_property_id, public.utility_cycle_day_v1(k.d, (v_ucfg -> 'electric' ->> 'cycle_day')::integer)) -> 'electric' ->> 'forecast_php')::numeric
             when 'water'    then (public.utility_bill_estimate_v1(p_property_id, public.utility_cycle_day_v1(k.d, (v_ucfg -> 'water' ->> 'cycle_day')::integer)) -> 'water' ->> 'forecast_php')::numeric
             else (v_cfg -> 'bills' -> k.kind ->> 'amount')::numeric end
      from k
     where (p_min_period is null or k.period >= p_min_period)
       and not exists (select 1 from public.utility_bills b where b.property_id = p_property_id and b.kind = k.kind and b.period = k.period)
    on conflict (property_id, kind, period) do nothing
    returning id)
  select array_agg(i.id) into v_ids from ins i;
  v_ids := coalesce(v_ids, '{}');

  -- the one second nudge: this month's rows still unpaid that this call did not just open
  if v_day >= v_nudge and v_day >= v_pay then
    with n as (
      update public.utility_bills b set nudged_at = now()
       where b.property_id = p_property_id and b.period = to_char(p_on, 'YYYY-MM') and b.status in ('due', 'paying') and b.nudged_at is null and b.id <> all (v_ids)
      returning b.id)
    select array_agg(n.id) into v_nids from n;
  end if;
  v_nids := coalesce(v_nids, '{}');

  select coalesce(jsonb_agg(public.bill_json_v1(b) order by array_position(array['electric', 'water', 'internet', 'netflix'], b.kind)), '[]'::jsonb) into v_new from public.utility_bills b where b.id = any (v_ids);
  select coalesce(jsonb_agg(public.bill_json_v1(b) order by array_position(array['electric', 'water', 'internet', 'netflix'], b.kind)), '[]'::jsonb) into v_nud from public.utility_bills b where b.id = any (v_nids);
  return jsonb_build_object('new', v_new, 'nudge', v_nud);
end;
$$;

-- 7. bill_step_v1: the core, internal ------------------------------------------------------------------------------------------------------------------------------------------------------
-- No role gate here: the Staff app functions below check approve_payment, then call it with auth.uid(). steps pay | cancel | skip | paid. paid writes the one transactions row (external_ref bill:<kind>:<period>, found again by that ref).
-- While a bill is paying, only the person who tapped pay may settle or skip it (bad_step for anyone else). A screenshot that settled a staff payment cannot settle a bill (duplicate_proof).
-- An existing ledger row for the ref is linked only when property, source 'bill' and amount all match; otherwise (and for a VOID row) 55000 with a plain message. A paid or skipped bill closes its Today notice.
-- p_proof: {file_unique_id, file_id, sha256, amount, reference, path, read, verdict:'read', confirmed?} or {typed:true, amount, verdict:'typed'} (no caller in the app sends typed; it stays for a hand fix).
create or replace function public.bill_step_v1(p_id uuid, p_step text, p_actor_uid uuid, p_actor_name text, p_proof jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_b public.utility_bills%rowtype;
  v_actor text := coalesce(nullif(btrim(p_actor_name), ''), 'Finance');
  v_typed boolean; v_amt numeric; v_other text; v_ref text; v_label text; v_txn uuid; v_verdict text;
  v_t record; v_why text; v_con text;
begin
  if p_actor_uid is null or p_step is null or p_step not in ('pay', 'cancel', 'skip', 'paid') then return jsonb_build_object('ok', false, 'reason', 'bad_step'); end if;

  select * into v_b from public.utility_bills where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_json_v1(v_b)); end if;
  -- while the bill is paying, only the person who tapped pay may settle or skip it
  if v_b.status = 'paying' and p_step in ('skip', 'paid') and v_b.paying_by is distinct from p_actor_uid then
    return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b));
  end if;

  case p_step
    when 'pay' then
      if v_b.status = 'due' then
        update public.utility_bills set status = 'paying', paying_by = p_actor_uid, paying_by_name = v_actor, paying_at = now() where id = v_b.id returning * into v_b;
      elsif not (v_b.status = 'paying' and v_b.paying_by is not distinct from p_actor_uid) then -- the same person again re-opens her own payment
        return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b));
      end if;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b));

    when 'cancel' then
      if v_b.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'bad_step', 'bill', public.bill_json_v1(v_b)); end if;
      update public.utility_bills set status = 'due', paying_by = null, paying_by_name = null, paying_at = null where id = v_b.id returning * into v_b;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b));

    when 'skip' then
      if v_b.status <> 'skipped' then
        update public.utility_bills set status = 'skipped' where id = v_b.id returning * into v_b;
      end if;
      update public.ops_notices set is_active = false where id = v_b.notice_id and is_active;
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
                'Utility bill ' || v_b.kind || ' ' || v_b.period || ' (' || v_label || '). Bill ' || v_b.ref || '.', 'Staff app: ' || v_actor)
        returning id into v_txn;
      end if;
      update public.utility_bills set
        status = 'paid', paid_php = v_amt, paid_at = now(), paid_by = p_actor_uid, paid_by_name = v_actor, txn_id = v_txn,
        paying_by = coalesce(paying_by, p_actor_uid), paying_by_name = coalesce(paying_by_name, v_actor), paying_at = coalesce(paying_at, now()),
        proof_file_unique_id = case when v_typed then null else p_proof ->> 'file_unique_id' end,
        proof_file_id = case when v_typed then null else nullif(p_proof ->> 'file_id', '') end,
        proof_sha256 = case when v_typed then null else p_proof ->> 'sha256' end,
        proof_path = case when v_typed then null else nullif(p_proof ->> 'path', '') end,
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
      update public.ops_notices set is_active = false where id = v_b.notice_id and is_active;
      return jsonb_build_object('ok', true, 'bill', public.bill_json_v1(v_b), 'paid_php', v_amt);
  end case;
end;
$$;

-- 8. Staff app: pay (approve_payment) ----------------------------------------------------------------------------------------------------------------------------------------------------
-- Opens the pay sheet: marks the bill paying by the caller (a second call by the same person returns the same answer) and returns where to pay.
create or replace function public.bill_pay_open_v1(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_b public.utility_bills%rowtype; v_cfg jsonb; v_info jsonb;
begin
  select b.property_id into v_prop from public.utility_bills b where b.id = p_bill_id;
  if v_uid is null or not public.bill_can_v1(v_prop) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  select * into v_b from public.utility_bills where id = p_bill_id for update;
  if not found or v_b.status = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_cfg := public.bill_schedule_cfg_v1();
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_entry_v1(v_b, v_cfg, true, v_uid)); end if;
  if v_b.status = 'paying' and v_b.paying_by is distinct from v_uid then
    return jsonb_build_object('ok', false, 'reason', 'paying_by_other', 'name', v_b.paying_by_name);
  end if;
  if v_b.status = 'due' then
    perform public.bill_step_v1(v_b.id, 'pay', v_uid, public.bill_actor_name_v1(v_uid));
    select * into v_b from public.utility_bills where id = p_bill_id;
  end if;
  v_info := public.bill_pay_info_v1(v_cfg, v_b.kind, v_b.period);
  return jsonb_build_object('ok', true, 'bill', public.bill_entry_v1(v_b, v_cfg, true, v_uid),
    'pay', jsonb_build_object('payee_name', v_info -> 'payee_name', 'number_label', v_info -> 'number_label', 'number', v_info -> 'number', 'note', v_info -> 'note',
                              'amount_php', v_b.estimate_php, 'amount_editable', v_b.kind in ('electric', 'water')),
    'can_edit', public.current_staff_authorized('manage_staff', v_b.property_id));
end $$;

-- Settle from the Staff app. p_proof = {path, sha256?, amount, confirmed?}. The screenshot must already be stored by upload-photo under <property>/<this user>/..., which records its sha256 in
-- staff_upload_hashes; THAT value is used (a client value is only cross-checked and a mismatch is refused). Only the person who tapped pay may settle a bill that is paying.
create or replace function public.bill_pay_settle_v1(p_bill_id uuid, p_proof jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_b public.utility_bills%rowtype; v_cfg jsonb; v_res jsonb;
  v_path text; v_client_sha text; v_sha text; v_prefix text;
begin
  select b.property_id into v_prop from public.utility_bills b where b.id = p_bill_id;
  if v_uid is null or not public.bill_can_v1(v_prop) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  select * into v_b from public.utility_bills where id = p_bill_id for update;
  if not found or v_b.status = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_cfg := public.bill_schedule_cfg_v1();
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_entry_v1(v_b, v_cfg, true, v_uid)); end if;
  if v_b.status = 'paying' and v_b.paying_by is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_payer', 'name', v_b.paying_by_name); end if;

  if p_proof is null or jsonb_typeof(p_proof) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_proof'); end if;
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
  return public.bill_reply_v1(v_res, v_b.id);
end $$;

-- "Not now": the payer puts a paying bill back to due. Someone else's paying bill is not_payer. A bill already due is answered ok.
create or replace function public.bill_pay_cancel_v1(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_b public.utility_bills%rowtype; v_res jsonb;
begin
  select b.property_id into v_prop from public.utility_bills b where b.id = p_bill_id;
  if v_uid is null or not public.bill_can_v1(v_prop) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  select * into v_b from public.utility_bills where id = p_bill_id for update;
  if not found or v_b.status = 'skipped' then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_entry_v1(v_b, public.bill_schedule_cfg_v1(), true, v_uid)); end if;
  if v_b.status = 'paying' and v_b.paying_by is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_payer', 'name', v_b.paying_by_name); end if;
  v_res := case when v_b.status = 'paying' then public.bill_step_v1(v_b.id, 'cancel', v_uid, public.bill_actor_name_v1(v_uid)) else jsonb_build_object('ok', true, 'bill', '{}'::jsonb) end;
  return public.bill_reply_v1(v_res, v_b.id);
end $$;

-- "Not paying this month": allowed when the bill is due, or paying by the caller. Writes no ledger row. A bill already skipped is answered ok.
create or replace function public.bill_pay_skip_v1(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_b public.utility_bills%rowtype; v_res jsonb;
begin
  select b.property_id into v_prop from public.utility_bills b where b.id = p_bill_id;
  if v_uid is null or not public.bill_can_v1(v_prop) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  select * into v_b from public.utility_bills where id = p_bill_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_b.status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'already_paid', 'bill', public.bill_entry_v1(v_b, public.bill_schedule_cfg_v1(), true, v_uid)); end if;
  if v_b.status = 'paying' and v_b.paying_by is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_payer', 'name', v_b.paying_by_name); end if;
  v_res := public.bill_step_v1(v_b.id, 'skip', v_uid, public.bill_actor_name_v1(v_uid));
  return public.bill_reply_v1(v_res, v_b.id);
end $$;

-- the stored screenshot of a PAID bill, for approve_payment callers: the object path in the private cleaning-photos bucket
create or replace function public.bill_proof_v1(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_prop uuid; v_path text; v_status text;
begin
  select b.property_id into v_prop from public.utility_bills b where b.id = p_bill_id;
  if v_uid is null or not public.bill_can_v1(v_prop) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  select b.status, b.proof_path into v_status, v_path from public.utility_bills b where b.id = p_bill_id;
  if v_status is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_status <> 'paid' or v_path is null then return jsonb_build_object('ok', false, 'reason', 'no_proof'); end if;
  return jsonb_build_object('ok', true, 'path', v_path);
end $$;

-- 9. Staff app: edit details (manage_staff) ---------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.bill_schedule_get_v1(p_property_id uuid, p_kind text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_cfg jsonb; v_info jsonb;
begin
  if v_uid is null or p_property_id is null or not public.current_staff_authorized('manage_staff', p_property_id) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  if p_kind is null or p_kind not in ('electric', 'water', 'internet', 'netflix') then return jsonb_build_object('ok', false, 'reason', 'bad_kind'); end if;
  v_cfg := public.bill_schedule_cfg_v1();
  v_info := public.bill_pay_info_v1(v_cfg, p_kind, to_char(public.manila_today(), 'YYYY-MM'));
  return jsonb_build_object('ok', true, 'kind', p_kind, 'label', v_cfg -> 'bills' -> p_kind ->> 'label', 'payee_name', v_info -> 'payee_name',
    'number_label', v_info -> 'number_label', 'number', v_info -> 'number', 'note', v_cfg -> 'bills' -> p_kind ->> 'note',
    'amount_php', v_cfg -> 'bills' -> p_kind -> 'amount', 'remind_day', v_info -> 'remind_day', 'amount_fixed', v_info -> 'amount_fixed');
end $$;

-- p_patch keys: payee_name, number, note (text, trimmed, up to 80 characters; empty clears), amount_php (fixed bills only, > 0), remind_day (whole number 1..28). Anything else is refused (bad_key) and nothing is written.
-- The audit row names the keys that changed, never their values. Bills opened later read the new settings; a bill not yet paid shows the new pay details and, for a fixed bill, the new amount; a paid bill is untouched.
create or replace function public.bill_schedule_set_v1(p_property_id uuid, p_kind text, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid(); v_cur jsonb; v_bill jsonb; v_key text; v_val jsonb; v_store text; v_n numeric; v_changed text[] := '{}'; v_new jsonb; v_amt jsonb;
begin
  if v_uid is null or p_property_id is null or not public.current_staff_authorized('manage_staff', p_property_id) then return jsonb_build_object('ok', false, 'reason', 'not_authorized'); end if;
  if not exists (select 1 from public.properties p where p.id = p_property_id) then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if p_kind is null or p_kind not in ('electric', 'water', 'internet', 'netflix') then return jsonb_build_object('ok', false, 'reason', 'bad_kind'); end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_patch'); end if;

  select a.value into v_cur from public.app_settings a where a.key = 'bill_schedule' for update;
  v_cur := case when jsonb_typeof(v_cur) = 'object' then v_cur else '{}'::jsonb end;
  v_bill := case when jsonb_typeof(v_cur #> array['bills', p_kind]) = 'object' then v_cur #> array['bills', p_kind] else '{}'::jsonb end;

  for v_key, v_val in select e.key, e.value from jsonb_each(p_patch) e loop
    case v_key
      when 'payee_name', 'number', 'note' then
        if jsonb_typeof(v_val) <> 'string' or char_length(btrim(v_val #>> '{}')) > 80 then return jsonb_build_object('ok', false, 'reason', 'bad_value', 'key', v_key); end if;
        v_val := to_jsonb(btrim(v_val #>> '{}'));
        v_store := case v_key when 'note' then 'note'
                              when 'payee_name' then case when p_kind in ('electric', 'water') then 'account_name' else 'pay_to_name' end
                              else case when p_kind in ('electric', 'water') then 'account' else 'pay_to_number' end end;
      when 'amount_php' then
        if p_kind not in ('internet', 'netflix') then return jsonb_build_object('ok', false, 'reason', 'bad_key', 'key', v_key); end if;
        if jsonb_typeof(v_val) <> 'number' then return jsonb_build_object('ok', false, 'reason', 'bad_value', 'key', v_key); end if;
        v_n := round((v_val #>> '{}')::numeric, 2);
        if v_n <= 0 or v_n > 100000 then return jsonb_build_object('ok', false, 'reason', 'bad_value', 'key', v_key); end if;
        v_val := to_jsonb(v_n); v_store := 'amount';
      when 'remind_day' then
        if jsonb_typeof(v_val) <> 'number' then return jsonb_build_object('ok', false, 'reason', 'bad_value', 'key', v_key); end if;
        v_n := (v_val #>> '{}')::numeric;
        if v_n <> trunc(v_n) or v_n < 1 or v_n > 28 then return jsonb_build_object('ok', false, 'reason', 'bad_value', 'key', v_key); end if;
        v_val := to_jsonb(v_n::integer); v_store := 'remind_day';
      else
        return jsonb_build_object('ok', false, 'reason', 'bad_key', 'key', v_key);
    end case;
    if v_bill -> v_store is distinct from v_val then v_changed := v_changed || v_key; end if;
    v_bill := v_bill || jsonb_build_object(v_store, v_val);
  end loop;
  if cardinality(v_changed) = 0 then return jsonb_build_object('ok', true, 'kind', p_kind, 'changed', '[]'::jsonb); end if;

  v_new := v_cur || jsonb_build_object('bills', case when jsonb_typeof(v_cur -> 'bills') = 'object' then v_cur -> 'bills' else '{}'::jsonb end || jsonb_build_object(p_kind, v_bill));
  insert into public.app_settings(key, value, updated_at) values ('bill_schedule', v_new, now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
  -- a fixed bill that is not paid yet shows the new amount (and its amount band moves with it)
  if 'amount_php' = any (v_changed) then
    v_amt := v_bill -> 'amount';
    update public.utility_bills b set estimate_php = (v_amt #>> '{}')::numeric where b.property_id = p_property_id and b.kind = p_kind and b.status in ('due', 'paying');
  end if;
  insert into public.admin_audit_log(property_id, entity_table, entity_id, action, after_state, reason, actor_user_id)
  values (p_property_id, 'bill_schedule', p_property_id, 'update', jsonb_build_object('kind', p_kind, 'keys', to_jsonb(v_changed)),
          'bill schedule ' || p_kind || ' edited: ' || array_to_string(v_changed, ', '), v_uid);
  return jsonb_build_object('ok', true, 'kind', p_kind, 'changed', to_jsonb(v_changed));
end $$;

-- 10. today_bills_v1: the lane A body plus "due" -------------------------------------------------------------------------------------------------------------------------------------------
-- due: every unpaid bill (due or paying) of any period, oldest period first, then this month's PAID bills; skipped rows are left out. Each entry is bill_entry_v1. No account or payee data.
create or replace function public.today_bills_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; v_cfg jsonb; v_ok boolean; v_uid uuid := auth.uid();
begin
  if v_uid is null or p_property_id is null or not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception using errcode = '42501', message = 'not authorized';
  end if;
  v := public.utility_bill_estimate_v1(p_property_id, public.manila_today());
  v_cfg := public.bill_schedule_cfg_v1();
  v_ok := public.current_staff_authorized('approve_payment', p_property_id);
  return jsonb_build_object(
    'since', (v -> 'electric' ->> 'cycle_from')::date,
    'last_reading_at', v -> 'electric' -> 'last_reading_at',
    'electric', jsonb_build_object('php', v -> 'electric' -> 'so_far_php', 'kwh', v -> 'electric' -> 'kwh'),
    'water', jsonb_build_object('php', v -> 'water' -> 'so_far_php', 'm3', v -> 'water' -> 'm3'),
    'due', coalesce((select jsonb_agg(public.bill_entry_v1(b, v_cfg, v_ok, v_uid)
                                      order by (b.status = 'paid'), b.period, array_position(array['electric', 'water', 'internet', 'netflix'], b.kind))
                       from public.utility_bills b where b.property_id = p_property_id
                        and (b.status in ('due', 'paying') or (b.status = 'paid' and b.period = to_char(public.manila_today(), 'YYYY-MM')))), '[]'::jsonb));
end;
$$;

-- 11. the daily job ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Per property: on reading_day one notice "Meter reading due today (21st)"; bill_due_open_v1 opens the bills (never a month before 2026-11); each new bill gets ONE notice
-- "<Label> is due by the <day>." (no amount: notices_v1 hides amounts in notice text; the amount is on the To pay list); an unpaid bill's notice is dated today again so it stays on Today until the bill
-- is paid or skipped (bill_step_v1 closes it). A second run the same day writes nothing new. p_on and p_property_id exist for tests and hand runs; the job calls it with no arguments (today in Manila, all properties).
create or replace function public.bill_daily_v1(p_on date default null, p_property_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_floor constant text := '2026-11'; -- the release month: October 2026 and earlier stay closed
  v_today date := coalesce(p_on, public.manila_today());
  v_cfg jsonb := public.bill_schedule_cfg_v1();
  v_read integer := (v_cfg ->> 'reading_day')::integer;
  v_prop uuid; v_res jsonb; v_bill jsonb; v_nid uuid; v_title text; v_opened integer := 0; v_notices integer := 0;
begin
  for v_prop in select p.id from public.properties p where p_property_id is null or p.id = p_property_id order by p.id loop
    if extract(day from v_today)::integer = v_read then
      v_title := 'Meter reading due today (' || to_char(make_date(2001, 1, v_read), 'FMDDth') || ')';
      if not exists (select 1 from public.ops_notices n where n.property_id = v_prop and n.notice_type = 'reminder' and n.source = 'system' and n.effective_date = v_today and n.title = v_title) then
        insert into public.ops_notices(property_id, notice_type, title, description, effective_date, source, audience)
        values (v_prop, 'reminder', v_title, 'Read the electricity and water meters.', v_today, 'system', 'staff') returning id into v_nid;
        perform public.bill_push_v1(v_prop, v_nid);
        v_notices := v_notices + 1;
      end if;
    end if;

    v_res := public.bill_due_open_v1(v_prop, v_today, c_floor);
    for v_bill in select e from jsonb_array_elements(v_res -> 'new') e loop
      v_opened := v_opened + 1;
      insert into public.ops_notices(property_id, notice_type, title, description, effective_date, source, audience)
      values (v_prop, 'reminder', (v_bill ->> 'label') || ' is due by the ' || to_char(make_date(2001, 1, (v_bill ->> 'remind_day')::integer), 'FMDDth') || '.',
              'See To pay on Today.', v_today, 'system', 'staff') returning id into v_nid;
      update public.utility_bills set notice_id = v_nid where id = (v_bill ->> 'id')::uuid;
      perform public.bill_push_v1(v_prop, v_nid);
      v_notices := v_notices + 1;
    end loop;

    -- an unpaid bill stays on Today: its one notice is dated today (notices_v1 ends a notice at the end of its date)
    update public.ops_notices n set effective_date = v_today
     where n.is_active and n.effective_date < v_today
       and n.id in (select b.notice_id from public.utility_bills b where b.property_id = v_prop and b.status in ('due', 'paying') and b.notice_id is not null);
  end loop;
  return jsonb_build_object('on', v_today, 'bills_opened', v_opened, 'notices_written', v_notices);
end $$;

-- 08:00 Manila = 00:00 UTC. Where pg_cron is absent (a rehearsal copy) nothing happens.
do $cron$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - bill-daily-0800-manila not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'bill-daily-0800-manila') then
    perform cron.unschedule('bill-daily-0800-manila');
  end if;
  perform cron.schedule('bill-daily-0800-manila', '0 0 * * *', 'select public.bill_daily_v1()');
end $cron$;

-- 12. grants (ML-21) -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.bill_cfg_text_v1(jsonb, text) from public, anon, authenticated, service_role;
revoke all on function public.bill_cfg_day_v1(jsonb, integer) from public, anon, authenticated, service_role;
revoke all on function public.bill_cfg_one_v1(jsonb, text, jsonb, integer) from public, anon, authenticated, service_role;
revoke all on function public.bill_schedule_cfg_v1() from public, anon, authenticated, service_role;
revoke all on function public.bill_json_v1(public.utility_bills) from public, anon, authenticated, service_role;
revoke all on function public.bill_actor_name_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.bill_can_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.bill_pay_info_v1(jsonb, text, text) from public, anon, authenticated, service_role;
revoke all on function public.bill_entry_v1(public.utility_bills, jsonb, boolean, uuid) from public, anon, authenticated, service_role;
revoke all on function public.bill_reply_v1(jsonb, uuid) from public, anon, authenticated, service_role;
revoke all on function public.bill_push_v1(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.bill_due_open_v1(uuid, date, text) from public, anon, authenticated, service_role;
revoke all on function public.bill_step_v1(uuid, text, uuid, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.bill_daily_v1(date, uuid) from public, anon, authenticated, service_role;
revoke all on function public.bill_pay_open_v1(uuid) from public, anon, service_role;
revoke all on function public.bill_pay_settle_v1(uuid, jsonb) from public, anon, service_role;
revoke all on function public.bill_pay_cancel_v1(uuid) from public, anon, service_role;
revoke all on function public.bill_pay_skip_v1(uuid) from public, anon, service_role;
revoke all on function public.bill_proof_v1(uuid) from public, anon, service_role;
revoke all on function public.bill_schedule_get_v1(uuid, text) from public, anon, service_role;
revoke all on function public.bill_schedule_set_v1(uuid, text, jsonb) from public, anon, service_role;
revoke all on function public.today_bills_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.bill_pay_open_v1(uuid) to authenticated;
grant execute on function public.bill_pay_settle_v1(uuid, jsonb) to authenticated;
grant execute on function public.bill_pay_cancel_v1(uuid) to authenticated;
grant execute on function public.bill_pay_skip_v1(uuid) to authenticated;
grant execute on function public.bill_proof_v1(uuid) to authenticated;
grant execute on function public.bill_schedule_get_v1(uuid, text) to authenticated;
grant execute on function public.bill_schedule_set_v1(uuid, text, jsonb) to authenticated;
grant execute on function public.today_bills_v1(uuid) to authenticated;

comment on function public.bill_due_open_v1(uuid, date, text) is 's127 bills: internal. Opens each bill on its remind_day (this month; before it, last month''s missing row) and returns {new, nudge}; a second call the same day returns nothing new. p_min_period is a floor.';
comment on function public.bill_step_v1(uuid, text, uuid, text, jsonb) is 's127 bills: internal core of the Staff app pay functions. pay | cancel | skip | paid. paid needs a stored screenshot (sha256 + file_unique_id) or typed true, writes one transactions row bill:<kind>:<period>.';
comment on function public.bill_daily_v1(date, uuid) is 's127 bills: internal, run by pg_cron at 08:00 Manila. Opens the bills and writes the Today notices (one per bill per period). Never opens a month before 2026-11.';
comment on function public.bill_pay_open_v1(uuid) is 's127 bills: approve_payment. Marks the bill paying by the caller; returns {ok, bill, pay:{payee_name, number_label, number, note, amount_php, amount_editable}, can_edit}. Refusals: not_authorized, not_found, already_paid, paying_by_other.';
comment on function public.bill_pay_settle_v1(uuid, jsonb) is 's127 bills: approve_payment. p_proof {path, sha256, amount, confirmed}; one expense row. Refusals: not_authorized, not_found, already_paid, not_payer, bad_proof, no_stored_proof, sha_mismatch, duplicate_proof, bad_amount, confirm_amount.';
comment on function public.today_bills_v1(uuid) is 's127: the electricity and water bill so far for the Today tab plus the bills to pay (due): every unpaid bill and this month''s paid ones, each as {id, kind, label, period, status, estimate_php, paid_php, is_estimate, due_day, paying_by_name, paid_by_name, paid_at, can_pay}. Every active staff role of the property (read_operations); anyone else 42501. Money by design (Lloyd 2026-11-20); no account number.';

-- forward check: everything this release adds is present and closed to the API roles ----------------------------------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.utility_bills') is null then raise exception 'utility_bills missing'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.utility_bills'::regclass) then raise exception 'utility_bills RLS not enabled'; end if;
  if has_table_privilege('anon', 'public.utility_bills', 'select') or has_table_privilege('authenticated', 'public.utility_bills', 'select') then raise exception 'an API role can read utility_bills'; end if;
  if has_function_privilege('anon', 'public.bill_step_v1(uuid,text,uuid,text,jsonb)', 'execute') or has_function_privilege('authenticated', 'public.bill_step_v1(uuid,text,uuid,text,jsonb)', 'execute')
     or has_function_privilege('service_role', 'public.bill_step_v1(uuid,text,uuid,text,jsonb)', 'execute') then raise exception 'an API role can run bill_step_v1'; end if;
  if has_function_privilege('anon', 'public.bill_due_open_v1(uuid,date,text)', 'execute') or has_function_privilege('authenticated', 'public.bill_due_open_v1(uuid,date,text)', 'execute') then raise exception 'an API role can run bill_due_open_v1'; end if;
  if not exists (select 1 from public.app_settings where key = 'bill_schedule') then raise exception 'bill_schedule setting missing'; end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.transactions'::regclass and conname = 'transactions_source_check' and pg_get_constraintdef(oid) like '%''bill''%') then raise exception 'transactions_source_check lacks bill'; end if;
end $$;

commit;
