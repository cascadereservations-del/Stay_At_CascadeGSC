-- Ledger truth, 2026-09-14 (admin session 12, item 2; D-113).
-- Source: the Messenger "Cascade Hideaway - Receipts" parse (cascade-fb-transactions.md, 74 rows)
-- correlated against public.transactions on 2026-09-14: only two rows already existed (EcoFlow
-- 13,190 on 2026-04-08; internet 1,500 on 2026-08-31). Lloyd 2026-09-14: "yes they are all
-- expenses except 953 Aragon; Jarely 2,500 and Jerly 2,000 = payment for previous cleaners";
-- payout split option A; meter flags as recommended.
--
-- What this does (every insert is idempotent on external_ref, every write is audited by the
-- admin_audit_row trigger with the reason set below):
--   1. FB expenses as source manual, confirmed. Skipped on purpose: 953 Aragon 3,500 (other
--      property); Honey cash payments from 2026-05-28 on (05-30 800, 06-10 500+500, 06-13 750,
--      06-29 1,020, 09-14 1,300) because the per-session cleaner_fee rows already carry those
--      cleans; 2026-06-09 ~1,640 "Clas Thomas refund" (the 3,640 refund of HMSHFR4NRD is already
--      recorded, the parse misread the amount); 2026-02-14 Clean Depot 1,146 (same amount as the
--      July xlsx row 28, probable duplicate); rows with no legible amount.
--   2. The nine BPI/InstaPay transfers to "Own Bank" as txn_type drawing (owner transfers out).
--   3. Payout e-mail 19b91676c5fba55c linked to HM94F8E5Y3 with HM4D4XPC9P in the note (option A).
--   4. meter_flag on readings 393dd9fb (first_reading) and 88bf01fe (re_entry).
--   The 33 per-session cleaner_fee rows are NOT voided: Lloyd has no lump-sum list (Honey resumed
--   about three months ago; earlier cleans were Jary, Hazel Ann and an earlier Honey contract), so
--   the per-clean rows stay as the fee record. Jan-May 2026 (55 completed stays) has no cleaning
--   record at all; only the FB payments to Hazel Anne, Jarely and Jerly are booked here.
--
-- Run (PowerShell):
--   & "C:\Program Files\Git\bin\bash.exe" -lc 'cd /c/Users/Lloyd/Claude/Projects/Cascade/stay-site && CASCADE_SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe bash scripts/migrations/run-sql-on-host.sh docs/plans/2026-09-14-ledger-truth.sql'
-- Undo: every row is in Settings > Audit history; admin_undo_v1 voids an insert and restores an update.
begin;

select public.admin_audit_context_v1('ledger truth 2026-09-14 (D-113): FB receipts import, owner drawings, payout split A, meter flags; Lloyd approved 2026-09-14');

