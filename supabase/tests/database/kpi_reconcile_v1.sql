-- Session 91, lane kpi-sql: release s91_kpi_20261026. The golden file for docs/s91/KPI-AUDIT.md: a month whose every headline number is known by hand,
-- the fixes F1 F2 F3 F6 F7 F10, and the mechanism (kpi_recompute_v1, kpi_reconcile_v1, kpi_reconcile_window_v1, the V19 wiring and the kpi_reconciled health row).
-- Private fixture property, inside begin/rollback, for the LAST FULL MONTH (Manila). Stays (all in the past):
--   A  Airbnb 3 nights, transaction export gross 3,000, cleaning 0     (+ a confirmed airbnb_email estimate of 3,000)
--   B  Airbnb 2 nights, no export row, host payout 1,500 + host fee 300 = 1,800
--   C  direct 1 night, total 1,780, WITH its DIRECT: mirror reservation (the F1 double count)
--   D  Airbnb 2 nights, TWO export rows 1,000 + 2,000 (the F2 split payout)
--   E  Airbnb 5 nights, cancelled
--   F  synthetic direct inquiry, cancelled, dated in the next month
-- Ledger: payout e-mails 1,500 (B) + 2,550 (D); direct_booking 1,780; three cleaner fees of 650 with their sessions; one drawing of 2,300.
-- Golden (days = days in that month): sold 8, occupancy round(800/days, 2) (31 days: 25.81), revenue 9,580.00 complete, ADR 1,197.50, RevPAR round(9580/days, 2) (31: 309.03),
-- cash 5,830.00, finance income 5,830.00, net 1,580.00, cleaner fees 1,950 = 1,950, cancellation 20.00, ALOS 2.00.
-- Deviation from the audit text, on purpose: a +100 revenue drift on ONE side cannot raise "exactly one" finding, because ADR and RevPAR are derived from revenue; the test asserts the
-- accommodation_revenue finding (red, diff 100.00) and that nothing outside the revenue family fires.
begin;
select plan(49);

create temp table fx on commit drop as select (date_trunc('month', public.manila_today()::timestamp) - interval '1 month')::date m;
create function pg_temp.mo(p_off integer) returns date language sql as $$ select m + p_off from fx $$;
create function pg_temp.days() returns integer language sql as $$ select ((m + interval '1 month')::date - m) from fx $$;
create function pg_temp.keys(p jsonb) returns text language sql as $$ select coalesce(string_agg(e ->> 'key', ',' order by e ->> 'key'), '') from jsonb_array_elements(p) e $$;

-- Shape of the new internals: they exist, are definer with an empty search_path, and no client role can run them.
select has_function('public', 'hospitality_metrics_core_v1', array['uuid','date','date','boolean'], 'the metrics core exists');
select has_function('public', 'kpi_recompute_v1', array['uuid','date','date'], 'the recompute exists');
select has_function('public', 'kpi_reconcile_v1', array['uuid','date'], 'the reconcile exists');
select has_function('public', 'kpi_reconcile_window_v1', array['uuid','date'], 'the four-month window exists');
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""']) from pg_proc p where p.oid in (
  'public.hospitality_metrics_core_v1(uuid,date,date,boolean)'::regprocedure, 'public.kpi_recompute_v1(uuid,date,date)'::regprocedure,
  'public.kpi_reconcile_v1(uuid,date)'::regprocedure, 'public.kpi_reconcile_window_v1(uuid,date)'::regprocedure)), 'all four are security definer with an empty search_path');
select ok(not exists (select 1 from pg_proc p, unnest(array['anon', 'authenticated', 'service_role']) r(role_name) where p.oid in (
  'public.hospitality_metrics_core_v1(uuid,date,date,boolean)'::regprocedure, 'public.kpi_recompute_v1(uuid,date,date)'::regprocedure,
  'public.kpi_reconcile_v1(uuid,date)'::regprocedure, 'public.kpi_reconcile_window_v1(uuid,date)'::regprocedure)
  and has_function_privilege(r.role_name, p.oid, 'execute'))
  and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where a.grantee = 0 and p.oid in (
  'public.hospitality_metrics_core_v1(uuid,date,date,boolean)'::regprocedure, 'public.kpi_recompute_v1(uuid,date,date)'::regprocedure,
  'public.kpi_reconcile_v1(uuid,date)'::regprocedure, 'public.kpi_reconcile_window_v1(uuid,date)'::regprocedure)), 'anon, authenticated, service_role and PUBLIC cannot execute any of them');
