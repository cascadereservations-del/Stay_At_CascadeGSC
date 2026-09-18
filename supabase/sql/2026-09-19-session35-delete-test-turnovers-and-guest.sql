-- One-off reviewed SQL (session 35, Lloyd 2026-09-19: "delete everything that is fake as not to taint
-- or poison the database"). Run with run-sql-on-host.sh from stay-site. Idempotent: every delete is
-- keyed on explicit ids and re-running it is a no-op.
--
-- WHAT IS BEING DELETED, and why each one is safe:
--
--  1. cleaning_sessions 940ee84f-86a4-4b27-b671-8b59722c56ac  (2026-09-10, last_guest_name 'test', 16 photos)
--  2. cleaning_sessions 66f2d126-b19e-422b-bab1-37af51865048  (2026-09-18, last_guest_name 'test', 20 photos)
--
--     Both are test submissions, not cleanings of a guest stay. Their meter readings carry NO
--     information: the 2026-09-18 row reads electric 3921 -> 3921 and water 73.8330 -> 73.8330, a
--     delta of exactly 0.00, because it duplicates the reading the real 2026-09-18 01:43Z turnover
--     already recorded. The next real cleaning therefore compares against the same numbers whether
--     these rows exist or not. Nothing real is lost.
--
--     Before running this, the evidence they carried was written into the vault: BASELINE B101 now
--     quotes the six Confirm & Leave items that reached checklist_details for the first time on the
--     2026-09-18 row, which is what SPEC-02 and D-187 were built to produce.
--
--  3. guests f0b6cc72-a80b-44b3-9f85-94100116ba50  (name 'test', 0 stays, created 2026-07-01)
--     Zero references: no booking_inquiries, no crm_guest_profiles, no conversations, no reservations,
--     no follow-ups, no companions, no profile details. Verified by FK census 2026-09-19.
--
-- WHAT IS DELIBERATELY NOT DELETED:
--
--  - All three booking_inquiries and all three `direct:` calendar_events. Every one is a real person
--    (Loreine Shane G. Lopez, confirmed; Marifel Suzanne Boncales and Marifel, both cancelled). A
--    cancellation is exactly when the record matters.
--  - concierge_threads: zero `probe:` rows, nothing to clean.
--
-- STILL OWED AFTER THIS, and only Lloyd can do it (SQL cannot delete Storage objects):
--  - The five orphan booking receipts named in the vault note RECEIPTS-AUDIT-2026-09-18.
--  - The cleaning photos of the two sessions below, under
--    cleaning-photos/6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/<submission>/... for each.
--    Storage -> cleaning-photos in the Supabase dashboard.

begin;

-- Children first: both have a FK to cleaning_sessions.
delete from public.meter_readings
 where session_id in ('940ee84f-86a4-4b27-b671-8b59722c56ac', '66f2d126-b19e-422b-bab1-37af51865048');

delete from public.cleaning_diagnostics
 where session_id in ('940ee84f-86a4-4b27-b671-8b59722c56ac', '66f2d126-b19e-422b-bab1-37af51865048');

delete from public.cleaning_sessions
 where id in ('940ee84f-86a4-4b27-b671-8b59722c56ac', '66f2d126-b19e-422b-bab1-37af51865048');

delete from public.guests
 where id = 'f0b6cc72-a80b-44b3-9f85-94100116ba50';

-- Forward check: refuse to commit if anything named above survived, or if a real row was caught.
do $$
declare v_sessions int; v_guest int; v_real int;
begin
  select count(*) into v_sessions from public.cleaning_sessions
   where id in ('940ee84f-86a4-4b27-b671-8b59722c56ac', '66f2d126-b19e-422b-bab1-37af51865048');
  select count(*) into v_guest from public.guests where id = 'f0b6cc72-a80b-44b3-9f85-94100116ba50';
  select count(*) into v_real from public.booking_inquiries;

  if v_sessions <> 0 then raise exception 'test cleaning sessions survived: %', v_sessions; end if;
  if v_guest <> 0 then raise exception 'test guest survived'; end if;
  if v_real <> 3 then raise exception 'booking_inquiries should still hold its 3 real rows, found %', v_real; end if;
  raise notice 'deleted 2 test cleaning sessions with their readings and diagnostics, and 1 test guest; 3 real booking_inquiries untouched';
end $$;

commit;
