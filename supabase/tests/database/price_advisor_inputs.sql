-- Session 72, SPEC-35: price_advisor_inputs_v1(property, from, to). Read-only inputs for the price advisor.
-- Synthetic properties A (data), B (another property: must never leak into A), C (no history at all), an owner (aal2) and a cleaner.
-- Every expected number is worked by hand in the comment beside the fixture. Inside begin/rollback.
-- Target months are Feb-Mar 2026 so the trailing window (2025-02-01 to 2026-02-01) never moves with the clock; last year is Feb-Mar 2025.
-- Reservations are inserted as 'confirmed': the advisor treats confirmed and completed alike, and completed past stays would fire the
-- income reconciler (ensure_income_transaction), which is not what is under test.
begin;
select plan(55);

select ok((select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.price_advisor_inputs_v1(uuid,date,date)'::regprocedure), 'security definer with an empty search_path');
select ok(not has_function_privilege('anon', 'public.price_advisor_inputs_v1(uuid,date,date)', 'execute'), 'anon cannot call it');
select ok(has_function_privilege('authenticated', 'public.price_advisor_inputs_v1(uuid,date,date)', 'execute'), 'authenticated can call it');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'public.price_advisor_inputs_v1(uuid,date,date)'::regprocedure and a.grantee = 0), 'PUBLIC has no execute grant');
select is((select provolatile::text from pg_proc where oid = 'public.price_advisor_inputs_v1(uuid,date,date)'::regprocedure), 's', 'the function is STABLE (it only reads)');

insert into public.properties(id, name, is_active) values
  ('e7500000-0000-4000-8000-0000000000a1', 'Synthetic Advisor A', true),
  ('e7500000-0000-4000-8000-0000000000a2', 'Synthetic Advisor B', true),
  ('e7500000-0000-4000-8000-0000000000a3', 'Synthetic Advisor C empty', true);
insert into auth.users(id) values ('e7600000-0000-4000-8000-0000000000a1'), ('e7600000-0000-4000-8000-0000000000a2');
insert into public.staff_access_profiles(user_id, role) values ('e7600000-0000-4000-8000-0000000000a1', 'owner'), ('e7600000-0000-4000-8000-0000000000a2', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values ('e7600000-0000-4000-8000-0000000000a2', 'e7500000-0000-4000-8000-0000000000a1');

-- Property A, last year Feb-Mar 2025 (night = the date a guest sleeps; a stay 03 -> 08 holds nights 3,4,5,6,7).
insert into public.airbnb_reservations(property_id, confirmation_code, status, checkin_date, checkout_date, nights, guest_paid, host_service_fee, host_payout) values
  ('e7500000-0000-4000-8000-0000000000a1', 'ZADV1', 'confirmed', '2025-02-03', '2025-02-08', 5, 8500, 1000, 7000),   -- Feb nights 3-7 = 5; pays 7000 / 5 = 1400 a night
  ('e7500000-0000-4000-8000-0000000000a1', 'ZADV2', 'confirmed', '2025-02-21', '2025-02-23', 2, null, null, null),   -- Feb nights 21,22 = 2 (Friday and Saturday: a weekend night counts like any other); payout UNKNOWN (null, not 0)
  ('e7500000-0000-4000-8000-0000000000a1', 'ZADV3', 'confirmed', '2025-03-30', '2025-04-02', 3, 3500, 500, 3000),    -- Mar nights 30,31 = 2 (Apr 1 is April); 3000 / 3 = 1000 a night
  ('e7500000-0000-4000-8000-0000000000a1', 'ZADV4', 'cancelled', '2025-02-25', '2025-02-27', 2, null, null, null),   -- cancelled: counts for nothing
  ('e7500000-0000-4000-8000-0000000000a2', 'ZADV5', 'confirmed', '2025-02-12', '2025-02-14', 2, 1100, 99, 999);     -- property B: must not reach A
-- One direct stay recorded twice (inquiry + calendar row): nights 10,11 = 2, counted once.
insert into public.booking_inquiries(property_id, guest_name, guest_phone, checkin_date, checkout_date, source, status, total_amount)
  values ('e7500000-0000-4000-8000-0000000000a1', 'Synthetic Guest', '0000000000', '2025-02-10', '2025-02-12', 'direct', 'confirmed', 3000);
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, block_reason, block_reason_source) values
  ('e7500000-0000-4000-8000-0000000000a1', 'adv-direct-1',      'direct',  'confirmed', '2025-02-10', '2025-02-12', null, null),
  ('e7500000-0000-4000-8000-0000000000a1', 'adv-direct-only',   'manual',  'confirmed', '2025-03-10', '2025-03-12', null, null),       -- direct stay with NO inquiry: Mar nights 10,11 = 2
  ('e7500000-0000-4000-8000-0000000000a1', 'adv-direct-canc',   'direct',  'cancelled', '2025-03-20', '2025-03-22', null, null),       -- cancelled: counts for nothing
  ('e7500000-0000-4000-8000-0000000000a2', 'adv-direct-b',      'direct',  'confirmed', '2025-03-10', '2025-03-12', null, null),       -- property B's own calendar-only stay
  ('e7500000-0000-4000-8000-0000000000a1', 'adv-brown-ly',      'airbnb',  'blocked',   '2025-02-14', '2025-02-16', 'brownout', 'auto'),       -- held nights 14,15 = 2
  ('e7500000-0000-4000-8000-0000000000a1', 'adv-maint-assumed', 'airbnb',  'blocked',   '2025-02-17', '2025-02-18', 'maintenance', 'assumed'), -- only assumed: stays sellable
  ('e7500000-0000-4000-8000-0000000000a1', 'adv-other',         'airbnb',  'blocked',   '2025-02-18', '2025-02-19', 'other', 'staff'),         -- "other" is not a hold
  ('e7500000-0000-4000-8000-0000000000a1', 'adv-owner-overlap', 'airbnb',  'blocked',   '2025-02-04', '2025-02-06', 'owner_use', 'auto'),      -- nights 4,5 are occupied by ZADV1: occupied only
  ('e7500000-0000-4000-8000-0000000000a1', 'adv-canc',          'airbnb',  'cancelled', '2025-02-27', '2025-02-28', 'brownout', 'auto'),       -- cancelled: no hold
  ('e7500000-0000-4000-8000-0000000000a1', 'adv-brown-ty',      'airbnb',  'blocked',   '2026-02-05', '2026-02-07', 'brownout', 'staff'),      -- this year: Feb 2026 held nights 5,6 = 2
  ('e7500000-0000-4000-8000-0000000000a2', 'adv-brown-b',       'airbnb',  'blocked',   '2025-02-24', '2025-02-26', 'brownout', 'auto');       -- property B
