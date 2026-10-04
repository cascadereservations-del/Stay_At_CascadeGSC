-- Session 69 (D-294): release api_governor_20261004. An API governor: every model call and every OpenRouter budget snapshot is
-- recorded, and system-verifier raises findings about cap pressure (V14), provider outage (V15), cap headroom (V16),
-- credit runway (V17) and cost drift (V18). The findings are computed in TypeScript and passed to apply_verifier_run_v1
-- in p_found, like V13.
--   llm_usage              one row per model call (title, provider, model, tier, tokens, cost, ok, probe).
--   api_budget_snapshots   one row per key per snapshot: GET /api/v1/key status, limit, remaining and LIFETIME usage.
--   api_usage_daily_v1     per Manila day, provider, title, tier, model, probe: calls, fails, tokens, cost. service_role only.
--   api_budget_daily_v1    per Manila day and key: limit, lowest remaining, spent (max - min lifetime usage that day).
--   prune_api_usage_v1     deletes rows older than p_keep_days (default 120), returns the count.
--   app_settings.api_caps  the caps, credit, prices and thresholds the verifier reads (seeded once, never overwritten).
--   job_heartbeats         'api-governor' (2 days) so a governor that stops running is reported.
--   apply_verifier_run_v1  V14-V18 added to the DAILY scope array and V14-V15 (cap pressure, outage: urgent) to the HOURLY one,
--                          so a finding no longer raised resolves itself in the scope that raises it (orchestrator, Lloyd: "notify immediately").
-- The apply_verifier_run_v1 body below is the live definition (md5(prosrc) 5c02101b0c2bd109389ce659702b2270, identical to
-- 20260925010000_verifier_v7_dates_mismatch.sql, read 2026-10-04) with the two scope arrays changed. verifier_findings has no
-- CHECK on check_id, so no catalog needs widening. V14-V18 were unused in production when this was written.
-- Both tables are service_role only, like concierge_turn_stats. system-verifier calls prune_api_usage_v1 once a day.

begin;

create table if not exists public.llm_usage (
  id       bigint generated always as identity primary key,
  at       timestamptz not null default now(),
  title    text not null,
  provider text not null check (provider in ('openrouter', 'gemini', 'omniroute')),
  model    text,
  tier     text,
  input    integer,
  output   integer,
  cost_usd numeric(12,6),
  ok       boolean not null default true,
  error    text check (error is null or char_length(error) <= 200),
  probe    boolean not null default false
);
create index if not exists llm_usage_at_idx on public.llm_usage (at);

create table if not exists public.api_budget_snapshots (
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  key_name      text not null check (key_name in ('primary', 'backup')),
  status        integer,
  limit_usd     numeric(12,6),
  remaining_usd numeric(12,6),
  usage_usd     numeric(12,6)
);
create index if not exists api_budget_snapshots_key_at_idx on public.api_budget_snapshots (key_name, at);

alter table public.llm_usage enable row level security;
alter table public.api_budget_snapshots enable row level security;
-- No policy for anon or authenticated: Edge Functions (service role) only.
revoke all on table public.llm_usage from public, anon, authenticated;
revoke all on table public.api_budget_snapshots from public, anon, authenticated;
grant select, insert on table public.llm_usage to service_role;
grant select, insert on table public.api_budget_snapshots to service_role;
revoke all on sequence public.llm_usage_id_seq, public.api_budget_snapshots_id_seq from public, anon, authenticated; -- Supabase default grants

create or replace function public.api_usage_daily_v1(p_days integer default 35)
returns table(day date, provider text, title text, tier text, model text, probe boolean,
              calls integer, fails integer, input bigint, output bigint, cost_usd numeric)
