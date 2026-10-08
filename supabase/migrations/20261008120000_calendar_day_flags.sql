-- Session 77, lane L2 (SQL): release calendar_day_flags_20261008. The Cascade Staff calendar contract (s77-rules.md).
--   staff_home_v1(uuid)         LIVE body (md5(replace(prosrc, chr(13), '')) 7bfb1d05a9705d92cb063f2335a8c3c5, read 2026-10-08; the
--                               full pg_get_functiondef CR-stripped md5 58c1002541f968449c58e64af370292d) plus three additions and
--                               nothing else:
--                               calendar[].block_reason   direct | brownout | maintenance | owner | other | null (status blocked only;
--                                                         the stored owner_use is sent as owner, unblock as other)
--                               calendar[].block_label    'Direct booking BD296460' | 'Brownout' | 'Maintenance' | 'Owner use' | 'Blocked'
--                                                         The only part of block_note that leaves the function is the 8-character
--                                                         booking ref after 'DIR '.
--                               day_flags[]               {date, kind, label, source auto|manual, id uuid|null}: manual flags plus
--                                                         auto brownout (blocked rows with block_reason brownout, and each active
--                                                         brownout notice the warnings list already carries) and auto maintenance
--                                                         (blocked rows with block_reason maintenance), today-30 .. today+120,
--                                                         one row per (date, kind): manual > notice > calendar block.
--   warnings[].key              the verifier_findings.key of a system-check warning (null for the others), the key the Tasks list
--                               uses for source verifier_findings and ack_verifier_finding_v1(p_key) takes. detail is unchanged.
--   warnings[].acknowledged / .facts   system-check warnings now list OPEN findings only (an acknowledged one no longer shows);
--                               acknowledged is false on every row it is still sent on; facts is the allow-list of
--                               staff_verifier_facts_v1 (null for non-verifier warnings).
--   calendar_day_flags          manual secondary flags per night (brownout | maintenance | deep_clean | other), RLS on, no direct grant
--                               to any API role (service_role only), audited per row by admin_audit_row_v1.
--   calendar_day_flag_set_v1 / calendar_day_flag_clear_v1   owner or admin only (admin_require read_operations on the property, then
--                               the staff profile role must be owner or admin), security definer, search_path empty, anon has no
--                               execute. Set is idempotent per (property, date, kind): a second set updates the label. Clear stamps
--                               cleared_at and is idempotent on an already cleared flag.
-- Additive: one table, two functions, one function body replaced (same signature, same grants). Old readers ignore the new keys.
-- The 20261005 staff_home_v1 forward checks still hold: no money or contact column is named in the source.

begin;

create table if not exists public.calendar_day_flags (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references public.properties(id),
  date date not null,
  kind text not null check (kind in ('brownout','maintenance','deep_clean','other')),
  label text not null default '' check (char_length(label) <= 80),
  created_by uuid,
  created_at timestamptz not null default now(),
  cleared_at timestamptz
);
create unique index if not exists calendar_day_flags_active_uq on public.calendar_day_flags(property_id, date, kind) where cleared_at is null;
create index if not exists calendar_day_flags_window_idx on public.calendar_day_flags(property_id, date) where cleared_at is null;
alter table public.calendar_day_flags enable row level security;
revoke all on public.calendar_day_flags from public, anon, authenticated;
grant all on public.calendar_day_flags to service_role;
drop trigger if exists admin_audit_row on public.calendar_day_flags;
create trigger admin_audit_row after insert or update on public.calendar_day_flags for each row execute function public.admin_audit_row_v1();
comment on table public.calendar_day_flags is
  'S77: manual day flags on the Cascade Staff calendar. Read only through staff_home_v1 (day_flags); written only by calendar_day_flag_set_v1 / calendar_day_flag_clear_v1 (owner/admin).';

create or replace function public.calendar_day_flag_set_v1(p_property_id uuid, p_date date, p_kind text, p_label text)
returns jsonb language plpgsql volatile security definer set search_path to '' as $$
declare
  v_label text := btrim(coalesce(p_label, ''));
  v_id uuid;