insert into public.acct_settings(property_id, accounting_start) values ('e7500000-0000-4000-8000-0000000000a1', '2025-06-01');
-- Expenses window = 2025-02-01 (inclusive) to 2026-02-01 (exclusive). Counted: E1, E2 (supplies 400 + 600 = 1000, 2 rows), E3, E9 (utilities 1500 + 500 = 2000).
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, payee_name, hidden_at) values
  ('e7700000-0000-4000-8000-0000000000e1', 'e7500000-0000-4000-8000-0000000000a1', 'expense', 'supplies',  'confirmed', 'manual', '2025-02-15', 400,  'Zz E1', null),   -- before accounting_start: an estimate
  ('e7700000-0000-4000-8000-0000000000e2', 'e7500000-0000-4000-8000-0000000000a1', 'expense', 'supplies',  'confirmed', 'manual', '2025-06-10', 600,  'Zz E2', null),
  ('e7700000-0000-4000-8000-0000000000e3', 'e7500000-0000-4000-8000-0000000000a1', 'expense', 'utilities', 'confirmed', 'manual', '2025-12-20', 1500, 'Zz E3', null),
  ('e7700000-0000-4000-8000-0000000000e4', 'e7500000-0000-4000-8000-0000000000a1', 'expense', 'supplies',  'void',      'manual', '2025-07-01', 9999, 'Zz E4 void', null),          -- void: ignored
  ('e7700000-0000-4000-8000-0000000000e5', 'e7500000-0000-4000-8000-0000000000a1', 'expense', 'supplies',  'confirmed', 'manual', '2026-02-01', 777,  'Zz E5 after the window', null), -- window end is exclusive
  ('e7700000-0000-4000-8000-0000000000e6', 'e7500000-0000-4000-8000-0000000000a1', 'income',  'direct_income', 'confirmed', 'manual', '2025-03-01', 5000, 'Zz E6 income', null), -- income: ignored
  ('e7700000-0000-4000-8000-0000000000e7', 'e7500000-0000-4000-8000-0000000000a1', 'expense', 'loan',      'confirmed', 'manual', '2025-01-31', 888,  'Zz E7 before the window', null),
  ('e7700000-0000-4000-8000-0000000000e8', 'e7500000-0000-4000-8000-0000000000a2', 'expense', 'supplies',  'confirmed', 'manual', '2025-03-01', 123,  'Zz E8 property B', null),
  ('e7700000-0000-4000-8000-0000000000e9', 'e7500000-0000-4000-8000-0000000000a1', 'expense', 'utilities', 'confirmed', 'manual', '2025-04-04', 500,  'Zz E9 hidden', now());       -- hidden is display only: still counts

