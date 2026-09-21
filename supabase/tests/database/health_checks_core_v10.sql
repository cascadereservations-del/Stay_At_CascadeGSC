-- SPEC-11 session 1 steps 1 and 3: the health-check core, and V10.
--
-- The move itself is proved by hash, not by this file. md5(prosrc) of
-- health_checks_core_v1 is asserted as a forward check in the release contract,
-- because an equality test between the two wrappers CANNOT catch a mistyped
-- body: both wrappers read the same body, so both would be wrong together and
-- agree perfectly. What this file proves is the half a hash cannot - that the
-- gate still gates, that p_fin is really threaded through to the four financial
-- checks, and that V10 turns a non-passing check into a finding exactly once.
--
-- Every fixture is created inside this transaction and disappears with the
-- closing rollback, so CI's empty baseline database (B103) is enough.
--
-- aal is ignored since D-094, so the finance split here is by ROLE: an admin
-- holds read_finance, an inspector holds read_operations without it. That is
-- also why the cleaner assertion withholds PROPERTY access rather than relying
-- on the role - since 20260913130000 a cleaner does hold read_operations, and a
-- test written against the older matrix would have passed for the wrong reason.

begin;
select plan(27);

-- Catalogue -------------------------------------------------------------------
select has_function('public', 'health_checks_core_v1', array['uuid','boolean'], 'the core exists');
select has_function('public', 'run_health_checks_service_v1', array['uuid'], 'the service wrapper exists');
select is_definer('public', 'health_checks_core_v1', array['uuid','boolean'], 'the core is security definer');

-- anon has to be revoked BY NAME. Supabase grants EXECUTE on every new function
-- to anon by default, and `revoke all ... from public` does not take it away.
select ok(not has_function_privilege('anon', 'public.health_checks_core_v1(uuid,boolean)', 'execute')
      and not has_function_privilege('authenticated', 'public.health_checks_core_v1(uuid,boolean)', 'execute'),
  'the core is reachable through a wrapper or not at all');
select ok(has_function_privilege('service_role', 'public.run_health_checks_service_v1(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.run_health_checks_service_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.run_health_checks_service_v1(uuid)', 'execute'),
  'only a scheduled job may ask with finance already true');
select ok(has_function_privilege('authenticated', 'public.run_health_checks_v1(uuid)', 'execute'),
  'the dashboard button is untouched: authenticated still holds EXECUTE');

-- Fixtures --------------------------------------------------------------------
insert into public.properties(id, name, is_active)
values ('e1000000-0000-4000-8000-000000000001', 'Synthetic Health Property', true) on conflict(id) do nothing;

-- staff_access_profiles.user_id is a foreign key into auth.users, so the three
-- staff have to exist as users before they can have a role. CI caught this:
-- without it the file aborts after the sixth assertion having planned 27.
insert into auth.users(id) values
  ('e2000000-0000-4000-8000-00000000000a'),
  ('e2000000-0000-4000-8000-00000000000b'),
  ('e2000000-0000-4000-8000-00000000000c');

insert into public.staff_access_profiles(user_id, role) values
  ('e2000000-0000-4000-8000-00000000000a', 'admin'),
  ('e2000000-0000-4000-8000-00000000000b', 'inspector'),
  ('e2000000-0000-4000-8000-00000000000c', 'cleaner');

-- The cleaner deliberately gets NO property access row; that is what denies her.
insert into public.staff_property_access(user_id, property_id) values
  ('e2000000-0000-4000-8000-00000000000a', 'e1000000-0000-4000-8000-000000000001'),
  ('e2000000-0000-4000-8000-00000000000b', 'e1000000-0000-4000-8000-000000000001');

-- The move ---------------------------------------------------------------------
-- The core's answer is taken first, as postgres, and parked where the two
-- wrapper calls below can be compared against it. The wrappers have to run as
-- `authenticated` and the core is not callable by that role, so the comparison
-- cannot happen inside one statement.
--
-- Eleven checks, not the spec's ten: 20260916150000 added concierge_handoffs_open
-- after SPEC-11 was written. Four of the eleven are financial.
create temp table hc_expected(fin boolean primary key, checks jsonb);
insert into hc_expected
select true, (select jsonb_agg(e - 'ran_at' - 'ran_by' order by e->>'check_key')
                from jsonb_array_elements(
                  public.health_checks_core_v1('e1000000-0000-4000-8000-000000000001', true)->'checks') e);
