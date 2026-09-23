-- Session 46: reset Lloyd's own Messenger test thread (psid 24786231807734398, "Ben") to a first-contact state, so
-- SPEC-01 (Cassy opener once, Taglish opener) and SPEC-13 (look-before-you-book block with both links) can be read
-- live. `introduced` is a scan of history for a bot turn naming Cassy (index.ts:688), so emptying history is what
-- makes the next message a first contact. Touches this one row only; no booking rows exist for it (checked below).
-- Safe to re-run.
begin;
update public.concierge_threads
   set history = '[]'::jsonb, bot_turns = 0, booking_flow = null, human_until = null
 where psid = '24786231807734398';
commit;
-- forward checks: expect 1 row with hist 0, turns 0, flow null; and 0 synthetic inquiries
select 'thread' k, jsonb_array_length(history) hist, bot_turns turns, (booking_flow is null) flow_cleared
  from public.concierge_threads where psid = '24786231807734398';
select 'ben_inquiries' k, count(*) from public.booking_inquiries where guest_email = 'ben@example.com';