language sql stable security definer set search_path to '' as $$
  select (u.at at time zone 'Asia/Manila')::date,
         u.provider, u.title, u.tier, u.model, u.probe,
         count(*)::integer,
         (count(*) filter (where not u.ok))::integer,
         coalesce(sum(u.input), 0)::bigint,
         coalesce(sum(u.output), 0)::bigint,
         coalesce(sum(u.cost_usd), 0)::numeric
    from public.llm_usage u
   where u.at >= (((now() at time zone 'Asia/Manila')::date - p_days)::timestamp at time zone 'Asia/Manila')
   group by 1, 2, 3, 4, 5, 6
   order by 1, 2, 3, 4, 5, 6;
$$;

create or replace function public.api_budget_daily_v1(p_days integer default 35)
returns table(day date, key_name text, limit_usd numeric, min_remaining_usd numeric,
              spent_usd numeric, snapshots integer)
language sql stable security definer set search_path to '' as $$
  select (s.at at time zone 'Asia/Manila')::date,
         s.key_name,
         (array_agg(s.limit_usd order by s.at desc) filter (where s.limit_usd is not null))[1],
         min(s.remaining_usd),
         case when count(s.usage_usd) >= 2 then max(s.usage_usd) - min(s.usage_usd) end,
         count(*)::integer
    from public.api_budget_snapshots s
   where s.at >= (((now() at time zone 'Asia/Manila')::date - p_days)::timestamp at time zone 'Asia/Manila')
   group by 1, 2
   order by 1, 2;
$$;

create or replace function public.prune_api_usage_v1(p_keep_days integer default 120)
returns integer
language plpgsql security definer set search_path to '' as $$
declare
  v_cut timestamptz;
  v_a integer;
  v_b integer;
begin
  if p_keep_days is null or p_keep_days < 1 then
    raise exception 'p_keep_days must be at least 1' using errcode = '22023';
  end if;
  v_cut := now() - make_interval(days => p_keep_days);
  delete from public.llm_usage where at < v_cut;
  get diagnostics v_a = row_count;
  delete from public.api_budget_snapshots where at < v_cut;
  get diagnostics v_b = row_count;
  return v_a + v_b;
end;
$$;

revoke all on function public.api_usage_daily_v1(integer) from public, anon, authenticated;
revoke all on function public.api_budget_daily_v1(integer) from public, anon, authenticated;
revoke all on function public.prune_api_usage_v1(integer) from public, anon, authenticated;
grant execute on function public.api_usage_daily_v1(integer) to service_role;
grant execute on function public.api_budget_daily_v1(integer) to service_role;
grant execute on function public.prune_api_usage_v1(integer) to service_role;

comment on function public.api_usage_daily_v1(integer) is
  'Session 69 (D-294): model calls per Manila day, provider, title, tier, model and probe flag (calls, fails, tokens, cost). service_role only.';
comment on function public.api_budget_daily_v1(integer) is
  'Session 69 (D-294): OpenRouter key snapshots per Manila day and key: latest limit, lowest remaining, spent = max - min lifetime usage that day (null under 2 snapshots). service_role only.';
comment on function public.prune_api_usage_v1(integer) is
  'Session 69 (D-294): deletes llm_usage and api_budget_snapshots rows older than p_keep_days (default 120); returns the rows deleted. service_role only.';