grant select on hc_expected to authenticated;

set local role authenticated;
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-00000000000a","aal":"aal2"}';

select is(
  (select jsonb_array_length(public.run_health_checks_v1('e1000000-0000-4000-8000-000000000001')->'checks')),
  11, 'an admin sees all eleven checks, finance included');

select is(
  (select jsonb_agg(e - 'ran_at' - 'ran_by' order by e->>'check_key')
     from jsonb_array_elements(public.run_health_checks_v1('e1000000-0000-4000-8000-000000000001')->'checks') e),
  (select checks from hc_expected where fin),
  'the button and the core with true return the same eleven checks');

reset role;

-- Now the same property through an inspector: read_operations without
-- read_finance. The four financial rows EXIST in the table by this point, put
-- there by the runs above, so this asserts the FILTER and not merely their
-- absence - which is the version of this test that could pass by accident.
insert into hc_expected
select false, (select jsonb_agg(e - 'ran_at' - 'ran_by' order by e->>'check_key')
                 from jsonb_array_elements(
                   public.health_checks_core_v1('e1000000-0000-4000-8000-000000000001', false)->'checks') e);

set local role authenticated;
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-00000000000b","aal":"aal2"}';

select is(
  (select jsonb_array_length(public.run_health_checks_v1('e1000000-0000-4000-8000-000000000001')->'checks')),
  7, 'an inspector sees seven: the four financial checks are withheld');
select is(
  (select count(*) from jsonb_array_elements(
      public.run_health_checks_v1('e1000000-0000-4000-8000-000000000001')->'checks') e
    where e->>'check_key' in ('cleaner_fees_settled','ledger_duplicates','ledger_position','journals_balanced')),
  0::bigint, 'and not one of the four is among them');
select is(
  (select jsonb_agg(e - 'ran_at' - 'ran_by' order by e->>'check_key')
     from jsonb_array_elements(public.run_health_checks_v1('e1000000-0000-4000-8000-000000000001')->'checks') e),
  (select checks from hc_expected where not fin),
  'p_fin is really threaded: the core with false matches what the inspector saw');

set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-00000000000c","aal":"aal2"}';
select throws_ok(
  $$select public.run_health_checks_v1('e1000000-0000-4000-8000-000000000001')$$,
  '42501', null, 'the gate still gates: no access to this property, no health checks');
reset role;

-- V10 ---------------------------------------------------------------------------
-- A chosen slate, written directly, so each status is deliberate rather than
-- whatever the empty baseline happens to produce.
delete from public.admin_health_check_runs where property_id = 'e1000000-0000-4000-8000-000000000001';
insert into public.admin_health_check_runs(property_id, check_key, label, status, count, detail, ran_at)
values
  ('e1000000-0000-4000-8000-000000000001', 'journals_balanced', 'Posted journals balance', 'pass', 0, '[]'::jsonb, '2026-10-10T09:00:00Z'),
  ('e1000000-0000-4000-8000-000000000001', 'payout_rows_linked', 'Payout e-mails linked to a stay', 'fail', 1, '[]'::jsonb, '2026-10-10T09:00:00Z'),
  ('e1000000-0000-4000-8000-000000000001', 'checkouts_cleaned', 'Checkouts (90 days) followed by a cleaning', 'warn', 3, '[]'::jsonb, '2026-10-10T09:00:00Z'),
  ('e1000000-0000-4000-8000-000000000001', 'ledger_duplicates', 'Duplicate ledger rows', 'warn', 2, '[]'::jsonb, '2026-10-10T09:00:00Z');

select is(
  (select count(*) from jsonb_array_elements(
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-10T10:00:00Z')->'found') e
    where e->>'check_id' = 'V10'),
  0::bigint, 'V10 is a daily check and says nothing on the hour');

select is(
  (select count(*) from jsonb_array_elements(
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'daily', '2026-10-10T10:00:00Z')->'found') e
    where e->>'check_id' = 'V10'),
  3::bigint, 'the three non-passing checks become three findings, and the passing one stays quiet');