select ok((select prosecdef and proconfig = array['search_path=""'] and has_function_privilege('authenticated', oid, 'execute') and not has_function_privilege('anon', oid, 'execute')
           from pg_proc where oid = 'public.get_hospitality_metrics_v1(uuid,date,date)'::regprocedure), 'get_hospitality_metrics_v1 keeps its signature, definer and grants (authenticated only)');
select is(public.health_check_problem_v1('kpi_reconciled'), 'KPIs do not reconcile', 'the health sentence for the new row');
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.inventory_purchases'::regclass and attname = 'units_per_purchase' and not attisdropped),
          'numeric(10,4)', 'F10: a purchase can record a fractional pack size');
select ok(position('units_per_purchase, 1)::integer' in (select prosrc from pg_proc where oid = 'public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid)'::regprocedure)) = 0,
          'F10: record_inventory_receipt_v1 no longer casts the pack size to integer');
select ok(position('v_today   := public.manila_today();' in (select prosrc from pg_proc where oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure)) > 0
      and position('v_today   := current_date;' in (select prosrc from pg_proc where oid = 'public.get_missed_cleanings(uuid,integer)'::regprocedure)) = 0,
          'F6: get_missed_cleanings counts days from the Manila date, not the UTC one');

-- Fixture ------------------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e9100000-0000-4000-8000-0000000000a1', 'Synthetic KPI', true);
insert into public.app_settings(key, value) values ('operating_start_date', '"2026-01-01"'::jsonb) on conflict (key) do update set value = excluded.value;

insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_name, checkin_date, checkout_date, guest_paid, host_service_fee, host_payout, source, created_at) values
 ('e9200000-0000-4000-8000-0000000000a1', 'e9100000-0000-4000-8000-0000000000a1', 'HMKPIA', 'confirmed', 'Ana A', pg_temp.mo(0),  pg_temp.mo(3),  3150, 150, 2850, 'airbnb', now() - interval '60 days'),
 ('e9200000-0000-4000-8000-0000000000a2', 'e9100000-0000-4000-8000-0000000000a1', 'HMKPIB', 'confirmed', 'Ben B', pg_temp.mo(4),  pg_temp.mo(6),  2100, 300, 1500, 'airbnb', timestamptz '2026-03-04 20:30:00+00'),
 ('e9200000-0000-4000-8000-0000000000a4', 'e9100000-0000-4000-8000-0000000000a1', 'HMKPID', 'confirmed', 'Dee D', pg_temp.mo(10), pg_temp.mo(12), 3000, 450, 2550, 'airbnb', now() - interval '50 days'),
 ('e9200000-0000-4000-8000-0000000000a5', 'e9100000-0000-4000-8000-0000000000a1', 'HMKPIE', 'cancelled', 'Eve E', pg_temp.mo(14), pg_temp.mo(19), 5000, 300, 4700, 'airbnb', now() - interval '40 days');
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, source, status, total_amount) values
 ('e9300000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000a1', 'Cy C',          '0000000000', pg_temp.mo(7), pg_temp.mo(8), 'direct', 'confirmed', 1780),
 ('e9300000-0000-4000-8000-0000000000f1', 'e9100000-0000-4000-8000-0000000000a1', 'Synthetic F (test, ignore)', '0000000000', pg_temp.mo(pg_temp.days() + 2), pg_temp.mo(pg_temp.days() + 3), 'direct', 'cancelled', 1780);