create function pg_temp.adv(p uuid, f date, t date) returns jsonb language sql as $$ select public.price_advisor_inputs_v1(p, f, t) $$;
-- month i (0 = Feb 2026, 1 = Mar 2026) field k, as text
create function pg_temp.f(p uuid, i int, k text) returns text language sql as $$ select pg_temp.adv(p, date '2026-02-01', date '2026-03-31')->'months'->i->>k $$;
-- top-level / nested field by path
create function pg_temp.g(p uuid, path text[]) returns text language sql as $$ select pg_temp.adv(p, date '2026-02-01', date '2026-03-31') #>> path $$;

-- Permissions.
select set_config('request.jwt.claims', json_build_object('sub', 'e7600000-0000-4000-8000-0000000000a2', 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select throws_ok($$select public.price_advisor_inputs_v1('e7500000-0000-4000-8000-0000000000a1', date '2026-02-01', date '2026-03-31')$$, '42501', 'read_finance denied', 'a cleaner is refused');
select set_config('request.jwt.claims', json_build_object('sub', 'e7600000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'aal', 'aal1', 'app_metadata', json_build_object('role', 'owner'), 'iat', extract(epoch from now())::bigint)::text, true);
select lives_ok($$select public.price_advisor_inputs_v1('e7500000-0000-4000-8000-0000000000a1', date '2026-02-01', date '2026-03-31')$$, 'an owner on a password session is allowed (D-094: aal no longer gates)');
select set_config('request.jwt.claims', json_build_object('sub', 'e7600000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'aal', 'aal2', 'app_metadata', json_build_object('role', 'owner'), 'iat', extract(epoch from now())::bigint)::text, true);

-- Property A, target Feb 2026 (index 0) and Mar 2026 (index 1).
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['from']), '2026-02-01', 'the range starts on the first of the month');
select is(jsonb_array_length(pg_temp.adv('e7500000-0000-4000-8000-0000000000a1', date '2026-02-15', date '2026-03-02')->'months'), 2, 'Feb 15 to Mar 2 is two calendar months');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 0, 'days'), '28', 'Feb 2026 has 28 days');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 0, 'held_nights'), '2', 'Feb 2026 holds 2 nights (brownout 5 and 6)');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 1, 'held_nights'), '0', 'Mar 2026 holds none');
-- Last-year Feb 2025: history starts 2025-02-03, so days 3..28 are known = 26.
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 0, 'ly_days_covered'), '26', 'last Feb is known from the 3rd: 26 days');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 0, 'ly_airbnb_nights'), '7', 'last Feb Airbnb nights: 5 (ZADV1) + 2 (ZADV2) = 7; the cancelled stay and property B add nothing');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 0, 'ly_direct_nights'), '2', 'last Feb direct nights: the inquiry and its calendar row are one stay of 2 nights');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 0, 'ly_held_nights'), '2', 'last Feb held: brownout 14,15 only (assumed, "other", cancelled and an occupied night do not hold)');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 0, 'ly_stays'), '3', 'last Feb stays: ZADV1, ZADV2 and the direct stay');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 0, 'ly_payout_total')::numeric, 7000::numeric, 'last Feb payout: only ZADV1 has a figure (the unknown stay is left out, not counted as 0)');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 0, 'ly_paid_nights'), '5', 'last Feb nights that carry a payout: 5');
-- Last-year Mar 2025: 31 known days; ZADV3 sleeps Mar 30, 31 (and Apr 1).
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 1, 'ly_days_covered'), '31', 'last Mar is fully known: 31 days');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 1, 'ly_airbnb_nights'), '2', 'last Mar Airbnb nights: 30 and 31 = 2');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 1, 'ly_direct_nights'), '2', 'last Mar direct nights: the calendar-only stay, nights 10 and 11 = 2');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 1, 'ly_held_nights'), '0', 'last Mar held nights: 0');
-- ly_stays Mar 2025 = Airbnb ZADV3 (1) + confirmed inquiries (0) + calendar-only direct stays with no matching inquiry (adv-direct-only = 1; the cancelled row and property B's row add 0) = 2.
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 1, 'ly_stays'), '2', 'last Mar stays: ZADV3 + the direct stay that exists only as a calendar row');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a2', 1, 'ly_stays'), '1', 'property B counts only its own calendar-only stay in last Mar');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 1, 'ly_payout_total')::numeric, 2000::numeric, 'last Mar payout: 2 nights at 3000 / 3 = 1000');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a1', 1, 'ly_paid_nights'), '2', 'last Mar nights that carry a payout: 2');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['history_start']), '2025-02-03', 'history starts at the first confirmed stay');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['accounting_start']), '2025-06-01', 'accounting_start is passed through');
-- Fee: ZADV1 and ZADV3 have both figures. fee / (payout + fee) = (1000 + 500) / (7000 + 3000 + 1500) = 1500 / 11500 = 0.1304.
select is(round(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['airbnb_fee', 'rate'])::numeric, 4), 0.1304::numeric, 'observed Airbnb fee = 1500 / 11500');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['airbnb_fee', 'stays']), '2', 'the fee comes from 2 stays');
-- Expenses.
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['expenses', 'window_start']), '2025-02-01', 'expense window starts 12 months before the first target month');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['expenses', 'window_end']), '2026-02-01', 'expense window ends before the first target month');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['expenses', 'months_covered']), '12', 'first expense Feb 2025 to the window end = 12 months');
select is((select array_agg(c->>'category' order by c->>'category') from jsonb_array_elements(pg_temp.adv('e7500000-0000-4000-8000-0000000000a1', date '2026-02-01', date '2026-03-31')->'expenses'->'categories') c),
  array['supplies', 'utilities'], 'categories: void, income, out-of-window and other-property rows add none (no loan, no direct_income)');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['expenses', 'categories', '0', 'total'])::numeric, 1000::numeric, 'supplies = 400 + 600 (void 9999 and the 2026-02-01 row left out)');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['expenses', 'categories', '1', 'total'])::numeric, 2000::numeric, 'utilities = 1500 + 500 (a hidden row still counts)');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['expenses', 'categories', '0', 'rows']), '2', 'supplies has 2 rows');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['expenses', 'categories', '0', 'estimate_total'])::numeric, 400::numeric, 'supplies before accounting_start (2025-06-01) = 400, an estimate');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a1', array['expenses', 'categories', '1', 'estimate_total'])::numeric, 500::numeric, 'utilities before accounting_start = 500 (April 2025)');
