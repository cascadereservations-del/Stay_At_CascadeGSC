-- 2026-09-26 (session 54): make SPEC-05 message 2 (pre_arrival) due at 15:05 Manila TODAY for the SYNTHETIC test booking
-- 09A53800 (Ben Munez, cascadereservations+ben@gmail.com, confirmed on Messenger 02:16Z), and force the e-mail branch.
-- 1. check-in -> Manila today + 2 (booking_inquiries only; its calendar row stays Dec 1-3 until the cleanup cancels it),
-- 2. its confirmation log row -> 5 days older (so "confirmed less than 48 h before check-in" does not skip it),
-- 3. Ben's guest turns on the test thread -> 25 h old (the 23 h Messenger window reads closed, so the relay e-mails it).
-- Guarded: only this booking id with the synthetic e-mail, only the test psid; anything else rolls back.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site. Cleanup: 2026-09-26-s54-synthetic-cleanup.sql.
begin;
do $$
declare n integer;
begin
  update public.booking_inquiries
     set checkin_date  = (now() at time zone 'Asia/Manila')::date + 2,
         checkout_date = (now() at time zone 'Asia/Manila')::date + 4
   where id = '09a53800-99c1-4aa4-97ea-d6937ac1a113' and guest_email = 'cascadereservations+ben@gmail.com' and status = 'confirmed';
  get diagnostics n = row_count; if n <> 1 then raise exception 'synthetic booking not matched (%), nothing changed', n; end if;

  update public.guest_message_log set created_at = created_at - interval '5 days'
   where booking_id = '09a53800-99c1-4aa4-97ea-d6937ac1a113' and message_key = 'confirmation';
  get diagnostics n = row_count; if n <> 1 then raise exception 'confirmation log row not matched (%), nothing changed', n; end if;

  update public.concierge_threads
     set history = (select jsonb_agg(case when h->>'role' = 'guest' then jsonb_set(h, '{at}', to_jsonb(to_char((now() - interval '25 hours') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))) else h end order by i)
                      from jsonb_array_elements(history) with ordinality as x(h, i))
   where psid = '24786231807734398' and booking_flow->>'booking_id' = '09a53800-99c1-4aa4-97ea-d6937ac1a113';
  get diagnostics n = row_count; if n <> 1 then raise exception 'test thread not matched (%), nothing changed', n; end if;
end $$;
commit;
-- Check (read-only, after 15:00 Manila): select * from public.due_guest_messages_v1();  -> 09a53800 / pre_arrival until 15:05