-- 1. FB expenses -------------------------------------------------------------------------------
with fb(d, amt, cat, payee, note) as (values
  ('2025-10-28'::date, 222.00::numeric, 'utilities'::text, 'Gensan City Water District'::text, 'Water bill Oct 2025 (Maya, Suzanne)'::text),
  ('2025-10-28', 1046.30, 'utilities', 'SOCOTECO II', 'Electric bill Oct 2025 (GCash, Suzanne)'),
  ('2025-10-31', 200.00, 'supplies', 'S&R Dry Goods Store', 'Balde, kabo, sponge (Hazel Ann, invoice 0132)'),
  ('2025-11-01', 850.00, 'cleaning', 'Hazel Anne Pedrano', 'Cleaning fee (InstaPay)'),
  ('2025-11-01', 1000.00, 'internet', 'Latimer III Ceniza', 'Internet (InstaPay)'),
  ('2025-11-02', 1574.00, 'supplies', 'Petty cash (Hazel Ann)', 'Petty cash log 2025-10-22 to 11-02: tape, adhesive, gasoline x3, Uncle Nonoy 500, booking fee 200, umbrella 160, fares, balde/kabo/sponge, tissue'),
  ('2025-11-09', 100.00, 'supplies', 'Green Cross', 'Isopropyl alcohol 70%'),
  ('2025-11-22', 219.50, 'supplies', 'Store (name unclear)', 'Clean Liniig soda 1L'),
  ('2025-11-30', 2456.82, 'utilities', 'SOCOTECO II', 'Electric bill Nov 2025 (Maya, Suzanne)'),
  ('2025-12-01', 1250.00, 'cleaning', 'Honey / Kuya Brian', 'Honey back-up help 500 + Kuya Brian pakyaw transport Conel-Mandaue-Bria-Conel 750 (GCash)'),
  ('2025-12-02', 1000.00, 'internet', 'Latimer III Ceniza', 'Internet Nov 2025 (GCash)'),
  ('2025-12-05', 212.00, 'utilities', 'Gensan City Water District', 'Water bill Nov 2025 (date approximate, early Dec)'),
  ('2025-12-06', 340.00, 'supplies', 'JRK Consumer Inc.', '2 pcs gallon blue container'),
  ('2025-12-09', 180.00, 'supplies', 'Slosh Laundry Hub', 'Comforter laundry drop-off 170 + Surf Fabcon 10'),
  ('2026-02-11', 449.00, 'subscription', 'Netflix', 'Netflix subscription (card)'),
  ('2026-02-27', 2500.00, 'cleaning', 'Jarely Mabandos', 'Payment for previous cleaners (Lloyd 2026-09-14); pooled staff payment, GCash'),
  ('2026-02-28', 222.00, 'utilities', 'Gensan City Water District', 'Water bill (GCash, Suzanne)'),
  ('2026-02-28', 3447.80, 'utilities', 'SOCOTECO II', 'GCash payment, unlabeled, most likely electric (Suzanne)'),
  ('2026-03-24', 1397.00, 'supplies', 'Sunplus Cebu Store', 'Air purifier filter (Shopee, approximate)'),
  ('2026-03-26', 3533.71, 'utilities', 'SOCOTECO II', 'GCash payment, most likely electric (Suzanne)'),
  ('2026-03-26', 2097.00, 'loan', 'Pag-IBIG', 'Housing loan amortization, period 2026/03'),
  ('2026-03-26', 1890.00, 'supplies', 'Uniworld Home Care', 'Laundry liquid detergent bundle x2 (Shopee)'),
  ('2026-03-27', 928.00, 'supplies', 'Parrot Philippines', 'Air freshener / lavender x2 (Shopee, approximate)'),
  ('2026-04-18', 2000.00, 'cleaning', 'Jerly Malarindo', 'Payment for previous cleaners (Lloyd 2026-09-14); amount approximate, screenshot cut'),
  ('2026-04-28', 2593.47, 'utilities', 'SOCOTECO II', 'Electric bill Apr 2026 (GCash, Suzanne)'),
  ('2026-04-30', 1000.00, 'internet', 'Latimer III Ceniza', 'Internet (InstaPay, approximate)'),
  ('2026-05-06', 2000.00, 'other', 'Unknown (GCash)', 'GCash transfer, recipient not visible in the thread'),
  ('2026-05-07', 1798.00, 'supplies', 'SC Artknit Official Store', 'Muscle glass and multi-surface cleaner x2 (Shopee)'),
  ('2026-05-13', 650.00, 'cleaning', 'AU***Y C. (GCash 09384907562)', 'Cleaning payment, payee masked in the thread'),
  ('2026-05-25', 5000.00, 'loan', 'Pag-IBIG', 'Provident fund contribution'),
  ('2026-06-11', 1830.00, 'supplies', 'Honey Dorz Corcales', 'Replacement items: broken glass, vase, dishwashing liquid, garbage bag (approximate)'),
  ('2026-06-12', 449.00, 'subscription', 'Netflix', 'Netflix subscription (card)'),
  ('2026-06-23', 2807.00, 'loan', 'Pag-IBIG', 'Housing loan amortization, period 2026/06'),
  ('2026-06-28', 4306.15, 'utilities', 'SOCOTECO II', 'Electric bill Jun 2026 (approximate)'),
  ('2026-06-28', 229.63, 'utilities', 'Gensan City Water District', 'Water bill Jun 2026 (approximate)'),
  ('2026-07-09', 1185.25, 'supplies', 'ShopSuki', 'Body wash, toilet cleaner, laundry detergent, Baygon, Ambipur, sugar'),
  ('2026-07-22', 222.00, 'utilities', 'Gensan City Water District', 'Water bill (Maya)'),
  ('2026-07-25', 1800.00, 'other', 'Suzanne (own wallet)', 'Maya pay to own wallet; Lloyd 2026-09-14: expense'),
  ('2026-07-26', 3988.00, 'utilities', 'SOCOTECO II', 'Electric bill (GCash, approximate)'),
  ('2026-07-31', 1500.00, 'internet', 'Latimer III Ceniza', 'Internet Aug 2026 (GCash 0947 823 4016)'),
  ('2026-08-02', 1950.00, 'other', 'Suzanne (own wallet)', 'Maya pay to own wallet; Lloyd 2026-09-14: expense'),
  ('2026-08-23', 2912.70, 'utilities', 'SOCOTECO II', 'Electric bill (BPI biller, Cascade Hideaway BRIA account)'),
  ('2026-08-26', 222.00, 'utilities', 'Gensan City Water District', 'Water bill'),
  ('2026-08-27', 2097.00, 'loan', 'Pag-IBIG', 'Housing loan amortization, period 2026/08')
)
insert into public.transactions (property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, payee_name, notes, external_ref, logged_by)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid, 'expense', fb.cat, 'confirmed', 'manual', fb.d, fb.amt, 'PHP', fb.payee,
       fb.note || ' [FB Receipts GC, imported 2026-09-14]', 'fb:' || fb.d::text || ':' || fb.amt::text, 'ledger-truth-2026-09-14'
