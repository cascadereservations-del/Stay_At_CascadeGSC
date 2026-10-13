-- 20261015000000_s82_staff_31.sql
-- Session 82, lane S (server): release s82_staff_31_20261015. Cascade Staff 3.1 server side. Five parts, all additive; the four redefined functions are cut
-- from their reviewed s81 / s79 / session-70 bodies by script, each behind an md5 guard that stops the release if the live body is not the one cut from.
--   1. Notices      ops_notices.source_url (nullable http/https text, no whitespace or '@', 8 to 500 characters). notices_v1 returns it as `url` on every
--                   notice (null when none). Written by power-watch (the SOCOTECO post link) and by Cassy's notice card (the Facebook link a person sent).
--   2. Staff home   staff_home_v1 gains `arrival_ready {id, paid, door_code}` for OWNER and ADMIN sessions only, on every confirmed stay that is upcoming or
--                   in the house (calendar[], current_guest, next_guest). Absent, not null, for every other role: the cleaner and finance payloads are
--                   byte-identical to before. Sources (read 2026-10-15):
--                     id         guest_profile_details.id_on_file, or any guest_companions row with a photo (what V6 and the Stays card use).
--                     paid       true for an Airbnb stay (Airbnb collects it). null for a direct stay: the database holds the reservation fee only
--                                (the ledger row is the whole total, confirmed at the deposit) and no column says the balance arrived. Not invented.
--                     door_code  null for every stay: the PIN is set by hand in the lock app and sent by the host; only a "card offered" log row exists.
--   3. Cleaning progress   cleaning_progress (RLS on, no grants), cleaning_progress_set_v1 (a cleaner writes her own row for today),
--                   cleaning_progress_v1 (owner/admin read the latest row touched today).
--   4. Staff pay, admin side (MONEY)   staff_pay_admin_list_v1 gains `unrequested` (unpaid work that is in no request, per staff member, same rate rule as
--                   staff_pay_candidates_v1). staff_pay_admin_create_v1 makes a normal `requested` row on a staff member's behalf with the same guards,
--                   locks and line shapes as staff_pay_request_create_v1, marked staff_pay_requests.created_by_user_id. staff_pay_candidates_v1 and
--                   staff_pay_request_create_v1 are NOT touched (their live bodies were patched in place by 20261007110000); the shared rate rule is
--                   staff_pay_rate_v1 plus the two new helpers s_pay_day_v1 and s_pay_price_v1.
--   5. Follow-ups   staff_pay_settle_v1: a settle made in the Staff app is logged as "<name> via Staff app", not "Telegram: <name>" (Telegram settles
--                   unchanged). s_weekly_sweep_v1 + pg_cron job s82-pay-weekly-sweep (Sunday 22:30 UTC = Monday 06:30 Manila): asks notify-cleaner-payment
--                   once more for any request paid in the last 7 days whose notice was never claimed, deletes staff_upload_hashes older than 90 days and
--                   cleaning_progress rows older than 14 days. Secret: the existing Vault cascade_cron_shared_secret.
--   6. Inventory (owner decision 2026-10-15, "inventory: move to app counts")
--                   apply_inventory_purchase (the Telegram receipt restock): on a movement-controlled item it now writes the matching 'receipt' movement
--                   through s_inventory_purchase_movement_v1 (idempotent on p_txn_id there); uncontrolled items behave exactly as before.
--                   inventory_shopping_list: authenticated loses the cost columns (estimated_cost, unit_cost, supplier); get_shopping_list_v1 returns them
--                   only to finance_human_authorized sessions (the get_inventory_catalogue_v1 pattern). save_shopping_item_v1: without manage_inventory a
--                   person may only create rows and edit or cancel proposed rows she proposed herself.
-- SINGLE SHOT: the guards below compare the live bodies with the bodies this release was cut from, so a second run stops on its own md5 guard by design.
-- Needs the s81 releases applied first (s81_notices_20261014 and s81_staff_pay_push_20261014): the guards below stop the release otherwise.
-- Rollback: supabase/rollbacks/20261015_s82_staff_31.sql

begin;

-- 0. guards: each redefined function must still be the body this release was cut from (md5 of prosrc, carriage returns stripped) --------------
do $$
declare
  v_fn text; v_want text; v_got text;
begin
  for v_fn, v_want in select * from (values
    ('public.staff_home_v1(uuid)',          'd04e3c492bbeba8722554ac5c951c928'),
    ('public.notices_v1(uuid)',             'f3f0653167ffaa39fa155287a13b913a'),
    ('public.staff_pay_admin_list_v1()',    '067d97c248b17221574c7d4b8b57a3f9'),
    ('public.staff_pay_settle_v1(uuid,bigint,text,text,jsonb)', 'dda64b4a8f57fdf1b3d036ca458482d7'),
    ('public.apply_inventory_purchase(uuid,numeric,numeric,text,date,uuid)', 'e71d6a691a9af5e8fd5677a2857d9cd2'),
    ('public.save_shopping_item_v1(uuid,jsonb,text)', '4429199a1b728c79cf82d86c01b17903')) v(a, b) loop
    select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure(v_fn);
    if v_got is null then raise exception 's82 staff 3.1: % does not exist (apply the s81 releases first)', v_fn using errcode = '55000'; end if;
    if v_got <> v_want then
      raise exception 's82 staff 3.1: % is not the body this release was cut from (md5 %): re-cut it from the live body', v_fn, v_got using errcode = '55000';
    end if;
  end loop;
end $$;

-- 1. schema --------------------------------------------------------------------------------------------------------------------------------
alter table public.ops_notices add column if not exists source_url text
  check (source_url is null or (char_length(source_url) between 8 and 500 and source_url ~* '^https?://[^[:space:]@]+$'));
comment on column public.ops_notices.source_url is 'S82: the original post or advisory this notice came from (http/https, no whitespace, no credentials). Null for a notice typed by hand. Returned by notices_v1 as `url`.';

