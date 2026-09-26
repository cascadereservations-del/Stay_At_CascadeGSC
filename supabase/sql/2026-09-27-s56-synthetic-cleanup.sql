-- 2026-09-27 (session 56): clean up the session 56 synthetic booking (2026-09-27-s56-synthetic-3-6.sql, "Synthetic S56
-- Checkout", e5600000-...-0000000000c0). Run AFTER the 16:05 Manila guest-messages run, once the agent has read its log rows.
--   booking -> cancelled (the cancel queues a booking.cancelled outbox row: retired below as NO_CONSUMER_D070),
--   its guest_message_log rows deleted. No calendar_events, transactions or holds were ever created for it.
-- Guarded: only this id with the test alias; anything unexpected rolls everything back.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site.
begin;
do $$
declare
  bid uuid := 'e5600000-0000-4000-8000-0000000000c0';
  n integer;
begin
  update public.booking_inquiries set status = 'cancelled', notes = coalesce(notes || E'\n', '') || '[system] session 56 synthetic test, cancelled by cleanup'
   where id = bid and guest_email = 'cascadereservations+ben@gmail.com' and status <> 'cancelled';
  get diagnostics n = row_count; if n <> 1 then raise exception 'synthetic booking not matched (%); nothing changed', n; end if;
  if exists (select 1 from public.transactions where booking_id = bid) or exists (select 1 from public.calendar_events where uid = 'direct:' || bid::text) then
    raise exception 'a transaction or calendar row references the synthetic booking; nothing changed';
  end if;

  delete from public.guest_message_log where booking_id = bid;
  get diagnostics n = row_count; raise notice 'guest_message_log rows deleted: %', n;

  update public.automation_outbox set status = 'dead_letter', last_error_code = 'NO_CONSUMER_D070', completed_at = now()
   where aggregate_id = bid and status = 'pending';
  get diagnostics n = row_count; raise notice 'outbox rows retired: %', n;
end $$;
commit;
-- Forward checks (all true):
-- select status = 'cancelled' from public.booking_inquiries where id = 'e5600000-0000-4000-8000-0000000000c0';
-- select count(*) = 0 from public.guest_message_log where booking_id = 'e5600000-0000-4000-8000-0000000000c0';
-- select count(*) = 0 from public.automation_outbox where status = 'pending' and aggregate_id = 'e5600000-0000-4000-8000-0000000000c0';