select is(
  (select e->>'severity' from jsonb_array_elements(
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'daily', '2026-10-10T10:00:00Z')->'found') e
    where e->>'key' = 'V10:payout_rows_linked'),
  'red', 'a failing check is red');

select is(
  (select e->>'title' from jsonb_array_elements(
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'daily', '2026-10-10T10:00:00Z')->'found') e
    where e->>'key' = 'V10:checkouts_cleaned'),
  'Checkouts (90 days) followed by a cleaning',
  'a finding carries the check''s own label, so the card reads like the dashboard');

-- K16: ledger_duplicates n=2 is explained, not broken (D-124).
select is(
  (select e->'detail'->>'accepted' from jsonb_array_elements(
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'daily', '2026-10-10T10:00:00Z')->'found') e
    where e->>'key' = 'V10:ledger_duplicates'),
  'true', 'the accepted duplicate pair is marked accepted');

update public.admin_health_check_runs set count = 3
 where property_id = 'e1000000-0000-4000-8000-000000000001' and check_key = 'ledger_duplicates';
select is(
  (select e->'detail'->>'accepted' from jsonb_array_elements(
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'daily', '2026-10-10T10:00:00Z')->'found') e
    where e->>'key' = 'V10:ledger_duplicates'),
  null, 'a third duplicate is not what was accepted, and loses the mark');
update public.admin_health_check_runs set count = 2
 where property_id = 'e1000000-0000-4000-8000-000000000001' and check_key = 'ledger_duplicates';

-- Applying the run: accepted is born acknowledged and is never announced.
select lives_ok(
  $$select public.apply_verifier_run_v1('daily',
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'daily', '2026-10-10T10:00:00Z')->'found',
      '2026-10-10T10:00:00Z')$$,
  'a daily run records itself');

select is(
  (select status from public.verifier_findings where key = 'V10:ledger_duplicates'),
  'acknowledged', 'K16 is stored acknowledged, so it never wakes anyone at 07:45');
select is(
  (select status from public.verifier_findings where key = 'V10:payout_rows_linked'),
  'open', 'and a real failure is not');
select is(
  (select count(*) from public.verifier_findings f
    where f.check_id = 'V10' and f.last_alerted_at is not null and f.key = 'V10:ledger_duplicates'),
  0::bigint, 'the accepted finding was not announced at all');

select is(
  (select count(*) from jsonb_array_elements(
      public.apply_verifier_run_v1('daily',
        public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'daily', '2026-10-10T11:00:00Z')->'found',
        '2026-10-10T11:00:00Z')->'new') e),
  0::bigint, 'an hour later the same findings are not announced again');

-- Staleness. This guard exists because V10 reads a STORED run rather than
-- taking one, so a lost refresh would otherwise report last week's health as
-- though it were this morning's. Production's stored run was seven days old on
-- the day this was written, which is exactly what that failure looks like.
select is(
  (select count(*) from jsonb_array_elements(
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'daily', '2026-10-10T10:00:00Z')->'found') e
    where e->>'key' = 'V10:stale'),
  0::bigint, 'an hour-old run is fresh and says nothing');

update public.admin_health_check_runs set ran_at = '2026-10-08T00:00:00Z'
 where property_id = 'e1000000-0000-4000-8000-000000000001';
select is(
  (select e->>'title' from jsonb_array_elements(
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'daily', '2026-10-10T10:00:00Z')->'found') e
    where e->>'key' = 'V10:stale'),
  'System health has not been run', 'a fifty-eight-hour-old run says so out loud');

-- The scope rule, for V10 specifically: an hourly run must not resolve a
-- finding raised by a check it never ran.
select lives_ok(
  $$select public.apply_verifier_run_v1('hourly',
      public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-10T12:00:00Z')->'found',
      '2026-10-10T12:00:00Z')$$,
  'an hourly run follows');
select is(
  (select status from public.verifier_findings where key = 'V10:payout_rows_linked'),
  'open', 'and it left the daily V10 finding exactly where it was');

select * from finish();
rollback;