alter table public.staff_pay_requests add column if not exists created_by_user_id uuid references public.staff_access_profiles(user_id);
comment on column public.staff_pay_requests.created_by_user_id is 'S82: the owner/admin/finance user who made this request on the staff member''s behalf (staff_pay_admin_create_v1). Null when the staff member made it herself.';

create table if not exists public.cleaning_progress (
  property_id  uuid not null references public.properties(id),
  user_id      uuid not null references public.staff_access_profiles(user_id) on delete cascade,
  day          date not null,
  step         integer not null check (step between 0 and 200),
  of_steps     integer not null check (of_steps between 1 and 200),
  label        text check (label is null or char_length(label) <= 80),
  cleaner_name text not null default 'Cleaner' check (char_length(cleaner_name) <= 40),
  started_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (property_id, user_id, day),
  check (step <= of_steps)
);
alter table public.cleaning_progress enable row level security;
revoke all on public.cleaning_progress from public, anon, authenticated, service_role;
comment on table public.cleaning_progress is 'S82: where a cleaner is in the checklist today, one row per (property, cleaner, Manila day). Written only by cleaning_progress_set_v1, read only by cleaning_progress_v1 (owner/admin). No grants: the RPCs are the only door.';

-- 2. internal helpers (no API role can call them) -------------------------------------------------------------------------------------------
-- The pay day of a clean: the checkout date, else the check-in date, else the Manila date it was logged (the expression staff_pay_candidates_v1 uses).
create or replace function public.s_pay_day_v1(p_checkout date, p_checkin date, p_cleaned_at timestamptz)
returns date language sql immutable set search_path to '' as $$
  select coalesce(p_checkout, p_checkin, (p_cleaned_at at time zone 'Asia/Manila')::date);
$$;
revoke all on function public.s_pay_day_v1(date, date, timestamptz) from public, anon, authenticated, service_role;

-- The base fee and the optional transport rate in force on a day: a deep clean takes the general rate, anything else the regular one.
-- Zero rows when no rate row covers the day (staff_pay_candidates_v1 drops such a clean; staff_pay_request_create_v1 answers no_rate).
create or replace function public.s_pay_price_v1(p_type text, p_date date)
returns table(base numeric, transport numeric) language sql stable security definer set search_path to '' as $$
  select case when p_type = 'deep_clean' then x.general else x.regular end, x.transport from public.staff_pay_rate_v1(p_date) x;
$$;
revoke all on function public.s_pay_price_v1(text, date) from public, anon, authenticated, service_role;

-- Arrival readiness for one stay. The caller (staff_home_v1) has already checked the session is owner or admin.
create or replace function public.s_arrival_ready_v1(p_guest_id uuid, p_source text)
returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object(
    'id', p_guest_id is not null and (
            exists (select 1 from public.guest_profile_details d where d.guest_id = p_guest_id and d.id_on_file is true)
            or exists (select 1 from public.guest_companions c where c.guest_id = p_guest_id and c.id_photo_path is not null)),
    'paid', case when p_source = 'airbnb' then true end,
    'door_code', null::boolean);
$$;
revoke all on function public.s_arrival_ready_v1(uuid, text) from public, anon, authenticated, service_role;