-- the mirror row that canonical_booking_decision / inquiry_one_tap write for the confirmed direct stay C
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_name, checkin_date, checkout_date, source, host_payout) values
 ('e9200000-0000-4000-8000-0000000000a6', 'e9100000-0000-4000-8000-0000000000a1', 'DIRECT:e9300000-0000-4000-8000-0000000000c1', 'confirmed', 'Cy C', pg_temp.mo(7), pg_temp.mo(8), 'direct', null);
insert into public.airbnb_transactions(property_id, confirmation_code, row_type, txn_date, row_hash, gross_earnings, cleaning_fee, booking_date) values
 ('e9100000-0000-4000-8000-0000000000a1', 'HMKPIA', 'reservation', pg_temp.mo(0),  'kpi-fixture-a',  3000, 0, pg_temp.mo(-30)),
 ('e9100000-0000-4000-8000-0000000000a1', 'HMKPID', 'reservation', pg_temp.mo(10), 'kpi-fixture-d1', 1000, 0, pg_temp.mo(-20)),
 ('e9100000-0000-4000-8000-0000000000a1', 'HMKPID', 'reservation', pg_temp.mo(11), 'kpi-fixture-d2', 2000, 0, pg_temp.mo(-20));
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, payee_name, external_ref, income_stage, reservation_id, booking_id) values
 ('e9400000-0000-4000-8000-0000000000a1', 'e9100000-0000-4000-8000-0000000000a1', 'income',  'airbnb_income', 'confirmed', 'airbnb_payout_email', pg_temp.mo(8),  1500, 'Airbnb', 'HMKPIB', 'confirmed', 'e9200000-0000-4000-8000-0000000000a2', null),
 ('e9400000-0000-4000-8000-0000000000a2', 'e9100000-0000-4000-8000-0000000000a1', 'income',  'airbnb_income', 'confirmed', 'airbnb_payout_email', pg_temp.mo(14), 2550, 'Airbnb', 'HMKPID', 'confirmed', 'e9200000-0000-4000-8000-0000000000a4', null),
 ('e9400000-0000-4000-8000-0000000000a3', 'e9100000-0000-4000-8000-0000000000a1', 'income',  'airbnb_income', 'confirmed', 'airbnb_email',        pg_temp.mo(3),  3000, 'Airbnb', 'HMKPIA', 'estimated', null, null),
 ('e9400000-0000-4000-8000-0000000000a4', 'e9100000-0000-4000-8000-0000000000a1', 'income',  'direct_income', 'confirmed', 'direct_booking',      pg_temp.mo(7),  1780, 'Cy C',   null,       'confirmed', null, 'e9300000-0000-4000-8000-0000000000c1'),
 ('e9400000-0000-4000-8000-0000000000b1', 'e9100000-0000-4000-8000-0000000000a1', 'expense', 'cleaning',      'confirmed', 'cleaner_fee',         pg_temp.mo(3),  650,  'Fixture cleaner', null, 'confirmed', null, null),
 ('e9400000-0000-4000-8000-0000000000b2', 'e9100000-0000-4000-8000-0000000000a1', 'expense', 'cleaning',      'confirmed', 'cleaner_fee',         pg_temp.mo(6),  650,  'Fixture cleaner', null, 'confirmed', null, null),
 ('e9400000-0000-4000-8000-0000000000b3', 'e9100000-0000-4000-8000-0000000000a1', 'expense', 'cleaning',      'confirmed', 'cleaner_fee',         pg_temp.mo(12), 650,  'Fixture cleaner', null, 'confirmed', null, null),
 ('e9400000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000a1', 'drawing', 'owner_drawing', 'confirmed', 'manual',              pg_temp.mo(20), 2300, 'Owner',  null,       'confirmed', null, null);