from fb
where not exists (select 1 from public.transactions t where t.external_ref = 'fb:' || fb.d::text || ':' || fb.amt::text);

-- 2. Owner drawings ---------------------------------------------------------------------------
with dr(d, amt, note) as (values
  ('2026-02-03'::date, 10635.15::numeric, 'BPI transfer out to Own Bank (MA**LI***BO** ...324)'::text),
  ('2026-02-14', 10225.55, 'BPI transfer out to Own Bank'),
  ('2026-02-27', 14573.46, 'BPI transfer out to Own Bank'),
  ('2026-03-07', 8679.71, 'BPI transfer out to Own Bank ("Transfered na Mama")'),
  ('2026-03-22', 21748.28, 'InstaPay from A Main Savings to Own Bank, "Cascade Transfer 22.03.2026"; Cascade_Income_Report-1.xlsx attached in the thread'),
  ('2026-04-08', 7856.78, 'BPI transfer out to Own Bank'),
  ('2026-04-13', 6015.27, 'BPI transfer out to Own Bank'),
  ('2026-05-04', 11125.40, 'InstaPay from A Main Savings, "Cascade"; last digit cut off in the screenshot, recorded as .40'),
  ('2026-08-24', 2300.00, 'InstaPay from A Main Savings to Own Bank (HO**LE***OO**), "Cascade Payment 2026.08.24"')
)
insert into public.transactions (property_id, txn_type, category, status, source, transaction_date, gross_amount, currency, payee_name, notes, external_ref, logged_by)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid, 'drawing', 'owner_drawing', 'confirmed', 'manual', dr.d, dr.amt, 'PHP', 'Owner (Own Bank)',
       dr.note || ' [FB Receipts GC, imported 2026-09-14 as an owner drawing]', 'fb:' || dr.d::text || ':' || dr.amt::text, 'ledger-truth-2026-09-14'
from dr
where not exists (select 1 from public.transactions t where t.external_ref = 'fb:' || dr.d::text || ':' || dr.amt::text);