-- 3. notices_v1 gains url (cut from the s81 body) ----------------------------------------------------------------------------------------------------------
create or replace function public.notices_v1(p_property_id uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to ''
as $$
declare
  v_pid   uuid := coalesce(p_property_id,
                           (select s.property_id from public.staff_property_access s where s.user_id = auth.uid() order by s.property_id limit 1),
                           '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_role  text;
  v_priv  boolean;
  v_now_local timestamp := now() at time zone 'Asia/Manila';
  v_times jsonb; v_sources jsonb; v_wx jsonb; v_notices jsonb; v_house jsonb; v_inbox integer;
  c       jsonb; c_at timestamptz;
begin
  if not public.current_staff_authorized('read_operations', v_pid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select p.role into v_role from public.staff_access_profiles p where p.user_id = auth.uid();
  v_priv := public.current_staff_authorized('manage_operations', v_pid);   -- owner and admin only

  -- house times: the shared setting, the contract fallback when it is missing or malformed.
  select jsonb_build_object('check_out', coalesce(s.value->>'check_out', '12:00'), 'check_in', coalesce(s.value->>'check_in', '14:00'))
    into v_times from public.app_settings s where s.key = 'house_times';
  v_times := coalesce(v_times, '{"check_out":"12:00","check_in":"14:00"}'::jsonb);

  -- each link is used only if it is a plain Facebook page URL; a missing, malformed or non-Facebook value falls back to the built-in page for that key.
  select jsonb_build_object(
           'water_page', case when s.value->>'water_page' ~ '^https://(www\.)?facebook\.com/[A-Za-z0-9.]+/?$' then s.value->>'water_page' else 'https://www.facebook.com/gscwaterdistrict/' end,
           'power_page', case when s.value->>'power_page' ~ '^https://(www\.)?facebook\.com/[A-Za-z0-9.]+/?$' then s.value->>'power_page' else 'https://www.facebook.com/socoteco2.EC/' end)
    into v_sources from (select 1) o left join public.app_settings s on s.key = 'notice_sources';

  -- weather: the weather-proxy cache, only while it is under 60 minutes old; an allow-list of display fields.
  select s.value, s.updated_at into c, c_at from public.app_settings s where s.key = 'weather_proxy_cache';
  if c is not null and c_at > now() - interval '60 minutes' then
    v_wx := jsonb_build_object(
      'source', case c->>'source' when 'pirate_weather' then 'pirate' when 'google_weather' then 'google' when 'open_meteo' then 'open-meteo' else null end,
      'fetched_at', to_char(c_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'temp_c', c#>'{current,temp}',
      'condition', c#>'{current,description}',
      'code', c->'code',
      'rain_chance_pct', c#>'{current,rain_prob}',
      'aqi', c->'aqi',
      'hourly', coalesce((
        select jsonb_agg(jsonb_build_object('time', h.e->'time', 'rain_chance_pct', h.e->'rain_chance_pct', 'mm', h.e->'mm', 'code', h.e->'code') order by h.n)
          from (select e, n from jsonb_array_elements(case when jsonb_typeof(c->'hourly') = 'array' then c->'hourly' else '[]'::jsonb end) with ordinality as t(e, n)
                 order by n limit 12) h), '[]'::jsonb),
      'rain_watch', case when jsonb_typeof(c->'rain_watch') = 'object'
                         then jsonb_build_object('from', c#>'{rain_watch,from}', 'to', c#>'{rain_watch,to}', 'peak_pct', c#>'{rain_watch,peak_pct}') end);
  end if;

  -- notices: active and upcoming, brownout is shown as power. Title and detail are redacted free text.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', n.id,
           'type', case n.notice_type when 'brownout' then 'power' when 'water' then 'water' when 'deep_clean' then 'deep_clean' else 'note' end,
           'title', public.staff_redact_v1(n.title),
           'date', n.effective_date,
           'start_time', to_char(n.effective_time, 'HH24:MI'),
           'end_time', case when n.effective_time is not null and n.duration_hours is not null
                            then to_char(n.effective_time + n.duration_hours * interval '1 hour', 'HH24:MI') end,
           'duration_hours', n.duration_hours,
           'source', case when n.source = 'socoteco' then 'socoteco' when n.source = 'gscwd' then 'gscwd' when n.source = 'system' then 'system'
                          when n.source = 'ngcp' then 'system' when n.source in ('staff', 'manual') then 'manual'
                          when n.notice_type = 'brownout' then 'socoteco' else 'manual' end,
           'detail', public.staff_redact_v1(nullif(btrim(regexp_replace(n.description, '(^|\s*\|\s*)poster\s+\S+\s*$', '')), '')),
           'url', case when char_length(n.source_url) between 8 and 500 and n.source_url ~* '^https?://[^[:space:]@]+$' then n.source_url end
         ) order by n.effective_date, n.effective_time nulls first, n.created_at), '[]'::jsonb)
    into v_notices
    from public.ops_notices n
   where n.property_id = v_pid and n.is_active
     and coalesce(n.audience, 'staff') in ('staff', 'all')
     and (n.expires_at is null or n.expires_at > now())
     -- not ended yet: a timed notice ends at start + duration (Manila clock), any other at the end of its date. `date` stays the start date.
     and case when n.effective_time is not null and n.duration_hours is not null
              then n.effective_date::timestamp + n.effective_time + n.duration_hours * interval '1 hour'
              else n.effective_date::timestamp + interval '1 day' end >= v_now_local
     and n.effective_date <= v_today + 30;

  -- house items and the inbox count: owner and admin only. A cleaner gets [] and null.
  if v_priv then
    -- verifier_findings.detail is free-form jsonb (it can name guests or amounts), so a finding shows its redacted title only.
    select coalesce(jsonb_agg(u.item order by u.rank, u.sort_title), '[]'::jsonb) into v_house from (
      select x.* from (
        select 0 rank, f.title sort_title, jsonb_build_object('kind', 'finding', 'id', f.key,
                 'title', public.staff_redact_v1(f.title), 'detail', null) item
          from public.verifier_findings f where f.status in ('open', 'acknowledged')
        union all
        select 1, i.name, jsonb_build_object('kind', 'low_stock', 'id', i.id::text,
                 'title', public.staff_redact_v1('Low stock: ' || i.name),
                 'detail', 'Down to ' || trim(trailing '.' from trim(trailing '0' from i.qty_on_hand::numeric(12,2)::text))
                           || ', reorder below ' || trim(trailing '.' from trim(trailing '0' from i.reorder_below::numeric(12,2)::text)))
          from public.inventory_items i
         where i.property_id = v_pid and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below) x
      order by x.rank, x.sort_title limit 20) u;
    select count(*)::int into v_inbox from public.concierge_handoffs h where h.status = 'open';
  else
    v_house := '[]'::jsonb;
    v_inbox := null;
  end if;

  return jsonb_build_object(
    'generated_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'role', v_role,
    'house_times', v_times,
    'sources', v_sources,
    'weather', v_wx,
    'notices', v_notices,
    'house', v_house,
    'inbox_open', v_inbox);
end $$;
revoke all on function public.notices_v1(uuid) from public, anon;
grant execute on function public.notices_v1(uuid) to authenticated, service_role;
comment on function public.notices_v1(uuid) is
  'Cascade Staff v5 Notices: house_times, weather summary (null when the cache is over 60 minutes old), active and upcoming notices (each with url: the original post or advisory, or null), house items and inbox count for owner/admin only. Never money, phone or e-mail.';

-- 4. staff_home_v1 gains arrival_ready for owner and admin (cut from the 20261009040000 body) --------------------------------------------------------------
create or replace function public.staff_home_v1(p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
returns jsonb
language plpgsql stable security definer
set search_path to ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_role  text;
  v_ops_checks text[] := array['V6'];
  v_cal jsonb; v_flags jsonb; v_cur jsonb; v_next jsonb; v_warn jsonb; v_weather jsonb;
  v_priv boolean;
begin
  if not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select p.role into v_role from public.staff_access_profiles p where p.user_id = auth.uid();
  -- S82: arrival_ready is for owner and admin sessions only (the test staff_guest_companions_v1 uses); every other role's payload is unchanged.
  v_priv := exists (select 1 from public.staff_access_profiles p where p.user_id = auth.uid() and p.role in ('owner','admin') and p.disabled_at is null);

  -- calendar: names and dates only; contact columns, the raw feed text and the reconciliation fields are never selected.
  select coalesce(jsonb_agg((jsonb_build_object(
           'uid', e.uid, 'guest_name', case when e.status = 'blocked' then null else public.staff_redact_v1(e.guest_name) end,
           'checkin_date', e.checkin_date, 'checkout_date', e.checkout_date, 'nights', e.nights,
           'status', e.status, 'source', e.source,
           'checkin_time', e.checkin_time, 'checkout_time', e.checkout_time,
           -- S77 calendar contract: why a block exists, as a short label. Only the 8-character booking ref is read out of block_note.
           'block_reason', case when e.status = 'blocked' then
                             case e.block_reason when 'owner_use' then 'owner' when 'unblock' then 'other' else e.block_reason end end,
           'block_label', case when e.status = 'blocked' then
                             case e.block_reason
                               when 'direct' then 'Direct booking'
                                    || coalesce(' ' || upper(substring(e.block_note from '(?i)\mDIR\s+([0-9a-f]{8})\M')), '')
                               when 'brownout' then 'Brownout'
                               when 'maintenance' then 'Maintenance'
                               when 'owner_use' then 'Owner use'
                               else 'Blocked' end end)
           || case when v_priv and e.status = 'confirmed' and e.checkout_date >= v_today then
                jsonb_build_object('arrival_ready', public.s_arrival_ready_v1(
                  public.staff_stay_guest_id_v1(p_property_id, e.uid, e.linked_reservation_id, e.checkin_date, e.checkout_date), e.source))
              else '{}'::jsonb end) order by e.checkin_date, e.uid), '[]'::jsonb)
    into v_cal
  from public.calendar_events e
  where e.property_id = p_property_id and e.status in ('confirmed','blocked')
    and e.checkout_date >= v_today - 7 and e.checkin_date <= v_today + 60;

  -- day flags: manual flags plus brownout and maintenance derived from the calendar and the brownout notices, one per (date, kind);
  -- manual wins over a notice, a notice over a calendar block. ponytail: a brownout that runs past midnight flags its start date only.
  with n as (
    select d::date as day, 'brownout' as kind, 'Brownout' as label, 'auto' as source, null::uuid as id, 2 as pri
      from public.calendar_events e
     cross join lateral generate_series(greatest(e.checkin_date, v_today - 30)::timestamp,
                                        least(greatest(e.checkout_date - 1, e.checkin_date), v_today + 120)::timestamp, interval '1 day') d
     where e.property_id = p_property_id and e.status = 'blocked' and e.block_reason = 'brownout'
       and e.checkout_date >= v_today - 30 and e.checkin_date <= v_today + 120
    union all
    select d::date, 'maintenance', 'Maintenance', 'auto', null::uuid, 2
      from public.calendar_events e
     cross join lateral generate_series(greatest(e.checkin_date, v_today - 30)::timestamp,
                                        least(greatest(e.checkout_date - 1, e.checkin_date), v_today + 120)::timestamp, interval '1 day') d
     where e.property_id = p_property_id and e.status = 'blocked' and e.block_reason = 'maintenance'
       and e.checkout_date >= v_today - 30 and e.checkin_date <= v_today + 120
    union all
    select o.effective_date, 'brownout',
           case o.source when 'socoteco' then 'Brownout (SOCOTECO)' when 'ngcp' then 'Brownout (NGCP)' else 'Brownout' end, 'auto', null::uuid, 1
      from public.ops_notices o
     where o.property_id = p_property_id and o.is_active and o.notice_type = 'brownout'
       and coalesce(o.audience,'staff') in ('staff','all')
       and (o.expires_at is null or o.expires_at > now()) and o.effective_date >= v_today - 1
    union all
    select f.date, f.kind, public.staff_redact_v1(f.label), 'manual', f.id, 0
      from public.calendar_day_flags f
     where f.property_id = p_property_id and f.cleared_at is null
  ), u as (
    select distinct on (day, kind) day, kind, label, source, id
      from n where day between v_today - 30 and v_today + 120
     order by day, kind, pri
  )
  select coalesce(jsonb_agg(jsonb_build_object('date', day, 'kind', kind, 'label', label, 'source', source, 'id', id)
                            order by day, kind), '[]'::jsonb)
    into v_flags from u;

  -- current and next guest: the calendar fields plus the guest card (D-299.7, D-299.9).
  select jsonb_build_object('uid', s.uid, 'guest_name', public.staff_redact_v1(s.guest_name), 'source', s.source,
           'checkin_date', s.checkin_date, 'checkout_date', s.checkout_date, 'nights', s.nights,
           'checkin_time', s.checkin_time, 'checkout_time', s.checkout_time)
         || public.staff_guest_card_v1(p_property_id, s.guest_id, s.checkin_date)
         || public.staff_guest_contact_v1(s.guest_id)
         || public.staff_guest_companions_v1(s.guest_id)
         || case when v_priv then jsonb_build_object('arrival_ready', public.s_arrival_ready_v1(s.guest_id, s.source)) else '{}'::jsonb end
    into v_cur from public.staff_current_next_stays_v1(p_property_id) s where s.slot = 'current';
  select jsonb_build_object('uid', s.uid, 'guest_name', public.staff_redact_v1(s.guest_name), 'source', s.source,
           'checkin_date', s.checkin_date, 'checkout_date', s.checkout_date, 'nights', s.nights,
           'checkin_time', s.checkin_time, 'checkout_time', s.checkout_time)
         || public.staff_guest_card_v1(p_property_id, s.guest_id, s.checkin_date)
         || public.staff_guest_contact_v1(s.guest_id)
         || public.staff_guest_companions_v1(s.guest_id)
         || case when v_priv then jsonb_build_object('arrival_ready', public.s_arrival_ready_v1(s.guest_id, s.source)) else '{}'::jsonb end
    into v_next from public.staff_current_next_stays_v1(p_property_id) s where s.slot = 'next';

  with w as (
    select 'brownout' kind, 'alert' severity, public.staff_redact_v1(n.title) title,
           jsonb_build_object('date', n.effective_date, 'time', n.effective_time, 'hours', n.duration_hours,
                              'grid_line', public.staff_redact_v1(n.feeder), 'posted_by', public.staff_redact_v1(n.posted_by_name)) detail,
           n.effective_date::timestamptz at_ts, null::text as key, false as acked, null::jsonb as facts
      from public.ops_notices n
     where n.property_id = p_property_id and n.is_active and n.notice_type = 'brownout'
       and coalesce(n.audience,'staff') in ('staff','all')
       and (n.expires_at is null or n.expires_at > now()) and n.effective_date >= v_today - 1
    union all
    select 'verifier', case f.severity when 'red' then 'alert' else 'warn' end, public.staff_redact_v1(f.title) title,
           jsonb_build_object('check_id', f.check_id, 'status', f.status), f.last_seen, f.key, f.status = 'acknowledged', public.staff_verifier_facts_v1(f.check_id, f.detail)
      from public.verifier_findings f
     where f.status = 'open'
       and (v_role in ('owner','admin','finance') or f.check_id = any(v_ops_checks))
    union all
    select 'inventory', 'warn', public.staff_redact_v1('Low stock: ' || i.name) title,
           jsonb_build_object('qty', i.qty_on_hand, 'unit', i.unit, 'reorder_below', i.reorder_below), i.updated_at, null::text, false, null::jsonb
      from public.inventory_items i
     where i.property_id = p_property_id and i.is_active and i.qty_on_hand < i.reorder_below
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'severity', severity, 'title', title,
                                               'detail', detail, 'at', at_ts, 'key', key, 'acknowledged', acked, 'facts', facts)
                  order by case kind when 'brownout' then 0 when 'inventory' then 2 else 1 end, at_ts desc), '[]'::jsonb)
    into v_warn from w;

  -- weather: the 15-minute cache weather-proxy keeps; an allow-list of eight display fields, nothing else.
  select jsonb_build_object('source', s.value->>'source', 'fetched_at', s.value->>'fetched_at',
                            'current', jsonb_build_object(
                              'temp', s.value#>'{current,temp}', 'emoji', s.value#>'{current,emoji}',
                              'description', s.value#>'{current,description}', 'rain_prob', s.value#>'{current,rain_prob}',
                              'today_high', s.value#>'{current,today_high}', 'today_low', s.value#>'{current,today_low}',
                              'humidity', s.value#>'{current,humidity}', 'uv_label', s.value#>'{current,uv_label}'))
    into v_weather from public.app_settings s where s.key = 'weather_proxy_cache';

  return jsonb_build_object(
    'role', v_role, 'today', v_today, 'property_id', p_property_id,
    'calendar', v_cal, 'day_flags', v_flags, 'current_guest', v_cur, 'next_guest', v_next,
    'warnings', v_warn, 'weather', v_weather, 'generated_at', now());
end $$;
revoke all on function public.staff_home_v1(uuid) from public, anon;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;
comment on function public.staff_home_v1(uuid) is
  'Cascade Staff home (SPEC-36, S77, D-319, S82): calendar with block_reason/block_label, day_flags, current/next guest with returning marker and notes, open system-check warnings with key/acknowledged/facts, weather. Owner and admin sessions also get the current/next guest phone, e-mail and Messenger thread, companions (name, has_photo) and arrival_ready {id, paid, door_code} on every upcoming or in-house stay; never money; cleaners and other roles never get contact details, companions or arrival_ready (D-289).';

-- 7. staff pay, admin side: unrequested list and the web-settle label --------------------------------------------------------------------------------------
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
revoke all on function public.staff_pay_admin_list_v1() from public, anon, service_role;
grant execute on function public.staff_pay_admin_list_v1() to authenticated;

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
revoke all on function public.staff_pay_settle_v1(uuid, bigint, text, text, jsonb) from public, anon, authenticated, service_role;
-- 9. save_shopping_item_v1 (cut from the 20260913120000 body) ----------------------------------------------------------------------------------------------
create or replace function public.save_shopping_item_v1(p_property_id uuid, p_item jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row public.inventory_shopping_list%rowtype; v_id uuid; v_status text;
begin
  perform public.admin_require('read_operations', p_property_id);
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key required'; end if;
  v_id := nullif(p_item->>'id', '')::uuid;
  if v_id is null then
    select * into v_row from public.inventory_shopping_list where idempotency_key = p_idempotency_key;
    if found then return jsonb_build_object('ok', true, 'id', v_row.id, 'replayed', true); end if;
    insert into public.inventory_shopping_list(property_id, item_id, item_name, quantity, purchase_unit, estimated_cost, reason, proposed_by, idempotency_key)
    values (p_property_id, nullif(p_item->>'item_id', '')::uuid, p_item->>'item_name', (p_item->>'quantity')::numeric, p_item->>'purchase_unit', nullif(p_item->>'estimated_cost', '')::numeric, p_item->>'reason', auth.uid(), p_idempotency_key)
    returning * into v_row;
  else
    v_status := p_item->>'status';
    if v_status in ('approved','rejected') then perform public.admin_require('manage_inventory', p_property_id); end if;
    select * into v_row from public.inventory_shopping_list where id = v_id and property_id = p_property_id for update;
    if not found then raise exception using errcode = 'P0002', message = 'shopping item not found'; end if;
    -- S82: without manage_inventory: only a row she proposed herself, only while it is still proposed, only to edit it or cancel it, never an approval note
    if not public.current_staff_authorized('manage_inventory', p_property_id)
       and (v_row.proposed_by is distinct from auth.uid() or v_row.status <> 'proposed' or coalesce(v_status, 'proposed') not in ('proposed', 'cancelled') or p_item ? 'approval_note') then
      raise exception using errcode = '42501', message = 'manage_inventory denied';
    end if;
    if v_status = 'received' then raise exception using errcode = '22023', message = 'use record_inventory_receipt_v1 to receive goods'; end if;
    update public.inventory_shopping_list set
      status = coalesce(v_status, status), quantity = coalesce(nullif(p_item->>'quantity', '')::numeric, quantity), reason = coalesce(p_item->>'reason', reason),
      approved_by = case when v_status in ('approved','rejected') then auth.uid() else approved_by end,
      approved_at = case when v_status in ('approved','rejected') then now() else approved_at end,
      approval_note = coalesce(p_item->>'approval_note', approval_note), version = version + 1, updated_at = now()
    where id = v_id returning * into v_row;
  end if;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'status', v_row.status, 'version', v_row.version);
end;
$$;
revoke all on function public.save_shopping_item_v1(uuid, jsonb, text) from public, anon, service_role;
grant execute on function public.save_shopping_item_v1(uuid, jsonb, text) to authenticated;

-- 10. inventory: the Telegram receipt restock on a movement-controlled item (owner decision 2026-10-15, staff count in the app) ------------------------
-- reconcile_inventory_baseline_v1 makes an item movement-controlled, one way: from then on qty_on_hand must equal the last inventory_stock_movements row,
-- or inventory_ledger_consistent goes red and every movement RPC refuses with "stock reconciliation required". apply_inventory_purchase used to write
-- qty_on_hand alone. For a controlled item it now writes the same 'receipt' movement record_inventory_receipt_v1 writes (through the internal helper below,
-- which locks the item, checks the ledger is consistent, and keys the movement on the purchase row so it can never be written twice). An uncontrolled item
-- runs exactly the old statements. A controlled item with the same p_txn_id seen before answers {ok, replayed} and writes nothing (the old function had no
-- such guard; uncontrolled items keep that old behaviour). The movement's actor is the signed-in person, else the person who reconciled the item (a service
-- role has no user; actor_user_id is NOT NULL). The helper is callable by the service role and by a signed-in owner/admin only.
create or replace function public.s_inventory_purchase_movement_v1(p_item_id uuid, p_units numeric, p_reason text, p_source_ref text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; m public.inventory_stock_movements%rowtype; v_after numeric; v_actor uuid; v_id uuid;
begin
  select * into i from public.inventory_items where id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  if not (coalesce(auth.role(), '') = 'service_role' or public.inventory_human_authorized(i.property_id)) then
    raise exception using errcode = '42501', message = 'inventory access denied';
  end if;
  if i.movement_controlled_at is null then raise exception using errcode = '22023', message = 'item is not movement controlled'; end if;
  if p_units is null or p_units <= 0 or p_units >= 100000000 then raise exception using errcode = '22023', message = 'invalid quantity'; end if;
  select * into m from public.inventory_stock_movements where item_id = i.id order by sequence_no desc limit 1;
  if not found or m.quantity_after is distinct from i.qty_on_hand or m.property_id is distinct from i.property_id then
    raise exception using errcode = '22023', message = 'stock reconciliation required';
  end if;
  v_actor := coalesce(auth.uid(), i.baseline_reviewed_by);
  if v_actor is null then raise exception using errcode = '22023', message = 'no actor for this movement'; end if;
  v_after := i.qty_on_hand + p_units;
  insert into public.inventory_stock_movements(item_id, property_id, kind, quantity_before, quantity_after, reason, actor_user_id, idempotency_key)
  values (i.id, i.property_id, 'receipt', i.qty_on_hand, v_after, btrim(p_reason), v_actor,
          left('evt-' || encode(extensions.digest('inventory_purchases|' || p_source_ref || '|' || i.id::text || '|receipt', 'sha256'), 'hex'), 80))
  returning id into v_id;
  update public.inventory_items set qty_on_hand = v_after where id = i.id;
  return jsonb_build_object('before', i.qty_on_hand, 'after', v_after, 'movement_id', v_id);
end;
$$;
revoke all on function public.s_inventory_purchase_movement_v1(uuid, numeric, text, text) from public, anon;
grant execute on function public.s_inventory_purchase_movement_v1(uuid, numeric, text, text) to authenticated, service_role;

create or replace function public.apply_inventory_purchase(p_item_id uuid, p_qty numeric, p_unit_cost numeric default null::numeric, p_supplier text default null::text, p_purchased_at date default current_date, p_txn_id uuid default null::uuid)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_upp numeric; v_before numeric; v_after numeric; v_pid uuid; v_name text; v_controlled boolean; v_mv jsonb;
begin
  select coalesce(units_per_purchase, 1), qty_on_hand, name, movement_controlled_at is not null
    into v_upp, v_before, v_name, v_controlled
  from inventory_items where id = p_item_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'item_not_found');
  end if;

  -- S82: a movement-controlled item with this receipt transaction already restocked is answered, not added twice
  if v_controlled and p_txn_id is not null then
    select id into v_pid from inventory_purchases where item_id = p_item_id and notes like '%(txn ' || p_txn_id::text || ')%' limit 1;
    if found then
      return jsonb_build_object('ok', true, 'replayed', true, 'name', v_name, 'purchase_id', v_pid, 'qty_before', v_before, 'qty_after', v_before, 'added', 0);
    end if;
  end if;

  insert into inventory_purchases(item_id, qty, unit_cost, supplier, purchased_at, units_per_purchase, notes)
  values (p_item_id, p_qty, p_unit_cost, p_supplier, coalesce(p_purchased_at, current_date), v_upp,
          'Auto-restock from receipt OCR' || case when p_txn_id is not null then ' (txn ' || p_txn_id::text || ')' else '' end)
  returning id into v_pid;

  if v_controlled then
    v_mv := public.s_inventory_purchase_movement_v1(p_item_id, p_qty * v_upp,
              'Auto-restock from receipt OCR' || case when p_txn_id is not null then ' (txn ' || p_txn_id::text || ')' else '' end, v_pid::text);
    v_before := (v_mv ->> 'before')::numeric;
    v_after := (v_mv ->> 'after')::numeric;
  else
    v_after := coalesce(v_before, 0) + (p_qty * v_upp);
    update inventory_items set qty_on_hand = v_after where id = p_item_id;
  end if;

  insert into inventory_audit_log(entity_type, entity_id, action, before, after, actor)
  values ('inventory_items', p_item_id, 'ocr_restock',
          jsonb_build_object('qty_on_hand', v_before),
          jsonb_build_object('qty_on_hand', v_after, 'purchase_id', v_pid, 'qty_added', p_qty * v_upp),
          'telegram-ocr');

  return jsonb_build_object('ok', true, 'name', v_name, 'purchase_id', v_pid,
                            'qty_before', v_before, 'qty_after', v_after, 'added', p_qty * v_upp);
end; $$;
revoke execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) from public, anon;
grant execute on function public.apply_inventory_purchase(uuid, numeric, numeric, text, date, uuid) to authenticated, service_role;

-- 11. inventory_shopping_list: costs and edits ----------------------------------------------------------------------------------------------------
-- A column grant cannot tell an owner from a cleaner (both are `authenticated`), so the table loses its cost columns for direct reads and a definer read
-- model, get_shopping_list_v1, hands them to finance_human_authorized sessions only (the same test get_inventory_catalogue_v1 uses for unitCost).
-- WIRING: the admin dashboard's purchases page reads this table with select('*'), which now fails; it must call get_shopping_list_v1 (see the report).
revoke select on public.inventory_shopping_list from authenticated;
do $$
declare v_cols text;
begin
  select string_agg(format('%I', c.column_name), ', ' order by c.ordinal_position) into v_cols
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'inventory_shopping_list' and c.column_name not in ('estimated_cost', 'unit_cost', 'supplier');
  execute format('grant select (%s) on public.inventory_shopping_list to authenticated', v_cols);
end $$;

create or replace function public.get_shopping_list_v1(p_property_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_fin boolean; v_rows jsonb;
begin
  perform public.admin_require('read_operations', p_property_id);
  v_fin := public.finance_human_authorized(p_property_id);
  select coalesce(jsonb_agg(case when v_fin then to_jsonb(l) else to_jsonb(l) - 'estimated_cost' - 'unit_cost' - 'supplier' end order by l.proposed_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.inventory_shopping_list where property_id = p_property_id order by proposed_at desc limit 200) l;
  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;
revoke all on function public.get_shopping_list_v1(uuid) from public, anon, service_role;
grant execute on function public.get_shopping_list_v1(uuid) to authenticated;
comment on function public.get_shopping_list_v1(uuid) is 'S82: the shopping list for read_operations sessions. estimated_cost, unit_cost and supplier only for finance_human_authorized sessions (the table no longer grants them for direct reads).';


-- 5. cleaning progress ------------------------------------------------------------------------------------------------------------------------
-- A cleaner (anyone who may submit a cleaning) records where she is: step of of, with the section name. One row per (property, her, Manila day).
create or replace function public.cleaning_progress_set_v1(p_step integer, p_of integer, p_label text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_name text;
begin
  if v_uid is null or not public.current_staff_authorized('submit_cleaning', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  if p_step is null or p_of is null or p_of not between 1 and 200 or p_step not between 0 and p_of then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  -- first name only: the name she signs her cleans with, else her profile name
  select nullif(btrim(cs.cleaner_name), '') into v_name from public.cleaning_sessions cs
   where cs.property_id = c_prop and cs.submitted_by_user_id = v_uid order by cs.cleaned_at desc limit 1;
  if v_name is null then
    select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                    initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')))
      into v_name from auth.users u where u.id = v_uid;
  end if;
  v_name := left(coalesce(nullif(split_part(btrim(coalesce(v_name, '')), ' ', 1), ''), 'Cleaner'), 40);

  insert into public.cleaning_progress as p (property_id, user_id, day, step, of_steps, label, cleaner_name)
  values (c_prop, v_uid, v_today, p_step, p_of, nullif(left(btrim(coalesce(p_label, '')), 80), ''), v_name)
  on conflict (property_id, user_id, day) do update
    set step = excluded.step, of_steps = excluded.of_steps, label = excluded.label, cleaner_name = excluded.cleaner_name, updated_at = now(),
        -- a second clean the same day starts a new run
        started_at = case when p.step >= p.of_steps and excluded.step < excluded.of_steps then now() else p.started_at end;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.cleaning_progress_set_v1(integer, integer, text) from public, anon, service_role;
grant execute on function public.cleaning_progress_set_v1(integer, integer, text) to authenticated;

-- Owner and admin: the cleaner who touched her checklist most recently today, or null.
create or replace function public.cleaning_progress_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_day_start timestamptz := ((now() at time zone 'Asia/Manila')::date)::timestamp at time zone 'Asia/Manila';
  v_active jsonb;
begin
  if auth.uid() is null or not public.current_staff_authorized('manage_operations', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  select jsonb_build_object('step', p.step, 'of', p.of_steps, 'label', public.staff_redact_v1(p.label),
                            'started_at', p.started_at, 'updated_at', p.updated_at, 'cleaner_name', p.cleaner_name)
    into v_active
    from public.cleaning_progress p
   where p.property_id = c_prop and p.updated_at >= v_day_start
   order by p.updated_at desc limit 1;
  return jsonb_build_object('ok', true, 'active', v_active);
end $$;
revoke all on function public.cleaning_progress_v1() from public, anon, service_role;
grant execute on function public.cleaning_progress_v1() to authenticated;

-- 6. staff_pay_admin_create_v1 (MONEY) ----------------------------------------------------------------------------------------------------------
-- An owner/admin/finance user makes the same `requested` row staff_pay_request_create_v1 would have made for the staff member, from her unpaid cleans and
-- her unpaid expense claims. Same guards in the same order, same row locks (sessions then claims, each in id order), same line shapes, same total. It
-- validates everything first and writes last, so every {ok:false} leaves nothing behind. The key is idempotent per (payee, key): the second call with the
-- same key answers the first one's row (replay) and writes nothing; a different key for the same work is refused (session_taken / claim_taken).
-- p_sessions = [{id, transport:bool}]. No typed extras: only work that is already on file. Returns {ok:true, id, ref, ...}.
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
revoke all on function public.staff_pay_admin_create_v1(uuid, jsonb, uuid[], text) from public, anon, service_role;
grant execute on function public.staff_pay_admin_create_v1(uuid, jsonb, uuid[], text) to authenticated;

-- 8. weekly sweep -------------------------------------------------------------------------------------------------------------------------------
-- Requests paid in the last 7 days whose "you were paid" notice was never claimed (the trigger's call was lost). notify-cleaner-payment claims the
-- notice once, so a second ask for a request that was told in the meantime sends nothing.
create or replace function public.s_paid_unnotified_v1() returns setof uuid
language sql stable security definer set search_path to '' as $$
  select r.id from public.staff_pay_requests r
   where r.status = 'paid' and r.paid_at > now() - interval '7 days' and r.paid_notified_at is null
   order by r.paid_at limit 20;
$$;
revoke all on function public.s_paid_unnotified_v1() from public, anon, authenticated, service_role;

create or replace function public.s_weekly_sweep_v1() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_secret text; v_id uuid; v_fired integer := 0; v_hashes integer := 0; v_progress integer := 0;
begin
  perform public.record_job_heartbeat('pay-weekly-sweep', 'started');
  delete from public.staff_upload_hashes where created_at < now() - interval '90 days';
  get diagnostics v_hashes = row_count;
  delete from public.cleaning_progress where day < (now() at time zone 'Asia/Manila')::date - 14;
  get diagnostics v_progress = row_count;
  -- same guards as staff_pay_notify_paid_trg: where pg_net or the vault secret is absent (a rehearsal copy) nothing is sent
  if to_regnamespace('net') is not null and to_regclass('vault.decrypted_secrets') is not null then
    begin
      execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret' limit 1$q$ into v_secret;
      if coalesce(v_secret, '') <> '' then
        for v_id in select * from public.s_paid_unnotified_v1() loop
          perform net.http_post(
            url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/notify-cleaner-payment',
            headers := jsonb_build_object('Content-Type', 'application/json', 'x-cascade-cron-secret', v_secret),
            body := jsonb_build_object('action', 'paid', 'request_id', v_id),
            timeout_milliseconds := 20000);
          v_fired := v_fired + 1;
        end loop;
      end if;
    exception when others then
      raise warning 's_weekly_sweep_v1: could not queue the paid notices (%)', sqlstate;
    end;
  end if;
  perform public.record_job_heartbeat('pay-weekly-sweep', 'succeeded');
  return jsonb_build_object('purged_upload_hashes', v_hashes, 'purged_progress_rows', v_progress, 'paid_notices_asked', v_fired);
end $$;
revoke all on function public.s_weekly_sweep_v1() from public, anon, authenticated, service_role;

-- record_job_heartbeat refuses an unknown job: seeded as succeeded now, expected every 8 days (one late Monday is not an alert), no ops risk.
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('pay-weekly-sweep', 691200, false, now())
on conflict (job_name) do update set expected_interval_seconds = excluded.expected_interval_seconds, ops_risk = excluded.ops_risk;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - s82-pay-weekly-sweep wiring skipped';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 's82-pay-weekly-sweep';
  perform cron.schedule('s82-pay-weekly-sweep', '30 22 * * 0', $cmd$select public.s_weekly_sweep_v1();$cmd$);
  if (select count(*) from cron.job where jobname = 's82-pay-weekly-sweep' and active and schedule = '30 22 * * 0'
        and command like '%s_weekly_sweep_v1%') <> 1 then
    raise exception 's82-pay-weekly-sweep not scheduled';
  end if;
end $$;

-- 9. comments, final check ----------------------------------------------------------------------------------------------------------------------
comment on function public.cleaning_progress_set_v1(integer, integer, text) is 'S82: a cleaner records step p_step of p_of (and the section name) for today. One row per cleaner per Manila day.';
comment on function public.cleaning_progress_v1() is 'S82: owner/admin read the cleaner who touched her checklist most recently today ({step, of, label, started_at, updated_at, cleaner_name}) or null.';
comment on function public.staff_pay_admin_create_v1(uuid, jsonb, uuid[], text) is 'S82 (money): owner/admin/finance make a normal requested pay request for a staff member from her unpaid cleans and claims. Same rate rule, guards and locks as staff_pay_request_create_v1; idempotent on (payee, key); marked created_by_user_id.';

do $$
begin
  if to_regclass('public.cleaning_progress') is null then raise exception 'cleaning_progress missing'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.cleaning_progress'::regclass) then raise exception 'cleaning_progress RLS not enabled'; end if;
  if has_table_privilege('authenticated', 'public.cleaning_progress', 'select,insert,update,delete') or has_table_privilege('anon', 'public.cleaning_progress', 'select,insert,update,delete') then
    raise exception 'cleaning_progress is open to an API role';
  end if;
  if has_function_privilege('anon', 'public.staff_pay_admin_create_v1(uuid,jsonb,uuid[],text)', 'execute') then raise exception 'anon can create a pay request'; end if;
  if has_function_privilege('authenticated', 'public.s_arrival_ready_v1(uuid,text)', 'execute') then raise exception 'authenticated can run the arrival helper'; end if;
  if has_function_privilege('authenticated', 'public.s_weekly_sweep_v1()', 'execute') then raise exception 'authenticated can run the weekly sweep'; end if;
end $$;

commit;
