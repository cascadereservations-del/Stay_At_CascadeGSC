-- 2026-09-26 (session 54): clean up the SPEC-05 / SPEC-33 synthetic end-to-end test (Ben Munez, cascadereservations+ben@gmail.com).
-- Run AFTER the 15:05 Manila guest-messages run has sent message 2 for 09A53800 (read its guest_message_log row first).
--   09A53800 (confirmed on Messenger 02:16Z): booking -> cancelled, its calendar row and DIRECT: reservation -> cancelled,
--            its CONFIRMED income transaction (PHP 3,382) -> void, its guest_message_log rows deleted.
--   899604A0 (declined 02:14Z): already cancelled, calendar cancelled, transaction void - only its outbox rows remain.
--   Both: pending automation_outbox rows -> dead_letter (NO_CONSUMER_D070), as the SPEC-30 cleanup did.
--   Ben's test thread: booking_flow cleared so no later turn reads a cancelled test booking.
-- No acct_journals row references either booking (checked 2026-09-26). Payment reviews and decisions stay as audit history.
-- Guarded: every statement matches only these ids; unexpected counts roll everything back.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site.
begin;
do $$
declare n integer;
begin
  if not exists (select 1 from public.booking_inquiries where id = '09a53800-99c1-4aa4-97ea-d6937ac1a113' and guest_email = 'cascadereservations+ben@gmail.com') then
    raise exception 'synthetic booking 09A53800 not found with the synthetic e-mail; nothing changed';
  end if;

  update public.booking_inquiries set status = 'cancelled', notes = coalesce(notes || E'\n', '') || '[system] session 54 synthetic test, cancelled by cleanup'
   where id = '09a53800-99c1-4aa4-97ea-d6937ac1a113' and status <> 'cancelled';
  update public.calendar_events set status = 'cancelled', updated_at = now()
   where uid in ('cascade-direct-09a53800-99c1-4aa4-97ea-d6937ac1a113', 'direct:09a53800-99c1-4aa4-97ea-d6937ac1a113') and status <> 'cancelled';
  update public.airbnb_reservations set status = 'cancelled' where confirmation_code = 'DIRECT:09a53800-99c1-4aa4-97ea-d6937ac1a113';

  update public.transactions set status = 'void', updated_at = now()
   where id = '68ffda92-665a-40b1-af69-3ad023ce1b06' and booking_id = '09a53800-99c1-4aa4-97ea-d6937ac1a113' and status = 'confirmed';
  get diagnostics n = row_count; if n <> 1 then raise exception 'expected 1 confirmed test transaction, matched %; nothing changed', n; end if;

  delete from public.guest_message_log where booking_id = '09a53800-99c1-4aa4-97ea-d6937ac1a113';
  get diagnostics n = row_count; raise notice 'deleted % guest_message_log rows', n;

  update public.automation_outbox set status = 'dead_letter', last_error_code = 'NO_CONSUMER_D070', completed_at = now()
   where aggregate_id in ('09a53800-99c1-4aa4-97ea-d6937ac1a113', '899604a0-e240-4fa6-aaf5-d2318bc4db7d') and status = 'pending';
  get diagnostics n = row_count;
  if n not between 6 and 7 then raise exception 'expected 6 or 7 pending test outbox rows, matched %; nothing changed', n; end if;
  raise notice 'retired % test outbox rows', n;

  update public.concierge_threads set booking_flow = null, updated_at = now()
   where psid = '24786231807734398' and booking_flow->>'booking_id' in ('09a53800-99c1-4aa4-97ea-d6937ac1a113', '899604a0-e240-4fa6-aaf5-d2318bc4db7d');
end $$;
commit;
-- Forward checks (all true):
-- select status = 'cancelled' from public.booking_inquiries where id = '09a53800-99c1-4aa4-97ea-d6937ac1a113';
-- select status = 'void' from public.transactions where id = '68ffda92-665a-40b1-af69-3ad023ce1b06';
-- select count(*) = 0 from public.guest_message_log where booking_id = '09a53800-99c1-4aa4-97ea-d6937ac1a113';
-- select count(*) = 0 from public.automation_outbox where status = 'pending' and aggregate_id in ('09a53800-99c1-4aa4-97ea-d6937ac1a113','899604a0-e240-4fa6-aaf5-d2318bc4db7d');
