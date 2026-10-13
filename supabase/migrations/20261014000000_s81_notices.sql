-- 20261014000000_s81_notices.sql
-- Session 81, lane B (SQL): release s81_notices_20261014. The Cascade Staff v5 "Notices" read and the owner/admin "Add a notice" write.
--   notices_v1(uuid)        ONE role-gated read: house_times, the weather summary (from the weather-proxy cache, null when older than 60
--                           minutes), the active and upcoming ops_notices mapped to the contract types, house items and the open Messenger
--                           handoff count for owner/admin only. Every key is an allow-list entry; free text goes through staff_redact_v1
--                           (phones, e-mails, money); no money and no guest contact key exists in the payload.
--   ops_notice_add_v1(...)  owner/admin only (manage_operations): a short manual notice of type water, maintenance, deep_clean or note.
--                           Text containing a phone number, e-mail or amount is REFUSED, not silently edited.
--   ops_notices checks      notice_type gains water, maintenance, deep_clean, note; source gains gscwd, manual, system. The old values stay,
--                           so power-watch, telegram-expense and the admin dashboard keep working unchanged.
--   app_settings house_times  {"check_out":"12:00","check_in":"14:00"}, seeded only when the key is absent (read 2026-10-13: no such key,
--                           and no key under another name, existed).
-- Water source (read 2026-10-13): gensanwater.gov.ph/wp-json/wp/v2/posts is a WordPress feed of bids and awards only; its "Water Advisory"
-- category holds 0 posts and a search for "interruption" returns nothing. So no water-watch scraper: water notices arrive by a post forwarded to
-- Cassy (Save tap, source stays null here and reads as 'manual') or by ops_notice_add_v1.
--   app_settings notice_sources  {"water_page":"https://www.facebook.com/gscwaterdistrict/","power_page":"https://www.facebook.com/socoteco2.EC/"}, seeded
--                           only when absent; notices_v1 returns it as `sources` so the app can link "Check the GSCWD page" / "Check the SOCOTECO II page".
-- Fix round 1 (Opus review): a notice that started earlier and is still running stays listed (its window has not ended); low stock uses the admin
-- overview's comparison (reorder_below not null and qty_on_hand <= reorder_below); a brownout's " | poster <file>" suffix is stripped from detail.
-- Rollback: supabase/rollbacks/20261014_s81_notices.sql

begin;

-- 1. checks -------------------------------------------------------------------------------------------------------------------------
alter table public.ops_notices drop constraint if exists ops_notices_notice_type_check;
alter table public.ops_notices add constraint ops_notices_notice_type_check
  check (notice_type in ('brownout', 'holiday', 'event', 'reminder', 'water', 'maintenance', 'deep_clean', 'note'));
alter table public.ops_notices drop constraint if exists ops_notices_source_check;
alter table public.ops_notices add constraint ops_notices_source_check
  check (source in ('socoteco', 'ngcp', 'staff', 'gscwd', 'manual', 'system'));

-- 2. shared setting -----------------------------------------------------------------------------------------------------------------
insert into public.app_settings (key, value, updated_at)
values ('house_times', '{"check_out":"12:00","check_in":"14:00"}'::jsonb, now())
on conflict (key) do nothing;

insert into public.app_settings (key, value, updated_at)
values ('notice_sources', '{"water_page":"https://www.facebook.com/gscwaterdistrict/","power_page":"https://www.facebook.com/socoteco2.EC/"}'::jsonb, now())
on conflict (key) do nothing;

-- 3. notices_v1 ---------------------------------------------------------------------------------------------------------------------
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

  select jsonb_build_object('water_page', s.value->>'water_page', 'power_page', s.value->>'power_page')
    into v_sources from public.app_settings s where s.key = 'notice_sources';
  v_sources := coalesce(v_sources, '{"water_page":"https://www.facebook.com/gscwaterdistrict/","power_page":"https://www.facebook.com/socoteco2.EC/"}'::jsonb);

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
           'detail', public.staff_redact_v1(nullif(btrim(regexp_replace(n.description, '(^|\s*\|\s*)poster\s+\S+\s*$', '')), ''))
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

-- 4. ops_notice_add_v1 --------------------------------------------------------------------------------------------------------------
create or replace function public.ops_notice_add_v1(
  p_type text, p_title text, p_date date, p_start_time time default null, p_duration_hours numeric default null,
  p_detail text default null, p_property_id uuid default null)
returns jsonb
language plpgsql volatile security definer
set search_path to ''
as $$
declare
  v_pid   uuid := coalesce(p_property_id,
                           (select s.property_id from public.staff_property_access s where s.user_id = auth.uid() order by s.property_id limit 1),
                           '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_title text := btrim(p_title);
  v_detail text := nullif(btrim(p_detail), '');
  v_id    uuid;
begin
  if not public.current_staff_authorized('manage_operations', v_pid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_type is null or p_type not in ('water', 'maintenance', 'deep_clean', 'note') then
    raise exception 'type_not_allowed' using errcode = '22023';
  end if;
  if v_title is null or char_length(v_title) < 1 or char_length(v_title) > 80 then
    raise exception 'title_length' using errcode = '22023';
  end if;
  if v_detail is not null and char_length(v_detail) > 200 then
    raise exception 'detail_length' using errcode = '22023';
  end if;
  -- a phone number, e-mail or amount is refused, never stored: the redaction helper would change it.
  if public.staff_redact_v1(v_title) <> v_title or (v_detail is not null and public.staff_redact_v1(v_detail) <> v_detail) then
    raise exception 'contact_or_amount_not_allowed' using errcode = '22023';
  end if;
  if p_date is null or p_date < v_today - 1 or p_date > v_today + 365 then
    raise exception 'date_out_of_range' using errcode = '22023';
  end if;
  if p_duration_hours is not null and (p_duration_hours <= 0 or p_duration_hours > 72) then
    raise exception 'duration_out_of_range' using errcode = '22023';
  end if;

  insert into public.ops_notices (property_id, notice_type, title, description, effective_date, effective_time, duration_hours, source, audience)
  values (v_pid, p_type, v_title, v_detail, p_date, p_start_time, p_duration_hours, 'manual', 'staff')
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'type', p_type, 'title', v_title, 'date', p_date);
end $$;

-- 5. grants: state the end state (a --no-acl restore starts from default privileges) ---------------------------------------------------
revoke all on function public.notices_v1(uuid) from public, anon;
grant execute on function public.notices_v1(uuid) to authenticated, service_role;
revoke all on function public.ops_notice_add_v1(text, text, date, time, numeric, text, uuid) from public, anon;
grant execute on function public.ops_notice_add_v1(text, text, date, time, numeric, text, uuid) to authenticated, service_role;

comment on function public.notices_v1(uuid) is
  'Cascade Staff v5 Notices: house_times, weather summary (null when the cache is over 60 minutes old), active and upcoming notices, house items and inbox count for owner/admin only. Never money, phone or e-mail.';
comment on function public.ops_notice_add_v1(text, text, date, time, numeric, text, uuid) is
  'Owner/admin: add a short manual water, maintenance, deep_clean or note notice. Phone numbers, e-mails and amounts are refused.';

commit;
