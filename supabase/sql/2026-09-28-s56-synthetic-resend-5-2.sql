-- 2026-09-28 (session 56 follow-up, D-266): re-prove message 5.2 after the guest_message_reads fix. The synthetic
-- "S56 Checkout" (e5600000-...-c0) had 5.2 held on 2026-09-27 16:05 by the permission bug. Move its check-out to TODAY
-- (2026-09-28, Manila) and remove only its after_departure log row, so the 16:05 Manila run sends it with the fixed code.
-- checkout_reminder stays logged (sent 2026-09-27 09:05), so nothing else repeats. No calendar row exists for it, and a
-- check-out of today does not trip verifier V2 (it counts check-outs after today).
-- Run AFTER release guest_message_reads_20260928 is applied and guest-messages is redeployed, before 16:00 Manila.
-- Guarded. Run with scripts/migrations/run-sql-on-host.sh from stay-site. Cleanup afterwards: 2026-09-27-s56-synthetic-cleanup.sql.
begin;
do $$
declare n integer;
begin
  if (now() at time zone 'Asia/Manila')::date <> date '2026-09-28' or (now() at time zone 'Asia/Manila')::time >= time '16:00' then
    raise exception 'written for 2026-09-28 before 16:00 Manila (now %); nothing changed', now() at time zone 'Asia/Manila';
  end if;
  update public.booking_inquiries set checkout_date = date '2026-09-28'
   where id = 'e5600000-0000-4000-8000-0000000000c0' and guest_email = 'cascadereservations+ben@gmail.com' and status = 'confirmed';
  get diagnostics n = row_count; if n <> 1 then raise exception 'synthetic booking not matched (%); nothing changed', n; end if;
  delete from public.guest_message_log
   where booking_id = 'e5600000-0000-4000-8000-0000000000c0' and message_key = 'after_departure' and detail = 'open complaint';
  get diagnostics n = row_count; if n <> 1 then raise exception 'held after_departure row not matched (%); nothing changed', n; end if;
end $$;
commit;
-- Check (read-only): select * from public.due_guest_messages_v1(((date '2026-09-28') + time '16:05') at time zone 'Asia/Manila') where booking_id = 'e5600000-0000-4000-8000-0000000000c0';  -> after_departure