-- 3. Payout split, option A -------------------------------------------------------------------
update public.transactions
   set reservation_id = '7a1d07d3-72aa-48e5-9fd7-316a2dd45a7b',
       notes = concat_ws(' | ', notes, 'Covers two stays: HM94F8E5Y3 1,455.28 (Dianne Talimongan) + HM4D4XPC9P 1,309.02 (Stanley Baldon) - 2,501.27 adjustment HMCXKT4SSB. Linked to HM94F8E5Y3; HM4D4XPC9P is settled by this same e-mail (Lloyd 2026-09-14, option A).'),
       updated_at = now()
 where external_ref = '19b91676c5fba55c' and reservation_id is null;

-- 4. Meter flags ------------------------------------------------------------------------------
update public.meter_readings
   set meter_flag = 'first_reading',
       meter_override_note = 'First reading of the 2026-08-11 backfill (previous value 0, delta 3558 kWh / 67.388 m3 is not consumption). Excluded from utilities sums. Lloyd 2026-09-14.'
 where id = '393dd9fb-e3a6-424b-8318-41b1beb164a0' and meter_flag is null;

update public.meter_readings
   set meter_flag = 're_entry',
       meter_override_note = 'Re-entry of an older photo on 2026-08-11 (negative delta -36 kWh / -0.99 m3). Excluded from utilities sums. Lloyd 2026-09-14.'
 where id = '88bf01fe-e22d-4a4a-9372-32f0d266983f' and meter_flag is null;

-- Forward checks ------------------------------------------------------------------------------
do $$
declare v_fb int; v_dr int; v_link int; v_flags int;
begin
  select count(*) into v_fb from public.transactions where logged_by = 'ledger-truth-2026-09-14' and txn_type = 'expense';
  select count(*) into v_dr from public.transactions where logged_by = 'ledger-truth-2026-09-14' and txn_type = 'drawing';
  select count(*) into v_link from public.transactions where external_ref = '19b91676c5fba55c' and reservation_id = '7a1d07d3-72aa-48e5-9fd7-316a2dd45a7b';
  select count(*) into v_flags from public.meter_readings where id in ('393dd9fb-e3a6-424b-8318-41b1beb164a0','88bf01fe-e22d-4a4a-9372-32f0d266983f') and meter_flag is not null;
  if v_fb <> 44 then raise exception 'expected 44 FB expense rows, found %', v_fb; end if;
  if v_dr <> 9 then raise exception 'expected 9 drawing rows, found %', v_dr; end if;
  if v_link <> 1 then raise exception 'payout split not applied'; end if;
  if v_flags <> 2 then raise exception 'meter flags not applied'; end if;
end $$;

-- Report.
select 'fb_expenses' k, count(*)::text || ' rows, PHP ' || sum(gross_amount) v from public.transactions where logged_by = 'ledger-truth-2026-09-14' and txn_type = 'expense'
union all select 'drawings', count(*)::text || ' rows, PHP ' || sum(gross_amount) from public.transactions where logged_by = 'ledger-truth-2026-09-14' and txn_type = 'drawing'
union all select 'income_confirmed', sum(gross_amount)::text from public.transactions where txn_type = 'income' and status = 'confirmed' and source not in ('airbnb','airbnb_email')
union all select 'expenses_confirmed', sum(gross_amount)::text from public.transactions where txn_type = 'expense' and status = 'confirmed' and source not in ('airbnb','airbnb_email')
union all select 'drawings_confirmed', sum(gross_amount)::text from public.transactions where txn_type = 'drawing' and status = 'confirmed'
union all select 'position_2026_09_14', (
  (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'income' and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= '2026-09-14')
  - (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'expense' and status = 'confirmed' and source not in ('airbnb','airbnb_email') and transaction_date <= '2026-09-14')
  - (select coalesce(sum(gross_amount),0) from public.transactions where txn_type = 'drawing' and status = 'confirmed' and transaction_date <= '2026-09-14'))::text
union all select 'audit_rows_written', count(*)::text from public.admin_audit_log where reason like 'ledger truth 2026-09-14%';

commit;
