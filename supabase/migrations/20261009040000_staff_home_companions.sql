-- 20261009040000_staff_home_companions.sql
-- Session 79 (lane B, SQL), TASKS #42: the Cascade Staff home shows who is on the stay. staff_home_v1 gains, on current_guest and
-- next_guest, a key `companions`: [{name, has_photo}] ordered by creation. No ID type, no photo path, no number, no contact.
-- Owner and admin sessions only: the same role test staff_guest_contact_v1 uses for the D-319 contact fields (staff_access_profiles
-- role owner or admin, not disabled). Any other role gets no `companions` key at all (absent, not empty).
--   staff_guest_companions_v1(uuid)   internal helper, owner only (no API role can call it); '{}' for a non-owner/admin session.
--   staff_home_v1(uuid)               LIVE body (md5(replace(prosrc, chr(13), '')) f03adb4cc7e6d68be0a717f626c67f63, read 2026-10-08,
--                                     = the 20261008120000_calendar_day_flags.sql body) plus exactly two counted insertions: the
--                                     `|| public.staff_guest_companions_v1(s.guest_id)` line after the contact line, in both
--                                     the current and the next guest select. Same signature, same grants.
-- Additive: old readers ignore the new key. Rollback: supabase/rollbacks/20261009_s79_guest_id.sql

begin;

do $$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.staff_home_v1(uuid)'::regprocedure)
       <> 'f03adb4cc7e6d68be0a717f626c67f63' then
    raise exception 'staff_home_v1 is not the body this release was cut from: re-cut it from the live body' using errcode = '55000';
  end if;
end $$;

create or replace function public.staff_guest_companions_v1(p_guest_id uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select case when p_guest_id is not null
               and exists (select 1 from public.staff_access_profiles p
                            where p.user_id = auth.uid() and p.role in ('owner','admin') and p.disabled_at is null)
    then jsonb_build_object('companions', coalesce((
           select jsonb_agg(jsonb_build_object('name', public.staff_redact_v1(c.name), 'has_photo', c.id_photo_path is not null)
                            order by c.created_at, c.id)
             from public.guest_companions c where c.guest_id = p_guest_id), '[]'::jsonb))
    else '{}'::jsonb end;
$$;
revoke all on function public.staff_guest_companions_v1(uuid) from public, anon, authenticated, service_role;

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
begin
  if not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select p.role into v_role from public.staff_access_profiles p where p.user_id = auth.uid();

  -- calendar: names and dates only; contact columns, the raw feed text and the reconciliation fields are never selected.
  select coalesce(jsonb_agg(jsonb_build_object(
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
                               else 'Blocked' end end) order by e.checkin_date, e.uid), '[]'::jsonb)
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
    into v_cur from public.staff_current_next_stays_v1(p_property_id) s where s.slot = 'current';
  select jsonb_build_object('uid', s.uid, 'guest_name', public.staff_redact_v1(s.guest_name), 'source', s.source,
           'checkin_date', s.checkin_date, 'checkout_date', s.checkout_date, 'nights', s.nights,
           'checkin_time', s.checkin_time, 'checkout_time', s.checkout_time)
         || public.staff_guest_card_v1(p_property_id, s.guest_id, s.checkin_date)
         || public.staff_guest_contact_v1(s.guest_id)
         || public.staff_guest_companions_v1(s.guest_id)
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
  'Cascade Staff home (SPEC-36, S77, D-319): calendar with block_reason/block_label, day_flags, current/next guest with returning marker and notes, open system-check warnings with key/acknowledged/facts, weather. Owner and admin sessions also get the current/next guest phone, e-mail and Messenger thread, and companions (name, has_photo); never money; cleaners and other roles never get contact details or companions (D-289).';

commit;
