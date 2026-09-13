-- 2026-09-14 · Link every confirmed Airbnb payout row to its reservation (session 11, item 4).
-- Read-only finding first: 103 confirmed airbnb_payout_email rows, none carried booking_id.
--   92 are real payout emails whose detail_lines name the confirmation code (91 name one stay, 1 names two);
--   11 are synthetic-<code> rows created 2026-06-06 for stays whose email never arrived.
-- The 15 "reservations without payout email" are therefore covered, not gaps: their payout rows
-- exist (synthetic net of the PHP 250, later 550, co-host deduction; or a real email dated near
-- payout_date). This script records the link. It changes booking_id only; never amounts or status.
--
-- Run (Git Bash, from stay-site):
--   bash scripts/migrations/run-sql-on-host.sh docs/plans/2026-09-14-link-payouts-to-reservations.sql
--
-- Rollback (same runner):
--   update public.transactions set booking_id = null
--    where source = 'airbnb_payout_email' and notes like '%[linked 2026-09-14 s11]%';
--   update public.transactions set notes = replace(notes, ' [linked 2026-09-14 s11]', '')
--    where source = 'airbnb_payout_email' and notes like '%[linked 2026-09-14 s11]%';

begin;

-- 1. Real payout emails naming exactly one stay.
with em as (
  select t.id txn_id, min(dl->>'confirmation_code') code, count(distinct dl->>'confirmation_code') n
  from public.transactions t
  join public.airbnb_email_events e on e.gmail_message_id = t.external_ref
  join lateral jsonb_array_elements(coalesce(e.raw_payload->'detail_lines','[]'::jsonb)) dl on dl->>'line_type' = 'Home'
  where t.source = 'airbnb_payout_email' and t.status = 'confirmed' and t.booking_id is null
  group by t.id
  having count(distinct dl->>'confirmation_code') = 1
)
update public.transactions t
   set booking_id = r.id,
       notes = coalesce(t.notes, '') || ' [linked 2026-09-14 s11]',
       updated_at = now()
  from em join public.airbnb_reservations r on r.confirmation_code = em.code
 where t.id = em.txn_id;

-- 2. Synthetic rows: the code is in external_ref.
update public.transactions t
   set booking_id = r.id,
       notes = coalesce(t.notes, '') || ' [linked 2026-09-14 s11]',
       updated_at = now()
  from public.airbnb_reservations r
 where t.source = 'airbnb_payout_email' and t.status = 'confirmed' and t.booking_id is null
   and t.external_ref like 'synthetic-%' and r.confirmation_code = substr(t.external_ref, 11);

-- Report.
select 'linked' k, count(*)::text v from public.transactions where source = 'airbnb_payout_email' and status = 'confirmed' and booking_id is not null
union all
select 'still_unlinked', count(*)::text from public.transactions where source = 'airbnb_payout_email' and status = 'confirmed' and booking_id is null
union all
-- Expected 1: email 19b91676c5fba55c (2026-01-06, PHP 263.03) names HM4D4XPC9P and HM94F8E5Y3 together; split by hand.
select 'unlinked_refs', string_agg(external_ref || ' ' || transaction_date || ' ' || gross_amount, ' | ') from public.transactions where source = 'airbnb_payout_email' and status = 'confirmed' and booking_id is null
union all
select 'completed_without_payout_row', count(*)::text from public.airbnb_reservations r
 where r.status = 'completed' and not exists (select 1 from public.transactions t where t.booking_id = r.id and t.source = 'airbnb_payout_email' and t.status = 'confirmed');

commit;
