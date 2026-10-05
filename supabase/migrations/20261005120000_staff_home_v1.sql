-- Session 70, lane L3: release staff_home_v1_20261005. SPEC-36 (Cascade Staff PWA home, guest calendar info) extended by D-299.7 and D-299.9.
--   staff_home_v1(uuid)  ONE role-gated read for the Cascade Staff app: the calendar (names and dates only), the current and next
--                        guest with a returning-guest marker, stay count, earlier stays, notes from earlier stays and the path of the
--                        guest's ID photo, the warnings (brownout, verifier, low stock) and the weather. NEVER money, phone or e-mail
--                        (D-289): every key is an allow-list entry, and the pgTAP suite pins that the payload has none of them.
--   storage policy       "guest id photos staff current read": a staff session may read ONLY the primary ID photo of the guest who is
--                        in the house or arrives next, so the app can sign a short-lived URL for it with the user's own JWT. The
--                        existing manage_operations policies are untouched; cleaners have read_operations only.
--   internal helpers     staff_stay_guest_id_v1, staff_current_next_stays_v1, staff_primary_id_path_v1, staff_hide_money_v1,
--                        staff_guest_card_v1, staff_may_see_guest_id_v1, staff_redact_v1: security definer or immutable, no grant to anon
--                        or authenticated.
--                        staff_can_view_guest_id_object_v1 is the one helper the storage policy calls, so authenticated may execute it.
-- Where "notes from previous stays" live (read-only SQL on production 2026-10-05): guest_profile_details.stay_preferences, one text
-- column "YYYY-MM-DD: point | point || YYYY-MM-DD: point" (the dashboard's ImportantNotes card parses it), plus guest_profile_details.vip_reason
-- and guests.notes (1 row). The ID photo lives in guest_companions.id_photo_path, "<companion id>/<uuid>.jpg|png" in the private
-- guest-id-photos bucket; the guest's own row is the companion whose name equals the guest's name (D-129).
-- Guest -> stay link (40 of 41 confirmed stays since May resolve): calendar_events.linked_reservation_id -> airbnb_reservations.guest_id;
-- else the direct booking behind uid 'direct:<inquiry id>' (or 'cascade-direct-<id>'); else the one non-cancelled Airbnb reservation with
-- the same check-in and check-out dates (two or more matches = unknown, never a guess).
-- Stay count is counted from the stays themselves, not guests.total_stays: earlier stays = distinct (check-in, check-out) of this guest's
-- non-cancelled Airbnb reservations and confirmed direct bookings that ended on or before this stay's check-in; stay_count = earlier + 1;
-- returning = earlier >= 1. Unknown guest = null, never 0.
-- Notes are free text a person typed; amounts, phone numbers and e-mail addresses in them are best-effort replaced by [hidden]
-- (staff_redact_v1: contact shapes, then staff_hide_money_v1) BEFORE they leave the function, and the same redaction runs on every other
-- free-text field sent to staff (guest names, warning titles). Production holds a guest whose stay_preferences has a 09-mobile number
-- (D-289 audit, 2026-10-05). Staff never see money or contact details.
-- verifier_findings has no property_id; OPS_CHECKS below mirrors waves system-verifier/cards.ts (today {'V6'}): change both together.

begin;

create or replace function public.staff_hide_money_v1(p text)
returns text language sql immutable set search_path to '' as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(p, '(₱|€|£|\$|\m(php|usd|eur)\.?)\s*[0-9][0-9,]*(\.[0-9]+)?', '[hidden]', 'gi'),
               '[0-9][0-9,]*(\.[0-9]+)?\s*k?\s*(₱|€|\$|php|usd|eur|pesos?|pisos?|dollars?)', '[hidden]', 'gi'),
             '[0-9][0-9,]*(\.[0-9]+)?\s*k\M', '[hidden]', 'gi'),                     -- 1.5k, 2k
           '\m(P\s*|p)[0-9]+(,[0-9]{3})*(\.[0-9]+)?', '[hidden]', 'g');             -- PH shorthand: P500, P 1,000, P1,000.00, p500
$$;

