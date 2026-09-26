-- 2026-09-27 (session 56): synthetic proof of SPEC-05 messages 5.1 and 5.2 on the live function.
-- ONE synthetic confirmed direct booking, e-mail cascadereservations+ben@gmail.com (the test alias; no Messenger thread, so
-- both messages e-mail), Sep 25-27 - it checks out TODAY, so:
--   checkout_reminder at the 09:05 Manila run, after_departure (review links) at the 16:05 Manila run.
-- Why only this one: a synthetic stay with a check-out after today trips system-verifier V2 ("Confirmed booking with no
-- calendar block") and, with a calendar row on the Airbnb-booked nights, V1 ("Two stays overlap") - red cards to OPS and
-- Finance in the night. The door-code card and mid_stay are proven in a daytime session instead (D-265).
-- No calendar_events, transactions or holds are created. Inserted with source 'test' then switched to 'direct': the
-- outbox trigger fires only on INSERT with source 'direct', so no booking.requested event reaches n8n / Finance.
-- confirmation and pre_arrival are pre-logged ('skipped') so only 5.1 and 5.2 fire (1 and 2 were proven in session 54).
-- Guarded. Run with scripts/migrations/run-sql-on-host.sh from stay-site, before 09:00 Manila 2026-09-27.
-- Cleanup: 2026-09-27-s56-synthetic-cleanup.sql (after the 16:05 Manila run).
begin;
do $$
declare
  bid uuid := 'e5600000-0000-4000-8000-0000000000c0';
  d date := (now() at time zone 'Asia/Manila')::date;
  n integer;
begin
  if d <> date '2026-09-27' or (now() at time zone 'Asia/Manila')::time >= time '09:00' then
    raise exception 'written for 2026-09-27 before 09:00 Manila (now %); nothing changed', now() at time zone 'Asia/Manila';
  end if;
  if exists (select 1 from public.booking_inquiries where id = bid) then raise exception 'the synthetic booking already exists; nothing changed'; end if;

  insert into public.booking_inquiries (id, property_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, status, source, submitted_at, total_amount, deposit_amount, notes)
  values (bid, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Synthetic S56 Checkout', 'cascadereservations+ben@gmail.com', '09170000562',
          date '2026-09-25', date '2026-09-27', 2, 'confirmed', 'test', now(), 3560, 1780, '[system] session 56 synthetic test');
  update public.booking_inquiries set source = 'direct' where id = bid;
  get diagnostics n = row_count; if n <> 1 then raise exception 'expected 1 synthetic booking, got %; nothing changed', n; end if;

  insert into public.guest_message_log (booking_id, message_key, channel, status, detail)
  values (bid, 'confirmation', 'card_only', 'skipped', 'session 56 synthetic: proven in session 54'),
         (bid, 'pre_arrival',  'card_only', 'skipped', 'session 56 synthetic: proven in session 54');

  if exists (select 1 from public.automation_outbox where aggregate_id = bid) then
    raise exception 'an outbox event was queued for the synthetic booking; nothing changed';
  end if;
end $$;
commit;
-- Checks (read-only):
-- select * from public.due_guest_messages_v1(((date '2026-09-27') + time '09:05') at time zone 'Asia/Manila') where booking_id = 'e5600000-0000-4000-8000-0000000000c0';  -> checkout_reminder
-- select * from public.due_guest_messages_v1(((date '2026-09-27') + time '16:05') at time zone 'Asia/Manila') where booking_id = 'e5600000-0000-4000-8000-0000000000c0';  -> after_departure
