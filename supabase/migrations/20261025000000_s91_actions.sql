-- 20261025000000_s91_actions.sql
-- Session 91, lane SQL: release s91_actions_20261025. Five changes, two functions replaced (contract: Cascade/docs/s91/CONTRACT.md).
-- (1) guest_companions.id_photo_rotation smallint null, check in (0, 90, 180, 270). A BEFORE UPDATE OF id_photo_path trigger sets it back to null when the
--     photo path changes, so a replaced photo never inherits the old turn. anon has no access to guest_companions; authenticated has table-level SELECT
--     under the manage_operations RLS policy, no column ACLs and no UPDATE, so the column follows id_photo_path's privileges. Staff write it only through the RPCs below.
-- (2) staff_photo_rotation_v1(text[]): read_operations. Returns (path, rotation) only for paths the caller may view: manage_operations on the companion's
--     property, or staff_can_view_guest_id_object_v1(path). Unknown or refused paths are absent. Null rotation = never turned. At most 50 paths (22023).
-- (3) set_guest_photo_rotation_v1(text, smallint): manage_operations (owner/admin). Rotation outside 0/90/180/270 -> 22023 'rotation_invalid';
--     unknown path -> {ok:false, error:'not_found'}. No audit row: the generic admin_audit_row_v1 would copy id_number into admin_audit_log, and a turn is cosmetic.
-- (4) ops_notice_close_v1(uuid, uuid): manage_operations. Sets is_active = false on that notice (any source) for the caller's property. The existing
--     admin_audit_row trigger on ops_notices writes the audit row, labelled soft_delete via admin_audit_context_v1 like admin_soft_delete_v1.
--     Only hand-added notices close (source manual/staff, or no source on a non-brownout); feed notices -> {ok:false, error:'not_closable'}. Absent or other property -> 'not_found'.
-- (5) notices_v1: house findings show status = 'open' only (was open + acknowledged), so Resolve (ack_verifier_finding_v1) removes the row, as staff_home_v1 does.
-- (6) Low stock, ONE rule: i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below ("at or below the reorder level"). Chosen because
--     every other reader already uses <=: the inventory screens (s84/s86 'attention'), admin_overview low_stock, the daily digest and telegram-expense/inventory-report.
--     notices_v1 already used it; staff_home_v1 used '<' (an item exactly at its level was missing from the home warnings) and now matches.
-- Guards: the live notices_v1 and staff_home_v1 must be the s82 bodies this was cut from (md5 of prosrc, CR stripped, read live 2026-10-16), else 55000, nothing changes.
-- Everything below the guards is single shot. To undo apply supabase/rollbacks/20261025_s91_actions.sql.

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.notices_v1(uuid)');
  if v_got is distinct from '5a499767e7e1b373e029c430d89cddfe' then
    raise exception 's91 actions: notices_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.staff_home_v1(uuid)');
  if v_got is distinct from '7d848a295c76350bab83dab587ba44f6' then
    raise exception 's91 actions: staff_home_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

-- 1. rotation column + reset on photo change ------------------------------------------------------------------------------------------------
alter table public.guest_companions add column if not exists id_photo_rotation smallint check (id_photo_rotation in (0, 90, 180, 270));
comment on column public.guest_companions.id_photo_rotation is 'S91: clockwise turn in degrees (0, 90, 180, 270) staff applied to the ID photo; null = never turned. Reset to null when id_photo_path changes.';

create or replace function public.guest_companions_reset_rotation()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.id_photo_path is distinct from old.id_photo_path then new.id_photo_rotation := null; end if;
  return new;
end $$;
revoke all on function public.guest_companions_reset_rotation() from public, anon, authenticated, service_role;
drop trigger if exists guest_companions_reset_rotation on public.guest_companions;
create trigger guest_companions_reset_rotation before update of id_photo_path on public.guest_companions
  for each row execute function public.guest_companions_reset_rotation();

