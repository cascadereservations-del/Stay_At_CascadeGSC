-- RECOVERY-ONLY BRIDGE. Never apply to production; it is not part of supabase/migrations history.
--
-- Production received these six functions by hand from CH-Cleaners-Checklist/sql/ and they were never recorded
-- in supabase/migrations/. The disposable CI database (supabase/recovery/baseline.json) is built from a schema
-- snapshot plus the forward migrations, so it lacked them and 20260925030000_security_grants.sql failed with
-- "function public.get_cleanable_bookings(date, uuid, integer, integer) does not exist".
-- Definitions below are pg_get_functiondef output read read-only from production on 2026-11-24.
-- Production md5(prosrc) per function:
--   get_cleanable_bookings: NOT the current production body. It is the pre-s82 body (md5 7306b53090e34765717a5a65ea700219, copied from
--     supabase/rollbacks/20261015_s82_checklist.sql), because 20261015010000_s82_checklist.sql refuses to run unless the function
--     has exactly that body. Production had it from 2026-09-12 (hand-applied) until s82 replaced it on 2026-10-15.
--   can_skip_meter_photos: 03c8084770288bcd9d28ac478938bb3e
--   get_meter_photo_objects: bcab40f78d6158bd5612886b22f8d814
--   get_meter_sessions_pending_vision: d85edf8955e57a90da077d22e276c1a6
--   get_usage_medians: eb605dd66ebd70bb83061e2f38795132
--   get_checklist_staff_names: e77d9b3cda3e67fc088ab2a057b220eb
-- Grants are not set here, except get_checklist_staff_names: no migration grants it (anon by design, D-228), so it
-- reproduces the production ACL {postgres=X, anon=X, authenticated=X, service_role=X} at the end of this file.
-- The other five get their grants from 20260925030000_security_grants.sql.

set check_function_bodies = off;