select is((select sum((c->>'total')::numeric) from jsonb_array_elements(pg_temp.adv('e7500000-0000-4000-8000-0000000000a1', date '2026-02-01', date '2026-03-31')->'expenses'->'categories') c), 3000::numeric, 'all categories together = 3000');

-- Property C has no history at all: everything unknown is null, never 0.
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a3', 0, 'ly_days_covered'), '0', 'empty property: no known days');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a3', 0, 'ly_airbnb_nights'), null, 'empty property: Airbnb nights are unknown (null)');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a3', 0, 'ly_payout_total'), null, 'empty property: payout is unknown (null)');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a3', array['history_start']), null, 'empty property: no history start');
select is(jsonb_array_length(pg_temp.adv('e7500000-0000-4000-8000-0000000000a3', date '2026-02-01', date '2026-03-31')->'expenses'->'categories'), 0, 'empty property: no expense categories');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a3', array['expenses', 'months_covered']), null, 'empty property: expense months are unknown (null)');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a3', array['airbnb_fee', 'rate']), null, 'empty property: no observed fee (null)');

-- Property B only sees itself. History starts 2025-02-12, so Feb 12..28 = 17 known days.
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a2', 0, 'ly_airbnb_nights'), '2', 'property B sees its own 2 Airbnb nights (12, 13), none of the other property''s');
select is(pg_temp.f('e7500000-0000-4000-8000-0000000000a2', 0, 'ly_days_covered'), '17', 'property B has its own history start (17 known days)');
select is(pg_temp.g('e7500000-0000-4000-8000-0000000000a2', array['expenses', 'categories', '0', 'total'])::numeric, 123::numeric, 'property B sees only its own expense (123)');

-- Range checks.
select throws_ok($$select public.price_advisor_inputs_v1('e7500000-0000-4000-8000-0000000000a1', date '2026-03-31', date '2026-02-01')$$, '22023', null, 'to before from is refused');
select throws_ok($$select public.price_advisor_inputs_v1('e7500000-0000-4000-8000-0000000000a1', date '2026-02-01', date '2027-02-28')$$, '22023', 'at most 12 months at a time', '13 months are refused');
select throws_ok($$select public.price_advisor_inputs_v1('e7500000-0000-4000-8000-0000000000a1', null, date '2027-02-28')$$, '22023', null, 'a null date is refused');
select is(jsonb_array_length(pg_temp.adv('e7500000-0000-4000-8000-0000000000a1', date '2026-02-01', date '2027-01-31')->'months'), 12, '12 months are allowed');

reset role;
select * from finish();
rollback;
