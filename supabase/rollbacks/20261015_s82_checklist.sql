-- Rollback for release s82_checklist_20261015. Compensating, not a restore.
--   * puts get_cleanable_bookings and get_booking_for_date back to their pre-release bodies (md5 7306b530... and e1202ee7..., read from
--     production 2026-10-13); signatures, return columns and grants do not change, so nothing else needs touching;
--   * drops the predicate function k_calendar_row_offered once nothing calls it.
-- After the rollback the checklist's stay picker offers calendar blocks again (the old behaviour); the new checklist works against
-- either version of the functions. Safe until: any time. No data is written or deleted.
begin;

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

create or replace function public.get_booking_for_date(
  p_date        date,
  p_property_id uuid default null
)
returns table (
  event_id      uuid,
  checkin_date  date,
  checkout_date date,
  nights        integer,
  guest_name    text,
  source        text,
  status        text,
  match_type    text
)
language plpgsql
stable
set search_path to ''
as $function$
BEGIN
  -- Post-checkout clean: guest checked out today (priority match)
  RETURN QUERY
  SELECT
    ce.id,
    ce.checkin_date,
    ce.checkout_date,
    ce.nights,
    ce.guest_name,
    ce.source,
    ce.status,
    'checkout'::text
  FROM public.calendar_events ce
  WHERE ce.checkout_date = p_date
    AND ce.status != 'cancelled'
    AND (p_property_id IS NULL OR ce.property_id = p_property_id)
  ORDER BY ce.synced_at DESC
  LIMIT 1;

  -- If no checkout match, try checkin (pre-arrival clean)
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      ce.id,
      ce.checkin_date,
      ce.checkout_date,
      ce.nights,
      ce.guest_name,
      ce.source,
      ce.status,
      'checkin'::text
    FROM public.calendar_events ce
    WHERE ce.checkin_date = p_date
      AND ce.status != 'cancelled'
      AND (p_property_id IS NULL OR ce.property_id = p_property_id)
    ORDER BY ce.synced_at DESC
    LIMIT 1;
  END IF;
END;
$function$;

drop function if exists public.k_calendar_row_offered(uuid, text, text, text, date, date, date);

comment on function public.get_cleanable_bookings(date, uuid, integer, integer) is
  'Stays a cleaner may still file a report for on a given date. SECURITY DEFINER because calendar_events is owner/admin only; re-checks read_operations itself.';

commit;
