-- 2026-09-28 (session 58): clean up 2026-09-28-s58-synthetic-door-mid.sql. Prints the proof rows first, then:
--   both bookings -> cancelled (the cancel queues booking.cancelled outbox rows: retired below as NO_CONSUMER_D070),
--   their guest_message_log rows deleted, the synthetic guest and its profile deleted. Guarded: only these ids.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site, about a minute after the synthetic, before :35.
select booking_id, message_key, channel, status, detail, created_at from public.guest_message_log
 where booking_id in ('e5800000-0000-4000-8000-0000000000a0', 'e5800000-0000-4000-8000-0000000000b0') order by booking_id, created_at;
begin;
do $$
declare
  a uuid := 'e5800000-0000-4000-8000-0000000000a0';
  b uuid := 'e5800000-0000-4000-8000-0000000000b0';
  g uuid := 'e5800000-0000-4000-8000-0000000000c0';
  n integer;
begin
  update public.booking_inquiries set status = 'cancelled', guest_id = null,
         notes = coalesce(notes || E'\n', '') || '[test] session 58 synthetic, cancelled by cleanup'
   where id in (a, b) and guest_email = 'cascadereservations+ben@gmail.com' and status <> 'cancelled';
  get diagnostics n = row_count; if n <> 2 then raise exception 'synthetic bookings not matched (%); nothing changed', n; end if;
  if exists (select 1 from public.transactions where booking_id in (a, b))
     or exists (select 1 from public.calendar_events where uid in ('direct:' || a::text, 'direct:' || b::text)) then
    raise exception 'a transaction or calendar row references a synthetic booking; nothing changed';
  end if;
  delete from public.guest_message_log where booking_id in (a, b);
  get diagnostics n = row_count; raise notice 'guest_message_log rows deleted: %', n;
  update public.automation_outbox set status = 'dead_letter', last_error_code = 'NO_CONSUMER_D070', completed_at = now()
   where aggregate_id in (a, b) and status = 'pending';
  get diagnostics n = row_count; raise notice 'outbox rows retired: %', n;
  delete from public.guests where id = g; -- guest_profile_details cascades
  get diagnostics n = row_count; if n <> 1 then raise exception 'synthetic guest not matched (%); nothing changed', n; end if;
end $$;
commit;
-- Forward checks (all true):
-- select count(*) = 2 from public.booking_inquiries where id in ('e5800000-0000-4000-8000-0000000000a0','e5800000-0000-4000-8000-0000000000b0') and status = 'cancelled';
-- select count(*) = 0 from public.guest_message_log where booking_id in ('e5800000-0000-4000-8000-0000000000a0','e5800000-0000-4000-8000-0000000000b0');
-- select count(*) = 0 from public.guests where id = 'e5800000-0000-4000-8000-0000000000c0';