-- Free text sent to staff. Order: full-width digits and signs to ASCII; e-mail shapes; then ANY run of 7 or more digits joined by spaces,
-- brackets, dots, slashes, underscores, plus or minus signs (every phone layout: (0917) 123 4567, +63 917 123 4567, 0917/123/4567,
-- 083-552-1234, +1 (415) 555-0100, spaced-out digits) with its leading + or (; then money (staff_hide_money_v1). ISO dates YYYY-MM-DD are
-- fenced out of the digit run by the lookarounds (not preceded by a digit or by the start of a date, not starting a date); a colon is not a
-- joiner, so a time like 14:00 or 14:00-15:00 stays. Over-redaction is fine, a leak is not.
create or replace function public.staff_redact_v1(p text)
returns text language sql immutable set search_path to '' as $$
  select public.staff_hide_money_v1(
           regexp_replace(
             regexp_replace(
               translate(p, '０１２３４５６７８９＋（）－．／', '0123456789+()-./'),
               '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}', '[hidden]', 'g'),
             '[+(]*(?<![0-9])(?<![0-9]{4}-)(?<![0-9]{4}-[0-9]{2}-)(?![0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9]))[0-9]([[:space:]().\/_+-]*[0-9]){6,}',
             '[hidden]', 'g'));
$$;

-- Roles that may see a guest's ID photo (D-299.9): everyone with read_operations except maintenance.
create or replace function public.staff_may_see_guest_id_v1(p_property_id uuid)
returns boolean language sql stable security definer set search_path to '' as $$
  select public.current_staff_authorized('read_operations', p_property_id)
     and exists (select 1 from public.staff_access_profiles p
                  where p.user_id = auth.uid() and p.role in ('owner','admin','finance','cleaner','inspector'));
$$;

create or replace function public.staff_stay_guest_id_v1(p_property_id uuid, p_uid text, p_linked uuid, p_checkin date, p_checkout date)
returns uuid language sql stable security definer set search_path to '' as $$
  select coalesce(
    (select a.guest_id from public.airbnb_reservations a where a.id = p_linked),
    (select b.guest_id from public.booking_inquiries b
      where b.guest_id is not null and p_uid in ('direct:' || b.id::text, 'cascade-direct-' || b.id::text) limit 1),
    (select case when count(*) = 1 then (array_agg(a.guest_id))[1] end
       from public.airbnb_reservations a
      where a.property_id = p_property_id and a.checkin_date = p_checkin and a.checkout_date = p_checkout
        and a.status <> 'cancelled'));
$$;

-- The stay in the house (check-in on or before today, check-out after today) and the next arrival, Manila date.
create or replace function public.staff_current_next_stays_v1(p_property_id uuid)
returns table (slot text, uid text, guest_name text, source text, checkin_date date, checkout_date date, nights integer,
               checkin_time time, checkout_time time, guest_id uuid)
language sql stable security definer set search_path to '' as $$
  with t as (select (now() at time zone 'Asia/Manila')::date d),
  cur as (
    select e.* from public.calendar_events e, t
     where e.property_id = p_property_id and e.status = 'confirmed' and e.checkin_date <= t.d and e.checkout_date > t.d
     order by e.checkin_date desc, e.uid limit 1),
  nxt as (
    select e.* from public.calendar_events e, t
     where e.property_id = p_property_id and e.status = 'confirmed' and e.checkin_date > t.d
     order by e.checkin_date, e.uid limit 1)
  select 'current', c.uid, c.guest_name, c.source, c.checkin_date, c.checkout_date, c.nights, c.checkin_time, c.checkout_time,
         public.staff_stay_guest_id_v1(p_property_id, c.uid, c.linked_reservation_id, c.checkin_date, c.checkout_date)
    from cur c
  union all
  select 'next', n.uid, n.guest_name, n.source, n.checkin_date, n.checkout_date, n.nights, n.checkin_time, n.checkout_time,
         public.staff_stay_guest_id_v1(p_property_id, n.uid, n.linked_reservation_id, n.checkin_date, n.checkout_date)
    from nxt n;
$$;

-- The guest's own ID photo: the companion row named like the guest, else the oldest companion with a photo.
create or replace function public.staff_primary_id_path_v1(p_guest_id uuid)
returns text language sql stable security definer set search_path to '' as $$
  select c.id_photo_path
    from public.guest_companions c join public.guests g on g.id = c.guest_id
   where c.guest_id = p_guest_id and c.id_photo_path is not null
   order by (lower(btrim(c.name)) = lower(btrim(g.name))) desc, c.created_at, c.id
   limit 1;
$$;

create or replace function public.staff_guest_card_v1(p_property_id uuid, p_guest_id uuid, p_checkin date)
returns jsonb language sql stable security definer set search_path to '' as $$
  with earlier as (
    select distinct s.checkin_date, s.checkout_date, s.nights from (
      select a.checkin_date, a.checkout_date, coalesce(a.nights, a.checkout_date - a.checkin_date) nights from public.airbnb_reservations a
       where a.guest_id = p_guest_id and a.status <> 'cancelled'
      union all
      select b.checkin_date, b.checkout_date, coalesce(b.nights, b.checkout_date - b.checkin_date) nights from public.booking_inquiries b
       where b.guest_id = p_guest_id and b.status = 'confirmed') s
     where s.checkout_date <= p_checkin and s.checkin_date < p_checkin),
  last3 as (select * from earlier order by checkout_date desc limit 3)
  select jsonb_build_object(
    'repeat',        case when p_guest_id is null then null else (select count(*) from earlier) >= 1 end,
    'stay_count',    case when p_guest_id is null then null else (select count(*) from earlier) + 1 end,
    'earlier_stays', case when p_guest_id is null then null
                          else coalesce((select jsonb_agg(jsonb_build_object('month', to_char(l.checkout_date, 'YYYY-MM'), 'nights', l.nights)
                                                          order by l.checkout_date desc) from last3 l), '[]'::jsonb) end,
    'notes',         public.staff_redact_v1(nullif(btrim(concat_ws(' || ',
                        nullif(btrim(d.stay_preferences), ''),
                        case when nullif(btrim(d.vip_reason), '') is not null then 'VIP - ' || btrim(d.vip_reason) end,
                        nullif(btrim(g.notes), ''))), '')),
    'id_photo_path', case when p_guest_id is not null and public.staff_may_see_guest_id_v1(p_property_id)
                          then public.staff_primary_id_path_v1(p_guest_id) end)
  from (select 1) o
  left join public.guests g on g.id = p_guest_id and g.property_id = p_property_id
  left join public.guest_profile_details d on d.guest_id = g.id;
$$;

-- The one helper the storage policy calls (policies run as the caller, so authenticated needs execute on it).
create or replace function public.staff_can_view_guest_id_object_v1(p_name text)
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (
    select 1 from public.guest_companions c
     where c.id_photo_path = p_name
       and public.staff_may_see_guest_id_v1(c.property_id)
       and public.staff_primary_id_path_v1(c.guest_id) = p_name
       and exists (select 1 from public.staff_current_next_stays_v1(c.property_id) s where s.guest_id = c.guest_id));
$$;

create or replace function public.staff_home_v1(p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
returns jsonb
language plpgsql stable security definer
set search_path to ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_role  text;
  v_ops_checks text[] := array['V6'];
  v_cal jsonb; v_cur jsonb; v_next jsonb; v_warn jsonb; v_weather jsonb;
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
           'checkin_time', e.checkin_time, 'checkout_time', e.checkout_time) order by e.checkin_date, e.uid), '[]'::jsonb)
    into v_cal
  from public.calendar_events e
  where e.property_id = p_property_id and e.status in ('confirmed','blocked')
    and e.checkout_date >= v_today - 7 and e.checkin_date <= v_today + 60;

  -- current and next guest: the calendar fields plus the guest card (D-299.7, D-299.9).
  select jsonb_build_object('uid', s.uid, 'guest_name', public.staff_redact_v1(s.guest_name), 'source', s.source,
           'checkin_date', s.checkin_date, 'checkout_date', s.checkout_date, 'nights', s.nights,
           'checkin_time', s.checkin_time, 'checkout_time', s.checkout_time)
         || public.staff_guest_card_v1(p_property_id, s.guest_id, s.checkin_date)
    into v_cur from public.staff_current_next_stays_v1(p_property_id) s where s.slot = 'current';
  select jsonb_build_object('uid', s.uid, 'guest_name', public.staff_redact_v1(s.guest_name), 'source', s.source,
           'checkin_date', s.checkin_date, 'checkout_date', s.checkout_date, 'nights', s.nights,
           'checkin_time', s.checkin_time, 'checkout_time', s.checkout_time)
         || public.staff_guest_card_v1(p_property_id, s.guest_id, s.checkin_date)
    into v_next from public.staff_current_next_stays_v1(p_property_id) s where s.slot = 'next';

  with w as (
    select 'brownout' kind, 'alert' severity, public.staff_redact_v1(n.title) title,
           jsonb_build_object('date', n.effective_date, 'time', n.effective_time, 'hours', n.duration_hours,
                              'grid_line', public.staff_redact_v1(n.feeder), 'posted_by', public.staff_redact_v1(n.posted_by_name)) detail,
           n.effective_date::timestamptz at_ts
      from public.ops_notices n
     where n.property_id = p_property_id and n.is_active and n.notice_type = 'brownout'
       and coalesce(n.audience,'staff') in ('staff','all')
       and (n.expires_at is null or n.expires_at > now()) and n.effective_date >= v_today - 1
    union all
    select 'verifier', case f.severity when 'red' then 'alert' else 'warn' end, public.staff_redact_v1(f.title) title,
           jsonb_build_object('check_id', f.check_id, 'status', f.status), f.last_seen
      from public.verifier_findings f
     where f.status in ('open','acknowledged')
       and (v_role in ('owner','admin','finance') or f.check_id = any(v_ops_checks))
    union all
    select 'inventory', 'warn', public.staff_redact_v1('Low stock: ' || i.name) title,
           jsonb_build_object('qty', i.qty_on_hand, 'unit', i.unit, 'reorder_below', i.reorder_below), i.updated_at
      from public.inventory_items i
     where i.property_id = p_property_id and i.is_active and i.qty_on_hand < i.reorder_below
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'severity', severity, 'title', title,
                                               'detail', detail, 'at', at_ts)
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
    'calendar', v_cal, 'current_guest', v_cur, 'next_guest', v_next,
    'warnings', v_warn, 'weather', v_weather, 'generated_at', now());
