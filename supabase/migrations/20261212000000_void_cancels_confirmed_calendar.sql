-- A voided direct-booking income row cancels the booking (Lloyd 2026-11-28: keep that). The void leg only cancelled the
-- calendar row 'direct:<id>'; a confirmed booking's row is renamed to 'cascade-direct-<id>' (20261008100000), so it stayed
-- confirmed and kept blocking the dates. Same two uids as record_booking_lifecycle_action (20260905030000).
-- Only that where-clause changes. The DIRECT: reservation row, the trigger and the income-confirm guard are untouched.
-- No data change. No begin/commit (the runner wraps it).
-- Rollback: supabase/rollbacks/20261212_void_cancels_confirmed_calendar.sql

do $guard$
declare v text;
begin
  select md5(replace(prosrc, chr(13), '')) into v from pg_proc where oid = to_regprocedure('public.fn_direct_booking_cascade()');
  if v is null or v not in ('e08fe137097dbb2ac4f40eafbbcbd57d', '6df13b3b647844b6b7d76d5d12835393') then
    raise exception using errcode = '55000', message = '20261212000000_void_cancels_confirmed_calendar.sql: fn_direct_booking_cascade is not a known body (md5 ' || coalesce(v, 'missing') || '); nothing changed';
  end if;
end $guard$;

create or replace function public.fn_direct_booking_cascade()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.booking_id is null then return new; end if;

  -- SPEC-44: confirming happens only in decide_direct_booking (which flips the income row itself), so a confirmed row is a no-op.
  if new.status = 'void' and old.status is distinct from 'void' then
    update public.booking_inquiries
       set status = 'cancelled'
     where id = new.booking_id and status <> 'cancelled';
    update public.calendar_events
       set status = 'cancelled'
     where uid in ('direct:' || new.booking_id::text, 'cascade-direct-' || new.booking_id::text) and status <> 'cancelled';
  end if;

  return new;
exception when others then
  -- never block the ledger update because of a cascade hiccup
  raise warning 'fn_direct_booking_cascade error: %', sqlerrm;
  return new;
end $$;
revoke all on function public.fn_direct_booking_cascade() from public, anon, authenticated, service_role;
