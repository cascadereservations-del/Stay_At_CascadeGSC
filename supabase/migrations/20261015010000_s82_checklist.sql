-- Session 82 (lane K, part 1): release s82_checklist_20261015.
-- The cleaning checklist offered calendar BLOCKS (status = 'blocked', no guest) as if they were stays, with a 10-day look-back:
-- "Blocked / maintenance window" rows from earlier weeks kept showing up and reached the cleaning report. Owner: blocked dates are
-- included in the cleaning report only when they are scheduled for cleaning or maintenance.
--
-- How the table marks a block (read from calendar-sync blocks.ts / ical.ts and the 20260528 table): calendar_events.status = 'blocked'
-- (CHECK confirmed | blocked | cancelled). It is NOT "guest_name is null": an Airbnb stay can lack a name for a day, and a pending direct
-- hold is also status 'blocked' but carries a name. block_reason (brownout | maintenance | owner_use | direct | other | unblock) and
-- block_reason_source (auto | assumed | staff) say why. calendar-sync saves every unexplained Airbnb block as maintenance / assumed, so that
-- pair does NOT mean scheduled; only a staff answer does. Scheduled work is also recorded as a live calendar_day_flags row
-- (kind maintenance | deep_clean, cleared_at is null).
--
-- ONE predicate, public.k_calendar_row_offered, used by both functions:
--   * a row that is not a block is offered exactly as before (guest stays unchanged, look-back unchanged);
--   * a block is offered only for a cleaning date it covers (checkin_date <= date < checkout_date; no look-back for blocks) AND
--     (block_reason = 'maintenance' and block_reason_source = 'staff', or a live maintenance / deep_clean day flag on that date).
-- get_cleanable_bookings and get_booking_for_date keep their signatures, return columns, security mode and grants. The only visible change:
-- an offered block comes back from get_cleanable_bookings with kind = 'block' (a stay is still checkout | mid_stay | checkin). An old
-- client that does not know 'block' hides it, which is the safe direction.
begin;

do $stop$
begin
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_cleanable_bookings(date,uuid,integer,integer)'::regprocedure) <> '7306b53090e34765717a5a65ea700219' then
    raise exception 'STOP: public.get_cleanable_bookings changed in production since s82 lane K was written (md5 7306b53090e34765717a5a65ea700219); re-read production and re-vendor before applying';
  end if;
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.get_booking_for_date(date,uuid)'::regprocedure) <> 'e1202ee78fb0431f02af97e41fba4ffd' then
    raise exception 'STOP: public.get_booking_for_date changed in production since s82 lane K was written (md5 e1202ee78fb0431f02af97e41fba4ffd); re-read production and re-vendor before applying';
  end if;
end;
$stop$;

-- The one predicate. SECURITY DEFINER only to read calendar_day_flags (no grant to authenticated); the flag branch re-checks
-- read_operations itself, so anon, who may execute it, can never learn that a flag exists.
create or replace function public.k_calendar_row_offered(
  p_property_id         uuid,
  p_status              text,
  p_block_reason        text,
  p_block_reason_source text,
  p_checkin             date,
  p_checkout            date,
  p_date                date
)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select case
    when p_status is distinct from 'blocked' then true
    when not (p_checkin <= p_date and p_date < p_checkout) then false
    when p_block_reason = 'maintenance' and p_block_reason_source = 'staff' then true
    else public.current_staff_authorized('read_operations', p_property_id)
         and exists (
           select 1 from public.calendar_day_flags f
            where f.property_id = p_property_id
              and f.date = p_date
              and f.kind in ('maintenance', 'deep_clean')
              and f.cleared_at is null)
  end;
$function$;

revoke all on function public.k_calendar_row_offered(uuid, text, text, text, date, date, date) from public;
grant execute on function public.k_calendar_row_offered(uuid, text, text, text, date, date, date) to anon, authenticated, service_role;
comment on function public.k_calendar_row_offered(uuid, text, text, text, date, date, date) is
  's82 K: is this calendar_events row something a cleaner may report on for p_date? Stays always; a block only when it covers p_date and was scheduled (staff-answered maintenance, or a live maintenance / deep_clean day flag).';

-- get_cleanable_bookings: the s81-era body (md5 7306b530...) with the block predicate in the candidate filter, the kind and already_reported.
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
        when ce.status = 'blocked'                                     then 'block'
        when ce.checkout_date <= p_date                               then 'checkout'
        when ce.checkin_date  <  p_date and ce.checkout_date > p_date  then 'mid_stay'
        else 'checkin'
      end as kind
    from public.calendar_events ce
    where ce.property_id = p_property_id
      and ce.status <> 'cancelled'
      and (
        -- a block: only the cleaning date itself, and only when it was scheduled
        (ce.status = 'blocked'
         and public.k_calendar_row_offered(ce.property_id, ce.status, ce.block_reason, ce.block_reason_source,
                                           ce.checkin_date, ce.checkout_date, p_date))
        or (ce.status <> 'blocked' and (
          -- ended on or shortly before the cleaning date
          (ce.checkout_date <= p_date and ce.checkout_date >= p_date - p_lookback)
          -- guest still in residence, stay long enough to earn a mid-stay clean
          or (ce.checkin_date < p_date and ce.checkout_date > p_date
              and coalesce(ce.nights, 0) >= p_midstay_min)
          -- arriving today
          or ce.checkin_date = p_date
        ))
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
              when c.kind = 'block' then
                cs.checkout_date = c.checkout_date
                and cs.cleaned_at::date = p_date
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

-- get_booking_for_date: body equal to production (md5 e1202ee7...) plus the same predicate on both queries. SECURITY INVOKER as before.
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
    AND public.k_calendar_row_offered(ce.property_id, ce.status, ce.block_reason, ce.block_reason_source, ce.checkin_date, ce.checkout_date, p_date)
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
      AND public.k_calendar_row_offered(ce.property_id, ce.status, ce.block_reason, ce.block_reason_source, ce.checkin_date, ce.checkout_date, p_date)
    ORDER BY ce.synced_at DESC
    LIMIT 1;
  END IF;
END;
$function$;

-- create or replace keeps the existing grants; stated again so a --no-acl rehearsal carries them.
revoke all on function public.get_cleanable_bookings(date, uuid, integer, integer) from public;
grant execute on function public.get_cleanable_bookings(date, uuid, integer, integer) to authenticated, service_role;
grant execute on function public.get_booking_for_date(date, uuid) to anon, authenticated, service_role;

comment on function public.get_cleanable_bookings(date, uuid, integer, integer) is
  'Stays a cleaner may still file a report for on a given date, plus a calendar block only on a date it covers and was scheduled for (kind block). SECURITY DEFINER because the date rule needs day flags; re-checks read_operations itself.';

commit;
