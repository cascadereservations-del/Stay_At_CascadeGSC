-- 2026-09-28 (session 58): daytime proof of SPEC-05 message 3 (the door-code card to Finance) and message 4 (mid_stay),
-- the two session 56 could not prove at night (D-265). Two synthetic confirmed direct bookings, e-mail
-- cascadereservations+ben@gmail.com (the test alias, no Messenger thread, so mid_stay e-mails):
--   A  e5800000-...-a0  check-in today-3, check-out today+2 (5 nights): mid_stay is due today 15:00-21:00 Manila.
--   B  e5800000-...-b0  check-in today+4, one night, a synthetic guest with ID on file: the door-code card is due.
-- confirmation and pre_arrival are pre-logged 'skipped' (proven in session 54). No calendar_events, transactions or holds.
-- Inserted with source 'test' then switched to 'direct' (the outbox trigger fires on INSERT / status, not on source).
-- guest-messages is called once after commit (pg_net), so nothing waits for the :05 cron.
-- system-verifier runs V1-V5 hourly at :35: an in-progress synthetic trips V2, so this refuses to run between :28 and :36
-- and the cleanup (2026-09-28-s58-synthetic-cleanup.sql) runs in the same block about a minute later.
-- Guarded. Run with scripts/migrations/run-sql-on-host.sh from stay-site.
begin;
do $$
declare
  a uuid := 'e5800000-0000-4000-8000-0000000000a0';
  b uuid := 'e5800000-0000-4000-8000-0000000000b0';
  g uuid := 'e5800000-0000-4000-8000-0000000000c0';
  prop uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  mnl timestamp := now() at time zone 'Asia/Manila';
  d date := mnl::date;
  n integer;
begin
  if d <> date '2026-09-28' or mnl::time < time '15:00' or mnl::time >= time '20:50' then
    raise exception 'written for 2026-09-28 15:00-20:50 Manila, the mid_stay window (now %); nothing changed', mnl;
  end if;
  if extract(minute from mnl) between 28 and 36 then
    raise exception 'too close to the :35 system-verifier run (now %); run again after :37', mnl;
  end if;
  if exists (select 1 from public.booking_inquiries where id in (a, b)) or exists (select 1 from public.guests where id = g) then
    raise exception 'a synthetic row already exists; nothing changed';
  end if;

  insert into public.guests (id, property_id, name, source) values (g, prop, 'Synthetic S58 Door (test, ignore)', 'manual');
  insert into public.guest_profile_details (guest_id, property_id, id_on_file) values (g, prop, true);

  insert into public.booking_inquiries (id, property_id, guest_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, status, source, submitted_at, total_amount, deposit_amount, notes)
  values (a, prop, null, 'Synthetic S58 Midstay (test, ignore)', 'cascadereservations+ben@gmail.com', '09170000581',
          d - 3, d + 2, 2, 'confirmed', 'test', now(), 8900, 4450, '[test] session 58 synthetic mid_stay'),
         (b, prop, g, 'Synthetic S58 Door (test, ignore)', 'cascadereservations+ben@gmail.com', '09170000582',
          d + 4, d + 5, 2, 'confirmed', 'test', now(), 1780, 890, '[test] session 58 synthetic door code');
  update public.booking_inquiries set source = 'direct' where id in (a, b);
  get diagnostics n = row_count; if n <> 2 then raise exception 'expected 2 synthetic bookings, got %; nothing changed', n; end if;

  insert into public.guest_message_log (booking_id, message_key, channel, status, detail)
  values (a, 'confirmation', 'card_only', 'skipped', 'session 58 synthetic: proven in session 54'),
         (a, 'pre_arrival',  'card_only', 'skipped', 'session 58 synthetic: proven in session 54'),
         (b, 'confirmation', 'card_only', 'skipped', 'session 58 synthetic: proven in session 54'),
         (b, 'pre_arrival',  'card_only', 'skipped', 'session 58 synthetic: proven in session 54');

  if exists (select 1 from public.automation_outbox where aggregate_id in (a, b)) then
    raise exception 'an outbox event was queued for a synthetic booking; nothing changed';
  end if;
  -- exactly the two messages this test is for, and nothing else, is due
  if (select count(*) from public.due_guest_messages_v1() x where x.booking_id in (a, b)) <> 2
     or not exists (select 1 from public.due_guest_messages_v1() x where x.booking_id = a and x.message_key = 'mid_stay')
     or not exists (select 1 from public.due_guest_messages_v1() x where x.booking_id = b and x.message_key = 'door_code_offer') then
    raise exception 'due_guest_messages_v1 does not return exactly mid_stay (A) and door_code_offer (B); nothing changed';
  end if;
end $$;
select net.http_post(
  url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/guest-messages',
  headers := jsonb_build_object('Content-Type', 'application/json',
             'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')),
  body    := '{}'::jsonb) as request_id;
commit;