-- app_settings is anon-readable except keys matching its policy (token, secret, ical, chat_id ...); api_caps holds no secret.
insert into public.app_settings (key, value) values ('api_caps', $json$
{"caps":[{"id":"openrouter-primary","label":"OpenRouter key cascade-production","kind":"usd_day","cap":1,"floor":0.5,"key_name":"primary","where":"openrouter.ai > Settings > Keys > cascade-production > Credit limit"},{"id":"openrouter-backup","label":"OpenRouter backup key","kind":"usd_day","cap":3,"floor":0.5,"key_name":"backup","where":"openrouter.ai > Settings > Keys > backup key > Credit limit"},{"id":"omniroute-key","label":"OmniRoute key 'cascade omniroute'","kind":"usd_day_notional","cap":0.5,"floor":0.1,"provider":"omniroute","where":"OmniRoute dashboard > API Manager > cascade omniroute > Daily limit"},{"id":"cloudflare-free","label":"Cloudflare Workers AI free allowance","kind":"neurons_day","cap":10000,"fixed":true,"provider":"omniroute","where":"fixed by Cloudflare's free plan"}],"credit":{"openrouter_usd":10,"note":"Cascade OpenRouter account credit; update after a top-up"},"prices_usd_per_m":{"@cf/meta/llama-4-scout-17b-16e-instruct":[0.27,0.85],"@cf/mistralai/mistral-small-3.1-24b-instruct":[0.351,0.555],"@cf/meta/llama-3.3-70b-instruct-fp8-fast":[0.293,2.253],"@cf/aisingapore/gemma-sea-lion-v4-27b-it":[0.351,0.555],"openai/gpt-oss-120b":[0,0],"openai/gpt-oss-20b":[0,0]},"neuron_usd":0.000011,"rules":{"pressure_pct":70,"headroom_x":20,"target_x":5,"runway_days":30,"drift_x":2,"outage_fail_pct":50,"outage_min_calls":5}}
$json$::jsonb)
on conflict (key) do nothing;

-- The governor's own heartbeat: system-verifier records 'api-governor' after a daily evaluation that had all its inputs, so
-- job-heartbeat-monitor sends one Finance alert when the governor has not run for 1.5 x 2 days (it would otherwise go quiet).
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('api-governor', 172800, false, now())
on conflict (job_name) do nothing;