insert into public.cleaning_sessions(id, property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, fee_amount, fee_paid_at, fee_txn_id) values
 ('e9500000-0000-4000-8000-0000000000b1', 'e9100000-0000-4000-8000-0000000000a1', 'zz-kpi-1', 'Fixture', pg_temp.mo(3)::timestamptz + interval '12 hours',  'turnover', 650, pg_temp.mo(3)::timestamptz,  'e9400000-0000-4000-8000-0000000000b1'),
 ('e9500000-0000-4000-8000-0000000000b2', 'e9100000-0000-4000-8000-0000000000a1', 'zz-kpi-2', 'Fixture', pg_temp.mo(6)::timestamptz + interval '12 hours',  'turnover', 650, pg_temp.mo(6)::timestamptz,  'e9400000-0000-4000-8000-0000000000b2'),
 ('e9500000-0000-4000-8000-0000000000b3', 'e9100000-0000-4000-8000-0000000000a1', 'zz-kpi-3', 'Fixture', pg_temp.mo(12)::timestamptz + interval '12 hours', 'turnover', 650, pg_temp.mo(12)::timestamptz, 'e9400000-0000-4000-8000-0000000000b3');

create temp table pids on commit drop as select 'e9100000-0000-4000-8000-0000000000a1'::uuid p;
create function pg_temp.core() returns jsonb language sql as $$ select public.hospitality_metrics_core_v1((select p from pids), (select m from fx), (select (m + interval '1 month')::date from fx), true) -> 'metrics' $$;
create function pg_temp.rec() returns jsonb language sql as $$ select public.kpi_reconcile_v1((select p from pids), (select m from fx)) $$;

-- F1, F2, F7: the stays ----------------------------------------------------------------------------------------------------------------------------------------
select is((select count(*) from public.admin_stays_v1((select p from pids)) where guest_name in ('Cy C')), 1::bigint, 'F1: the confirmed direct stay C is one stay, not two (its DIRECT: mirror is skipped)');
select is((select count(*) from public.admin_stays_v1((select p from pids)) where code like 'DIRECT:%'), 0::bigint, 'F1: no stay carries a DIRECT: code');
select is((select accommodation_total from public.admin_stays_v1((select p from pids)) where code = 'HMKPID'), 3000.00, 'F2: the split payout rows are summed (1,000 + 2,000), not the larger one');
select is((select booking_created from public.admin_stays_v1((select p from pids)) where code = 'HMKPIB'), date '2026-03-05', 'F7: a stay with no export row dates its booking from created_at on the Manila clock (2026-03-04 20:30Z is 03-05 04:30 Manila)');

-- Golden numbers ----------------------------------------------------------------------------------------------------------------------------------------------
select is((pg_temp.core() -> 'sold_nights' ->> 'value')::integer, 8, 'golden: 8 sold nights (3 + 2 + 1 + 2; the cancelled stay and the cancelled inquiry are out)');
select is((pg_temp.core() -> 'occupancy' ->> 'value')::numeric, round(800.0 / pg_temp.days(), 2), 'golden: occupancy is 8 over the days of the month');
select is((pg_temp.core() -> 'accommodation_revenue' ->> 'value')::numeric, 9580.00, 'golden: accommodation revenue 3,000 + 1,800 + 1,780 + 3,000');
select is(pg_temp.core() -> 'accommodation_revenue' ->> 'coverage', 'complete', 'golden: revenue coverage is complete');
select is((pg_temp.core() -> 'adr' ->> 'value')::numeric, 1197.50, 'golden: ADR 9,580 over 8 nights');
select is((pg_temp.core() -> 'revpar' ->> 'value')::numeric, round(9580.0 / pg_temp.days(), 2), 'golden: RevPAR is revenue over the month capacity');
select is((pg_temp.core() -> 'cash_received' ->> 'value')::numeric, 5830.00, 'golden: cash received 1,500 + 2,550 + 1,780; the airbnb_email estimate is not cash');
select is((pg_temp.core() -> 'average_length_of_stay' ->> 'value')::numeric, 2.00, 'golden: ALOS 2.00');
select is((pg_temp.core() -> 'cancellation_rate' ->> 'value')::numeric, 20.00, 'golden: cancellation 1 of 5 arrivals (the mirror is not a sixth)');