create or replace function public.get_cleanable_bookings(
  p_date        date,
  p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid,
  p_lookback    integer default 10,
  p_midstay_min integer default 5
)
returns table (
  event_id         uuid,
  checkin_date     date,
  checkout_date    date,
  nights           integer,
  guest_name       text,
  kind             text,
  already_reported boolean
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception 'not authorized to read operations for this property'
      using errcode = '42501';
  end if;

  return query
  with candidate as (
    select
      ce.id,
      ce.checkin_date,
      ce.checkout_date,
      ce.nights,
      nullif(trim(coalesce(ce.guest_name, '')), '') as guest_name,
      case
        when ce.checkout_date <= p_date                               then 'checkout'
        when ce.checkin_date  <  p_date and ce.checkout_date > p_date  then 'mid_stay'
        else 'checkin'
      end as kind
    from public.calendar_events ce
    where ce.property_id = p_property_id
      and ce.status <> 'cancelled'
      and (
        -- ended on or shortly before the cleaning date
        (ce.checkout_date <= p_date and ce.checkout_date >= p_date - p_lookback)
        -- guest still in residence, stay long enough to earn a mid-stay clean
        or (ce.checkin_date < p_date and ce.checkout_date > p_date
            and coalesce(ce.nights, 0) >= p_midstay_min)
        -- arriving today
        or ce.checkin_date = p_date
      )
  )
  select
    c.id,
    c.checkin_date,
    c.checkout_date,
    c.nights,
    c.guest_name,
    c.kind,
    exists (
      select 1
      from public.cleaning_sessions cs
      where cs.property_id = p_property_id
        and case
              when c.kind = 'mid_stay' then
                coalesce(cs.cleaning_type, '') = 'mid_stay'
                and cs.checkout_date = c.checkout_date
                and cs.cleaned_at::date = p_date
              else
                coalesce(cs.cleaning_type, 'checkout') <> 'mid_stay'
                and cs.checkout_date = c.checkout_date
            end
    ) as already_reported
  from candidate c
  order by
    case c.kind when 'checkout' then 0 when 'mid_stay' then 1 else 2 end,
    c.checkout_date desc;
end;
$function$;

CREATE OR REPLACE FUNCTION public.can_skip_meter_photos(p_property_id uuid DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
 RETURNS TABLE(allowed boolean, last_skipped boolean, last_session_at timestamp with time zone, reason text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_last_skipped boolean;
  v_last_at      timestamptz;
begin
  if not public.current_staff_authorized('read_operations', p_property_id) then
    raise exception 'not authorized to read operations for this property'
      using errcode = '42501';
  end if;

  -- Only turnovers and deep cleans are held to this. A mid-stay refresh does
  -- not require meter readings at all, so skipping one proves nothing.
  select cs.meter_photos_skipped, cs.cleaned_at
    into v_last_skipped, v_last_at
  from public.cleaning_sessions cs
  where cs.property_id = p_property_id
    and cs.cleaning_type in ('turnover', 'deep_clean')
  order by cs.cleaned_at desc nulls last
  limit 1;

  return query
  select
    coalesce(v_last_skipped, false) = false,
    coalesce(v_last_skipped, false),
    v_last_at,
    case when coalesce(v_last_skipped, false)
         then 'the previous report also had no meter photos'
         else null end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_meter_photo_objects(p_submission_id text, p_cleaned_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_window_hours integer DEFAULT 12)
 RETURNS TABLE(object_name text, meter text, created_at timestamp with time zone, match_by text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with candidates as (
    select o.name,
           case when o.name ilike '%electric_meter%' then 'electric' else 'water' end as meter,
           o.created_at,
           -- proof beats inference
           case when p_submission_id is not null
                 and o.name like '%' || p_submission_id || '%'
                then 'submission_id' else 'upload_time' end as match_by
    from storage.objects o
    where o.bucket_id = 'cleaning-photos'
      and (o.name ilike '%electric_meter%' or o.name ilike '%water_meter%')
      and (
        (p_submission_id is not null and o.name like '%' || p_submission_id || '%')
        or (p_cleaned_at is not null
            and o.created_at <= p_cleaned_at
            and o.created_at >= p_cleaned_at - make_interval(hours => greatest(p_window_hours, 1)))
      )
  ),
  -- If the submission id matched anything at all, use only those.
  scoped as (
    select * from candidates
    where match_by = 'submission_id'
       or not exists (select 1 from candidates c2 where c2.match_by = 'submission_id')
  )
  select distinct on (meter) name, meter, created_at, match_by
  from scoped
  -- newest first within each meter: the closest upload before the submission
  order by meter, created_at desc;
$function$;

CREATE OR REPLACE FUNCTION public.get_meter_sessions_pending_vision(p_property_id uuid DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid, p_lookback integer DEFAULT 7, p_limit integer DEFAULT 20)
 RETURNS TABLE(session_id uuid, submission_id text, cleaned_at timestamp with time zone, cleaner_name text, electric_curr numeric, water_curr numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select cs.id, cs.submission_id, cs.cleaned_at, cs.cleaner_name,
         mr.electric_curr, mr.water_curr
  from public.cleaning_sessions cs
  join public.meter_readings mr on mr.session_id = cs.id
  where cs.property_id = p_property_id
    and cs.cleaned_at >= (now() - make_interval(days => greatest(p_lookback, 1)))
    and mr.vision_verdict is null
    and coalesce(cs.meter_photos_skipped, false) = false
    and coalesce(cs.meter_photo_count, 0) > 0
  order by cs.cleaned_at desc
  limit greatest(p_limit, 1);
$function$;

CREATE OR REPLACE FUNCTION public.get_usage_medians()
 RETURNS TABLE(item_id uuid, median_used numeric)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select item_id,
         percentile_cont(0.5) within group (order by used_qty)::numeric(10,2)
  from inventory_usage
  where session_date >= current_date - interval '90 days'
    and undone_at is null
  group by item_id;
$function$;

CREATE OR REPLACE FUNCTION public.get_checklist_staff_names()
 RETURNS TABLE(display_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select distinct u.raw_user_meta_data->>'display_name'
  from public.staff_access_profiles sap
  join auth.users u on u.id = sap.user_id
  where sap.role = 'cleaner'
    and sap.disabled_at is null
    and nullif(trim(coalesce(u.raw_user_meta_data->>'display_name', '')), '') is not null
  order by 1;
$function$;

revoke execute on function public.get_checklist_staff_names() from public;
grant execute on function public.get_checklist_staff_names() to anon, authenticated, service_role;