-- apply_verifier_run_v1: the live body, with V14-V18 added to the daily scope array and V14-V15 to the hourly one.
create or replace function public.apply_verifier_run_v1(
  p_scope text,
  p_found jsonb,
  p_now   timestamptz default now()
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_checks text[];
  v_new      jsonb := '[]'::jsonb;
  v_remind   jsonb := '[]'::jsonb;
  v_resolved jsonb := '[]'::jsonb;
  r record;
begin
  if p_scope not in ('hourly', 'daily') then
    raise exception 'scope must be hourly or daily' using errcode = '22023';
  end if;
  if p_found is null or jsonb_typeof(p_found) <> 'array' then
    raise exception 'p_found must be a json array' using errcode = '22023';
  end if;

  v_checks := case p_scope
    -- V13 (model budget) is raised by the system-verifier Edge Function in both scopes (D-227).
    -- V14-V18 (API governor, D-294) are raised by the Edge Function in the daily scope; V14-V15 hourly too (urgent).
    when 'hourly' then array['V1','V2','V3','V4','V5','V7','V7b','V11','V12','V13','V14','V15']
    else                array['V1','V2','V3','V4','V5','V6','V7','V7b','V10','V11','V12','V13','V14','V15','V16','V17','V18']
  end;

  -- Everything seen in this run: insert it, or mark it seen again. A finding
  -- that has been acknowledged stays acknowledged unless its shape changed,
  -- which is what the design's detail->>'n' comparison is for; here the whole
  -- detail is compared, because these checks carry ids rather than a count.
  for r in select value as v from jsonb_array_elements(p_found) loop
    -- An ALREADY-ACCEPTED finding is born acknowledged and never alerts. Only
    -- V10 sets detail.accepted, and only for K16's ledger_duplicates n=2. The
    -- on-conflict branch below still flips it back to open the moment the
    -- detail changes, which is what makes this safe: accepting a shape is not
    -- accepting the check forever.
    insert into public.verifier_findings as f
      (key, check_id, severity, title, detail, status, first_seen, last_seen)
    values (r.v->>'key', r.v->>'check_id', r.v->>'severity', r.v->>'title',
            coalesce(r.v->'detail', '{}'::jsonb),
            case when coalesce(r.v->'detail'->>'accepted', '') = 'true'
                 then 'acknowledged' else 'open' end,
            p_now, p_now)
    on conflict (key) do update
      set last_seen = p_now,
          severity  = excluded.severity,
          title     = excluded.title,
          detail    = excluded.detail,
          status    = case
                        when f.status = 'resolved' then 'open'
                        when f.status = 'acknowledged' and f.detail <> excluded.detail then 'open'
                        else f.status
                      end,
          resolved_at = null,
          resolved_by = null;
  end loop;

  -- Auto-resolution 1: a ghost hold whose inquiry is already expired or
  -- cancelled. This writes exactly what expire_booking_holds_v1 writes, on
  -- exactly the rows it would have written to, and nothing else.
  for r in
    select f.key, (f.detail->>'event')::uuid as event_id
      from public.verifier_findings f
     where f.check_id = 'V3' and f.status = 'open'
       and f.last_seen = p_now
       and (f.detail->>'auto_safe')::boolean is true
  loop
    update public.calendar_events set status = 'cancelled'
     where id = r.event_id and status = 'blocked';
    if found then
      update public.verifier_findings
         set status = 'resolved', resolved_at = p_now, resolved_by = 'auto',
             detail = detail || jsonb_build_object('auto', 'The booking behind this hold had already expired, so the hold was cancelled the same way the hold releaser would have.')
       where key = r.key;
      v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', 'Calendar hold with no live booking behind it', 'auto', true));
    end if;
  end loop;

  -- Auto-resolution 2: a stuck Messenger flow whose booking is already dead.
  -- The thread carries no booking id, so the match is the guest's e-mail AND
  -- both dates, and all three must be present. No match means no change: the
  -- safe direction is always to leave the flow alone and tell a person.
  for r in
    select f.key, f.detail->>'psid' as psid
      from public.verifier_findings f
     where f.check_id = 'V4' and f.status = 'open'
       and f.last_seen = p_now
       and coalesce(f.detail->>'email', '') <> ''
       and coalesce(f.detail->>'from', '')  <> ''
       and coalesce(f.detail->>'to', '')    <> ''
       and exists (
         select 1 from public.booking_inquiries b
          where lower(b.guest_email) = lower(f.detail->>'email')
            and b.checkin_date  = (f.detail->>'from')::date
            and b.checkout_date = (f.detail->>'to')::date
            and b.status in ('expired', 'cancelled'))
  loop
    update public.concierge_threads
       set booking_flow = booking_flow || jsonb_build_object('step', 'cancelled', 'updated_at', p_now)
     where psid = r.psid;
    if found then
      update public.verifier_findings
         set status = 'resolved', resolved_at = p_now, resolved_by = 'auto',
             detail = detail || jsonb_build_object('auto', 'The booking this conversation was waiting on had already expired, so the flow was closed and the guest can start again.')
       where key = r.key;
      v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', 'Messenger booking stuck at the payment step', 'auto', true));
    end if;
  end loop;

  -- Auto-resolution 3 (D-235): the Airbnb calendar is the primary record. A confirmed reservation
  -- whose dates disagree with its confirmed calendar row takes the calendar's dates (nights is generated
  -- from them). Money is never touched: the payout e-mail reconciles it, and payout_totals_agree judges it.
  for r in
    select f.key, (f.detail->>'reservation')::uuid as res_id,
           (f.detail->>'calendar_from')::date as cal_from, (f.detail->>'calendar_to')::date as cal_to,
           (f.detail->>'email_from')::date as em_from, (f.detail->>'email_to')::date as em_to
      from public.verifier_findings f
     where f.check_id = 'V7' and f.status = 'open'
       and f.last_seen = p_now
       and (f.detail->>'auto_safe')::boolean is true
  loop
    update public.airbnb_reservations
       set checkin_date = r.cal_from, checkout_date = r.cal_to
     where id = r.res_id and status = 'confirmed';
    if found then
      update public.verifier_findings
         set status = 'resolved', resolved_at = p_now, resolved_by = 'auto',
             detail = detail || jsonb_build_object('auto', format(
               'The Airbnb calendar is the primary record, so the reservation dates were corrected from it: %s to %s became %s to %s.',
               coalesce(to_char(r.em_from, 'Mon FMDD'), 'no date'), coalesce(to_char(r.em_to, 'Mon FMDD'), 'no date'),
               to_char(r.cal_from, 'Mon FMDD'), to_char(r.cal_to, 'Mon FMDD')))
       where key = r.key;
      v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', 'Reservation dates corrected from the Airbnb calendar', 'auto', true));
    end if;
  end loop;

  -- V7b is a weekly line plus ONE Follow-ups task per stay (D-218); the task closes itself below.
  for r in
    select f.detail->>'uid' as uid, f.detail->>'code' as code, f.detail->>'from' as d_from, f.detail->>'to' as d_to
      from public.verifier_findings f
     where f.check_id = 'V7b' and f.status = 'open' and f.last_seen = p_now
  loop
    perform public.system_task_open_v1(
      (select ce.property_id from public.calendar_events ce where ce.uid = r.uid limit 1),
      'airbnb_unmatched', r.uid,
      'Find the booking e-mail for Airbnb ' || coalesce(r.code, 'stay') || ' (' || r.d_from || ' to ' || r.d_to || ')',
      'The Airbnb calendar shows this stay but no booking e-mail matched it in 24 hours. Check the cascadereservations inbox, or the reservation on Airbnb.',
      'normal');
  end loop;

  -- Gone: open findings of a check this scope ran, that this run did not see.
  for r in
    update public.verifier_findings f
       set status = 'resolved', resolved_at = p_now, resolved_by = 'auto'
     where f.status in ('open', 'acknowledged')
       and f.check_id = any (v_checks)
       and f.last_seen < p_now
    returning f.key, f.title, f.severity
  loop
    v_resolved := v_resolved || jsonb_build_array(jsonb_build_object('key', r.key, 'title', r.title, 'auto', false));
  end loop;

  perform public.system_task_close_missing_v1('airbnb_unmatched',
    array(select f.detail->>'uid' from public.verifier_findings f where f.check_id = 'V7b' and f.status in ('open', 'acknowledged')),
    null, 'Closed automatically: the booking e-mail arrived and the stay is linked.');

  -- Worth saying out loud: never alerted, or alerted long enough ago to be
  -- worth repeating. Acknowledged findings are never reminded about; that is
  -- the whole point of the button.
  for r in
    update public.verifier_findings f
       set last_alerted_at = p_now
     where f.status = 'open'
       and f.last_seen = p_now
       and (f.last_alerted_at is null
            or f.last_alerted_at < p_now - (case when f.severity = 'red' then interval '24 hours' else interval '7 days' end))
    returning f.key, f.check_id, f.severity, f.title, f.detail, f.first_seen
  loop
    if r.first_seen = p_now then
      v_new := v_new || jsonb_build_array(jsonb_build_object('key', r.key, 'check_id', r.check_id, 'severity', r.severity, 'title', r.title, 'detail', r.detail));
    else
      v_remind := v_remind || jsonb_build_array(jsonb_build_object('key', r.key, 'check_id', r.check_id, 'severity', r.severity, 'title', r.title, 'detail', r.detail));
    end if;
  end loop;

  return jsonb_build_object('new', v_new, 'remind', v_remind, 'resolved', v_resolved);
end;
$function$;

revoke all on function public.apply_verifier_run_v1(text, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_verifier_run_v1(text, jsonb, timestamptz) to service_role;

comment on function public.apply_verifier_run_v1(text, jsonb, timestamptz) is
  'Records a verifier run: what is new, what is due a reminder, what has gone. Performs the three safe auto-resolutions (V3 ghost hold, V4 dead flow, V7 reservation dates from the Airbnb calendar) and keeps one task per V7b. Resolves only checks the given scope ran (V14-V18, the API governor checks, run in the daily scope). An accepted finding (K16) is born acknowledged. service_role only.';

commit;
