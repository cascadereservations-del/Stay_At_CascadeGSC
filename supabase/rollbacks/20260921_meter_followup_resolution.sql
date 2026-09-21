-- Compensating rollback for release meter_followup_resolution_20260921
--   20260921000000_meter_followup_resolution.sql
--
-- Deploy the previous submit-cleaning FIRST (waves 1e5df70) and re-publish the
-- previous checklist, or the app's "I have dealt with it" button starts failing
-- against a function that is no longer there. The button already falls back to
-- hiding the card locally on any error, so this is a tidiness rule rather than a
-- safety one; the server block is the part that must go first, because with the
-- function dropped nobody could clear a block that submit-cleaning still enforces.
--
-- The two COLUMNS are deliberately NOT dropped. They hold who cleared which
-- follow-up and what they said they did about it — evidence about real people
-- doing real work, which a rollback of a code decision has no business
-- destroying. Leaving them also means a rolled-back follow-up stays cleared
-- rather than silently re-blocking the cleaner who already answered for it.
-- Re-applying the migration is a no-op on them (add column if not exists).
begin;

drop function if exists public.resolve_meter_followup_v1(uuid, text);

commit;