end $$;

-- Grants: the helpers are internal; only the RPC and the storage helper reach authenticated.
revoke all on function public.staff_hide_money_v1(text) from public, anon, authenticated;
revoke all on function public.staff_redact_v1(text) from public, anon, authenticated;
revoke all on function public.staff_may_see_guest_id_v1(uuid) from public, anon, authenticated;
revoke all on function public.staff_stay_guest_id_v1(uuid, text, uuid, date, date) from public, anon, authenticated;
revoke all on function public.staff_current_next_stays_v1(uuid) from public, anon, authenticated;
revoke all on function public.staff_primary_id_path_v1(uuid) from public, anon, authenticated;
revoke all on function public.staff_guest_card_v1(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.staff_can_view_guest_id_object_v1(text) from public, anon;
grant execute on function public.staff_can_view_guest_id_object_v1(text) to authenticated;
revoke all on function public.staff_home_v1(uuid) from public, anon;
grant execute on function public.staff_home_v1(uuid) to authenticated, service_role;

comment on function public.staff_home_v1(uuid) is
  'SPEC-36 Cascade Staff home: calendar names+dates, current/next guest with returning marker, notes and ID photo path (D-299.7/.9), warnings, weather. Never money, phone or e-mail (D-289).';
comment on function public.staff_can_view_guest_id_object_v1(text) is
  'Storage policy helper: true only for the primary ID photo of the guest in the house or arriving next, for a staff role that may see it.';

-- A staff session may read the primary ID photo of the current or next guest only (the app signs a 5-minute URL with its own JWT).
drop policy if exists "guest id photos staff current read" on storage.objects;
create policy "guest id photos staff current read" on storage.objects for select to authenticated
  using (bucket_id = 'guest-id-photos' and public.staff_can_view_guest_id_object_v1(name));

commit;
