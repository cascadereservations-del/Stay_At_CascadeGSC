-- 20260914170000_transactions_reservation_id.sql (admin session 11, item 4)
-- transactions.booking_id references booking_inquiries (direct bookings only), so Airbnb payout
-- rows had no way to name their stay: 0 of 103 confirmed airbnb_payout_email rows were linked.
-- Finding (read-only, 2026-09-14): 92 real payout emails name a known confirmation code in
-- raw_payload.detail_lines (91 one stay, 1 two stays), 11 synthetic-<code> rows carry it in
-- external_ref, and all 78 CSV mirror rows name it in notes. The 15 completed reservations
-- without payout_email_message_id are all covered.
-- This adds one nullable column and fills it. Amounts and statuses are untouched.
--
-- Run (PowerShell):
--   & "C:\Program Files\Git\bin\bash.exe" -c 'cd /c/Users/Lloyd/Claude/Projects/Cascade/stay-site && bash scripts/migrations/run-sql-on-host.sh supabase/migrations/20260914170000_transactions_reservation_id.sql'
-- Rollback: alter table public.transactions drop column reservation_id;
begin;

alter table public.transactions
  add column if not exists reservation_id uuid references public.airbnb_reservations(id);
create index if not exists transactions_reservation_id_idx on public.transactions (reservation_id) where reservation_id is not null;
comment on column public.transactions.reservation_id is 'Airbnb stay this row settles (payout emails, synthetic payouts, CSV mirrors). booking_id is for direct bookings.';

-- 1. Real payout emails naming exactly one stay.
with em as (
  select t.id txn_id, min(dl->>'confirmation_code') code
  from public.transactions t
  join public.airbnb_email_events e on e.gmail_message_id = t.external_ref
  join lateral jsonb_array_elements(coalesce(e.raw_payload->'detail_lines','[]'::jsonb)) dl on dl->>'line_type' = 'Home'
  where t.source = 'airbnb_payout_email' and t.status = 'confirmed' and t.reservation_id is null
  group by t.id
  having count(distinct dl->>'confirmation_code') = 1
)
update public.transactions t
   set reservation_id = r.id, updated_at = now()
  from em join public.airbnb_reservations r on r.confirmation_code = em.code
 where t.id = em.txn_id;

-- 2. Synthetic rows: the code is in external_ref.
update public.transactions t
   set reservation_id = r.id, updated_at = now()
  from public.airbnb_reservations r
 where t.source = 'airbnb_payout_email' and t.status = 'confirmed' and t.reservation_id is null
   and t.external_ref like 'synthetic-%' and r.confirmation_code = substr(t.external_ref, 11);

-- 3. CSV mirror rows name the code in notes ("Airbnb <CODE> · ...").
update public.transactions t
   set reservation_id = r.id, updated_at = now()
  from public.airbnb_reservations r
 where t.source = 'airbnb' and t.txn_type = 'income' and t.reservation_id is null
   and t.notes ~ '^Airbnb HM[A-Z0-9]{8} '
   and r.confirmation_code = substring(t.notes from '^Airbnb (HM[A-Z0-9]{8}) ');

-- Forward check: at most one confirmed payout row is left unlinked (email 19b91676c5fba55c names two stays).
do $$
declare v int;
begin
  select count(*) into v from public.transactions where source = 'airbnb_payout_email' and status = 'confirmed' and reservation_id is null;
  if v > 1 then raise exception 'link incomplete: % confirmed payout rows still unlinked', v; end if;
end $$;

-- Report.
select 'payout_linked' k, count(*)::text v from public.transactions where source = 'airbnb_payout_email' and status = 'confirmed' and reservation_id is not null
union all select 'payout_unlinked', string_agg(external_ref || ' ' || transaction_date || ' ' || gross_amount, ' | ') from public.transactions where source = 'airbnb_payout_email' and status = 'confirmed' and reservation_id is null
union all select 'csv_linked', count(*)::text from public.transactions where source = 'airbnb' and txn_type = 'income' and reservation_id is not null
union all select 'completed_without_payout_row', coalesce(string_agg(r.confirmation_code, ' '), '0') from public.airbnb_reservations r
 where r.status = 'completed' and not exists (select 1 from public.transactions t where t.reservation_id = r.id and t.source = 'airbnb_payout_email' and t.status = 'confirmed');

commit;