begin
  perform public.admin_require('read_operations', p_property_id);
  if not exists (select 1 from public.staff_access_profiles p where p.user_id = auth.uid() and p.role in ('owner','admin')) then
    raise exception using errcode = '42501', message = 'owner or admin only';
  end if;
  if p_date is null then raise exception using errcode = '22023', message = 'a date is required'; end if;
  if p_kind is null or p_kind not in ('brownout','maintenance','deep_clean','other') then
    raise exception using errcode = '22023', message = 'kind must be brownout, maintenance, deep_clean or other';
  end if;
  if char_length(v_label) > 80 then raise exception using errcode = '22023', message = 'the label is at most 80 characters'; end if;
  perform public.admin_audit_context_v1('calendar day flag', null, null);
  insert into public.calendar_day_flags(property_id, date, kind, label, created_by)
  values (p_property_id, p_date, p_kind, v_label, auth.uid())
  on conflict (property_id, date, kind) where cleared_at is null do update set label = excluded.label
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.calendar_day_flag_clear_v1(p_property_id uuid, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path to '' as $$
declare v_cleared timestamptz;
begin
  perform public.admin_require('read_operations', p_property_id);
  if not exists (select 1 from public.staff_access_profiles p where p.user_id = auth.uid() and p.role in ('owner','admin')) then
    raise exception using errcode = '42501', message = 'owner or admin only';
  end if;
  select f.cleared_at into v_cleared from public.calendar_day_flags f where f.id = p_id and f.property_id = p_property_id;
  if not found then raise exception using errcode = 'P0002', message = 'flag not found'; end if;
  if v_cleared is null then
    perform public.admin_audit_context_v1('calendar day flag cleared', null, null);
    update public.calendar_day_flags set cleared_at = now() where id = p_id and property_id = p_property_id and cleared_at is null;
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.calendar_day_flag_set_v1(uuid, date, text, text) from public, anon, service_role;
revoke all on function public.calendar_day_flag_clear_v1(uuid, uuid) from public, anon, service_role;
grant execute on function public.calendar_day_flag_set_v1(uuid, date, text, text) to authenticated;
grant execute on function public.calendar_day_flag_clear_v1(uuid, uuid) to authenticated;

-- Safe facts of a system-check finding for staff: an allow-list read out of verifier_findings.detail. 8-character booking ref, guest FIRST
-- name only (redacted), ISO dates, block_from / block_to (V1m), the V10 check name and count n. Never a payee, a code, a phone, an
-- e-mail or an amount: V10 detail rows are not read at all.
create or replace function public.staff_verifier_facts_v1(p_check_id text, p_detail jsonb)
returns jsonb language sql immutable set search_path to '' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'ref',        upper(coalesce(substring(p_detail->>'booking' from '^[0-9a-fA-F]{8}'), substring(p_detail->>'stay' from '^[0-9a-fA-F]{8}'),
                                 substring(p_detail->>'uid' from '^cascade-direct-([0-9a-fA-F]{8})'))),
    'guest_first', nullif(public.staff_redact_v1(split_part(btrim(coalesce(p_detail->>'guest', p_detail#>>'{a,guest}', '')), ' ', 1)), ''),
    'from',       case when coalesce(p_detail->>'from', p_detail#>>'{a,from}', p_detail->>'arrives', p_detail->>'stay_from') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                       then coalesce(p_detail->>'from', p_detail#>>'{a,from}', p_detail->>'arrives', p_detail->>'stay_from') end,
    'to',         case when coalesce(p_detail->>'to', p_detail#>>'{a,to}', p_detail->>'stay_to') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                       then coalesce(p_detail->>'to', p_detail#>>'{a,to}', p_detail->>'stay_to') end,
    'block_from', case when p_detail->>'block_from' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then p_detail->>'block_from' end,
    'block_to',   case when p_detail->>'block_to' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then p_detail->>'block_to' end,
    'check',      case when p_check_id = 'V10' and p_detail->>'check' ~ '^[a-z_]{1,40}$' then p_detail->>'check' end,
    'n',          case when p_check_id = 'V10' and jsonb_typeof(p_detail->'n') = 'number' then p_detail->'n' end));
$$;
revoke all on function public.staff_verifier_facts_v1(text, jsonb) from public, anon, authenticated, service_role;

-- How to reach the guest, for an OWNER or ADMIN session only: any other caller gets '{}' (the keys are absent, not null, so a cleaner
-- payload never holds a contact shape). Phone as stored (normalised form first), e-mail, and the Messenger thread: the PSID is the
-- profile's messenger_psid, else the concierge thread whose booking_flow booking_id is one of this guest's inquiries; thread_url is the
-- link a person pasted into the guest profile (null when none; no inbox deep link is built anywhere in the code).
create or replace function public.staff_guest_contact_v1(p_guest_id uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select case when exists (select 1 from public.staff_access_profiles p
                            where p.user_id = auth.uid() and p.role in ('owner','admin') and p.disabled_at is null)
    then jsonb_build_object(
      'phone', (select coalesce(g.phone_e164, g.phone) from public.guests g where g.id = p_guest_id),
      'email', (select g.email from public.guests g where g.id = p_guest_id),
      'messenger', (select jsonb_build_object('psid', m.psid, 'thread_url', m.link)
                      from (select coalesce(nullif(btrim(d.messenger_psid), ''),
                                            (select t.psid from public.concierge_threads t
                                              where t.booking_flow->>'booking_id' in (select b.id::text from public.booking_inquiries b where b.guest_id = p_guest_id)
                                              order by t.updated_at desc limit 1)) as psid,
                                   case when btrim(d.messenger_link) ~ '^https://' then btrim(d.messenger_link) end as link
                              from (select 1) o left join public.guest_profile_details d on d.guest_id = p_guest_id) m
                     where m.psid is not null or m.link is not null))
    else '{}'::jsonb end;
$$;
revoke all on function public.staff_guest_contact_v1(uuid) from public, anon, authenticated, service_role;

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
    into v_cur from public.staff_current_next_stays_v1(p_property_id) s where s.slot = 'current';
  select jsonb_build_object('uid', s.uid, 'guest_name', public.staff_redact_v1(s.guest_name), 'source', s.source,
           'checkin_date', s.checkin_date, 'checkout_date', s.checkout_date, 'nights', s.nights,
           'checkin_time', s.checkin_time, 'checkout_time', s.checkout_time)
         || public.staff_guest_card_v1(p_property_id, s.guest_id, s.checkin_date)
         || public.staff_guest_contact_v1(s.guest_id)
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
  'Cascade Staff home (SPEC-36, S77, D-319): calendar with block_reason/block_label, day_flags, current/next guest with returning marker and notes, open system-check warnings with key/acknowledged/facts, weather. Owner and admin sessions also get the current/next guest phone, e-mail and Messenger thread; never money; cleaners and other roles never get contact details (D-289).';

commit;