-- 2. read rotations --------------------------------------------------------------------------------------------------------------------------
create or replace function public.staff_photo_rotation_v1(p_paths text[])
returns table(path text, rotation smallint)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_pid uuid := coalesce((select s.property_id from public.staff_property_access s where s.user_id = auth.uid() order by s.property_id limit 1),
                         '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
begin
  if not public.current_staff_authorized('read_operations', v_pid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_paths is null then return; end if;
  if cardinality(p_paths) > 50 then raise exception 'too_many_paths' using errcode = '22023'; end if;
  return query
    select c.id_photo_path, max(c.id_photo_rotation)::smallint
      from public.guest_companions c
     where c.id_photo_path = any(p_paths)
       and (public.current_staff_authorized('manage_operations', c.property_id) or public.staff_can_view_guest_id_object_v1(c.id_photo_path))
     group by c.id_photo_path;
end $$;

-- 3. set rotation ----------------------------------------------------------------------------------------------------------------------------
create or replace function public.set_guest_photo_rotation_v1(p_path text, p_rotation smallint)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_pid uuid := coalesce((select s.property_id from public.staff_property_access s where s.user_id = auth.uid() order by s.property_id limit 1),
                         '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
  v_n integer;
begin
  if not public.current_staff_authorized('manage_operations', v_pid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_rotation is null or p_rotation not in (0, 90, 180, 270) then
    raise exception 'rotation_invalid' using errcode = '22023';
  end if;
  -- the gate sits in WHERE (an unreferenced lateral would be optimised away): only photos on a property the caller manages.
  update public.guest_companions c set id_photo_rotation = p_rotation
   where c.id_photo_path = p_path and public.current_staff_authorized('manage_operations', c.property_id);
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'path', p_path, 'rotation', p_rotation);
end $$;

-- 4. close a notice --------------------------------------------------------------------------------------------------------------------------
create or replace function public.ops_notice_close_v1(p_id uuid, p_property_id uuid default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_pid uuid := coalesce(p_property_id,
                         (select s.property_id from public.staff_property_access s where s.user_id = auth.uid() order by s.property_id limit 1),
                         '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
  v_n integer;
begin
  if not public.current_staff_authorized('manage_operations', v_pid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- only a hand-added notice closes (the client's rule, lib.js A_heads, and notices_v1's 'manual' label: source manual or staff, or no source on a non-brownout);
  -- socoteco / gscwd / ngcp / system notices come from feeds and are not closable here.
  if exists (select 1 from public.ops_notices n where n.id = p_id and n.property_id = v_pid and n.is_active
                and not (n.source in ('manual', 'staff') or (n.source is null and n.notice_type <> 'brownout'))) then
    return jsonb_build_object('ok', false, 'error', 'not_closable');
  end if;
  perform public.admin_audit_context_v1('notice closed by staff', 'soft_delete', null);
  update public.ops_notices n set is_active = false
   where n.id = p_id and n.property_id = v_pid and n.is_active
     and (n.source in ('manual', 'staff') or (n.source is null and n.notice_type <> 'brownout'));
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;

-- 5. notices_v1 (live s82 body; only the findings filter changed) -----------------------------------------------------------------------------
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
          from public.verifier_findings f where f.status = 'open'
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

-- 6. staff_home_v1 (live s82 body; only the low-stock comparison changed: < becomes <= and a null level is excluded explicitly) -----------------
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
     where i.property_id = p_property_id and i.is_active and i.reorder_below is not null and i.qty_on_hand <= i.reorder_below
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

-- 6b. RLS on guests and airbnb_reservations follows the live staff profile, not the JWT claim --------------------------------------------------
-- Both owner/admin policies trusted auth.jwt()->app_metadata->role, so an admin disabled (or with revoked sessions) kept reading guest names, phones, e-mails
-- and notes over REST until the access token expired. current_staff_active(roles) checks staff_access_profiles: not disabled, role in the list, token issued
-- after sessions_revoked_after. Read live 2026-10-16: every owner/admin auth user has a matching active profile, so no active owner/admin loses access.
-- Readers checked: admin-dashboard (bookings, finance, guests, search APIs), the Staff app (calendar guests lookup, Guests screen): all owner/admin screens.
-- airbnb_reservations_finance_read (finance, read_finance) and the service_role policy are untouched; the four views on airbnb_reservations are security_invoker.
alter policy guests_owner_admin_all on public.guests
  using ((select public.current_staff_active(array['owner', 'admin'])))
  with check ((select public.current_staff_active(array['owner', 'admin'])));
alter policy airbnb_reservations_owner_admin_all on public.airbnb_reservations
  using ((select public.current_staff_active(array['owner', 'admin'])))
  with check ((select public.current_staff_active(array['owner', 'admin'])));

-- 6c. (moved out) Narrowing the guests table grants is a contract-phase change; it ships in its own release after this one.

-- 7. grants: state the end state---------------------------------------------------------------------------------------------------------------
revoke all on function public.notices_v1(uuid) from public, anon;
grant execute on function public.notices_v1(uuid) to authenticated, service_role;
revoke all on function public.staff_home_v1(uuid) from public, anon;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;
revoke all on function public.staff_photo_rotation_v1(text[]) from public, anon;
grant execute on function public.staff_photo_rotation_v1(text[]) to authenticated, service_role;
revoke all on function public.set_guest_photo_rotation_v1(text, smallint) from public, anon;
grant execute on function public.set_guest_photo_rotation_v1(text, smallint) to authenticated, service_role;
revoke all on function public.ops_notice_close_v1(uuid, uuid) from public, anon;
grant execute on function public.ops_notice_close_v1(uuid, uuid) to authenticated, service_role;

comment on function public.staff_photo_rotation_v1(text[]) is 'S91: (path, rotation) for ID photo paths the caller may view (owner/admin, or staff_can_view_guest_id_object_v1). Null rotation = never turned. At most 50 paths.';
comment on function public.set_guest_photo_rotation_v1(text, smallint) is 'S91: owner/admin turn an ID photo (0, 90, 180, 270). {ok:false,error:not_found} for an unknown path.';
comment on function public.ops_notice_close_v1(uuid, uuid) is 'S91: owner/admin close (is_active=false) any ops_notices row on their property. {ok:false,error:not_found} when absent.';

commit;