-- F3: the Telegram /summary -----------------------------------------------------------------------------------------------------------------------------------
select is((public.get_finance_summary((select m from fx), (select p from pids)) ->> 'income')::numeric, 5830.00, 'F3: finance income is 5,830; the 3,000 Airbnb estimate is not income received');
select is((public.get_finance_summary((select m from fx), (select p from pids)) ->> 'expenses')::numeric, 1950.00, 'F3: expenses are the three cleaner fees');
select is((public.get_finance_summary((select m from fx), (select p from pids)) ->> 'drawings')::numeric, 2300.00, 'F3: the drawing is reported');
select is((public.get_finance_summary((select m from fx), (select p from pids)) ->> 'net')::numeric, 1580.00, 'F3: net is income less expenses less drawings');

-- The recompute -----------------------------------------------------------------------------------------------------------------------------------------------
select is(public.kpi_recompute_v1((select p from pids), (select m from fx), (select (m + interval '1 month')::date from fx)) - 'adr' - 'cash_received' - 'cleaner_fee_ledger' - 'cleaner_fee_sessions',
          '{"sold_nights": 8, "revenue": 9580.00, "revenue_nights": 8, "revenue_missing_nights": 0, "pay_request_line_drift": 0, "pay_request_line_drift_ids": [], "direct_mirror_dups": 1,
            "confirmed_estimates_dead": 0, "confirmed_estimates_dead_refs": [], "split_payout_stays": 1}'::jsonb,
          'recompute: sold 8, revenue 9,580.00, one mirror and one split-payout stay on record, nothing dead, no drifting pay request');
select is((public.kpi_recompute_v1((select p from pids), (select m from fx), (select (m + interval '1 month')::date from fx)) ->> 'cleaner_fee_ledger')::numeric, 1950.00, 'recompute: cleaner fees in the ledger 1,950');
select is((public.kpi_recompute_v1((select p from pids), (select m from fx), (select (m + interval '1 month')::date from fx)) ->> 'cleaner_fee_sessions')::numeric, 1950.00, 'recompute: cleaner fees on the sessions 1,950');

-- Reconcile: clean --------------------------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.rec(), '[]'::jsonb, 'kpi_reconcile_v1 returns nothing on the fixture once F1 to F3 are in');
select is(public.kpi_reconcile_window_v1((select p from pids), ((select m from fx) + interval '1 month')::date), '[]'::jsonb, 'the four-month window is clean too (the older months are empty on both sides)');
select is((select count(*) from jsonb_array_elements(public.run_system_verifier_v1((select p from pids), 'daily', now()) -> 'found') e where e ->> 'check_id' = 'V19'), 0::bigint,
          'the daily verifier raises no V19 on a clean month');
select is((select to_jsonb(h) ->> 'status' from jsonb_array_elements(public.health_checks_core_v1((select p from pids), true) -> 'checks') h where h ->> 'check_key' = 'kpi_reconciled'),
          'pass', 'health: kpi_reconciled passes');
select is((select count(*) from jsonb_array_elements(public.health_checks_core_v1((select p from pids), false) -> 'checks') e where e ->> 'check_key' = 'kpi_reconciled'), 0::bigint,
          'health: kpi_reconciled is a finance row, withheld from a caller without finance');

-- The owner (aal2) sees the same numbers through the public RPC ----------------------------------------------------------------------------------------------
insert into auth.users(id) values ('e9a00000-0000-4000-8000-0000000000a1');
insert into public.staff_access_profiles(user_id, role) values ('e9a00000-0000-4000-8000-0000000000a1', 'owner');
select set_config('request.jwt.claims', json_build_object('sub', 'e9a00000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
grant select on fx, pids to authenticated;
select set_config('role', 'authenticated', true);
select is((public.get_hospitality_metrics_v1((select p from pids), (select m from fx), (select (m + interval '1 month')::date from fx)) -> 'metrics' -> 'accommodation_revenue' ->> 'value')::numeric, 9580.00,
          'the public RPC returns the core numbers to a finance-authorised owner');
reset role;
select set_config('request.jwt.claims', '{}', true);

-- Hygiene: cancel A, its confirmed estimate is now dead ------------------------------------------------------------------------------------------------------
update public.airbnb_reservations set status = 'cancelled' where id = 'e9200000-0000-4000-8000-0000000000a1';
select is(pg_temp.keys(pg_temp.rec()), 'V19:hygiene:confirmed_estimates_dead', 'cancelling A leaves exactly one finding: the hygiene count (the KPIs still agree with the books)');
select is((pg_temp.rec() -> 0 ->> 'severity') || '/' || (pg_temp.rec() -> 0 -> 'detail' ->> 'n') || '/' || (pg_temp.rec() -> 0 -> 'detail' -> 'rows' ->> 0), 'yellow/1/HMKPIA', 'it is yellow, n = 1, and names the stay code');
select is((select count(*) from jsonb_array_elements(public.run_system_verifier_v1((select p from pids), 'daily', now()) -> 'found') e where e ->> 'key' = 'V19:hygiene:confirmed_estimates_dead'), 1::bigint,
          'the daily verifier carries it once, even though four months were checked');
select is((select count(*) from jsonb_array_elements(public.run_system_verifier_v1((select p from pids), 'hourly', now()) -> 'found') e where e ->> 'check_id' = 'V19'), 0::bigint,
          'the hourly verifier does not run V19');
select is((select (to_jsonb(h) ->> 'status') from jsonb_array_elements(public.health_checks_core_v1((select p from pids), true) -> 'checks') h where h ->> 'check_key' = 'kpi_reconciled'), 'warn',
          'health: a yellow-only reconcile is a warn');
-- V19 is a daily check: an hourly run does not resolve it, a daily run that no longer sees it does
select is((select jsonb_array_length(public.apply_verifier_run_v1('daily', pg_temp.rec(), now() - interval '2 hours') -> 'new')), 1, 'apply: a V19 finding is stored and announced');
select ok(not coalesce((select bool_or(e ->> 'key' = 'V19:hygiene:confirmed_estimates_dead') from jsonb_array_elements(public.apply_verifier_run_v1('hourly', '[]'::jsonb, now() - interval '1 hour') -> 'resolved') e), false), 'apply: an hourly run leaves V19 alone');
select ok(coalesce((select bool_or(e ->> 'key' = 'V19:hygiene:confirmed_estimates_dead') from jsonb_array_elements(public.apply_verifier_run_v1('daily', '[]'::jsonb, now()) -> 'resolved') e), false), 'apply: a daily run that no longer sees it resolves it');

-- Drift: the shown side moves by +100 revenue -----------------------------------------------------------------------------------------------------------------
update public.airbnb_reservations set status = 'confirmed' where id = 'e9200000-0000-4000-8000-0000000000a1';
alter function public.kpi_recompute_v1(uuid, date, date) rename to kpi_recompute_real_v1;
create function public.kpi_recompute_v1(p_property_id uuid, p_start date, p_end_exclusive date) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_set(r, '{revenue}', to_jsonb((r ->> 'revenue')::numeric - 100)) from (select public.kpi_recompute_real_v1(p_property_id, p_start, p_end_exclusive) r) x $$;
discard plans;
select is((select e -> 'detail' ->> 'diff' from jsonb_array_elements(pg_temp.rec()) e where e ->> 'key' like '%:accommodation_revenue'), '100.00', 'drift: the revenue the page shows is 100.00 above the books, and V19 says so');
select is((select string_agg(distinct e ->> 'severity', ',') from jsonb_array_elements(pg_temp.rec()) e), 'red', 'drift: every finding is red');
select ok(not exists (select 1 from jsonb_array_elements(pg_temp.rec()) e where e ->> 'key' ~ ':(sold_nights|occupancy|cash_received|finance_summary_income|cleaner_fee)$'), 'drift: nights, occupancy and cash are not blamed');
select is((select (to_jsonb(h) ->> 'status') from jsonb_array_elements(public.health_checks_core_v1((select p from pids), true) -> 'checks') h where h ->> 'check_key' = 'kpi_reconciled'), 'fail', 'health: a red reconcile fails the row');

select * from finish();
rollback;
