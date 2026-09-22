-- Session 44: release verifier_triage_and_opening_amounts_20260923 (D-211, D-213, D-216).
-- One pair per rule: the case that must fire, and the neighbouring case that must stay silent.
-- Every fixture lives inside this transaction and goes with the closing rollback.

begin;
select plan(22);

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000044', 'Synthetic Verifier 44', true);

-- Titles are problem phrases ---------------------------------------------------
select is(public.health_check_problem_v1('checkouts_cleaned'), 'Checkout with no cleaning logged',
  'checkouts_cleaned reads as the problem');
select is(public.health_check_problem_v1('some_new_check'), 'System health check some new check needs a look',
  'an unknown check gets a neutral line, never its label');
select ok((select bool_and(
            public.health_check_problem_v1(k) not like 'System health check%'
            and public.health_check_problem_v1(k) <> l
            and public.health_check_problem_v1(k) !~* '\m(agree|linked|settled|reviewed|followed)\M')
           from (values
             ('payout_rows_linked', 'Payout e-mails linked to a stay'),
             ('completed_stays_paid', 'Completed stays with a payout row'),
             ('payout_totals_agree', 'Reservation payouts equal payout e-mails plus adjustments'),
             ('checkouts_cleaned', 'Checkouts (90 days) followed by a cleaning'),
             ('cleaner_fees_settled', 'Cleaning fees settled in the ledger'),
             ('meter_readings_reviewed', 'Odd meter readings reviewed'),
             ('inventory_ledger_consistent', 'Inventory quantities agree with movements'),
             ('ledger_duplicates', 'Duplicate ledger rows'),
             ('ledger_position', 'Cash position: income ' || chr(8722) || ' expenses ' || chr(8722) || ' drawings'),
             ('journals_balanced', 'Posted journals balance'),
             ('concierge_handoffs_open', 'Messenger handoffs awaiting a human reply')) v(k, l)),
  'all eleven checks have their own phrase, and none carries the passing label or a passing verb');

delete from public.admin_health_check_runs where property_id = 'e1000000-0000-4000-8000-000000000044';
insert into public.admin_health_check_runs(property_id, check_key, label, status, count, detail, ran_at)
values
  ('e1000000-0000-4000-8000-000000000044', 'checkouts_cleaned', 'Checkouts (90 days) followed by a cleaning', 'warn', 1,
   '[{"code": "HMSYNTH0001", "guest": "Synthetic Guest", "checkout": "2026-10-08"}]'::jsonb, '2026-10-10T09:00:00Z'),
  ('e1000000-0000-4000-8000-000000000044', 'ledger_duplicates', 'Duplicate ledger rows', 'warn', 2, '[]'::jsonb, '2026-10-10T09:00:00Z');

create temp table run44 as
  select e from jsonb_array_elements(
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000044', 'daily', '2026-10-10T10:00:00Z')->'found') e
   where e->>'check_id' = 'V10';

select is((select e->>'title' from run44 where e->>'key' = 'V10:checkouts_cleaned'), 'Checkout with no cleaning logged',
  'the stored title is the problem, not the label');
select is((select e->'detail'->>'label' from run44 where e->>'key' = 'V10:checkouts_cleaned'), 'Checkouts (90 days) followed by a cleaning',
  'and the label is still kept, in detail');
select ok(not exists (select 1 from run44 where e->'detail' ? 'ran_at'),
  'detail carries no timestamp that moves on every refresh');

-- checkouts_cleaned: red inside 72 hours, yellow outside ------------------------
select is((select e->>'severity' from run44 where e->>'key' = 'V10:checkouts_cleaned'), 'red',
  'a checkout two days ago with no cleaning is red');
update public.admin_health_check_runs
   set detail = '[{"code": "HMSYNTH0001", "guest": "Synthetic Guest", "checkout": "2026-09-30"}]'::jsonb
 where property_id = 'e1000000-0000-4000-8000-000000000044' and check_key = 'checkouts_cleaned';
select is((select e->>'severity' from jsonb_array_elements(
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000044', 'daily', '2026-10-10T10:00:00Z')->'found') e
   where e->>'key' = 'V10:checkouts_cleaned'), 'yellow',
  'a checkout ten days ago with no cleaning stays yellow');
update public.admin_health_check_runs
   set detail = '[{"code": "HMSYNTH0001", "guest": "Synthetic Guest", "checkout": "not a date"}]'::jsonb
 where property_id = 'e1000000-0000-4000-8000-000000000044' and check_key = 'checkouts_cleaned';
select is((select e->>'severity' from jsonb_array_elements(
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000044', 'daily', '2026-10-10T10:00:00Z')->'found') e
   where e->>'key' = 'V10:checkouts_cleaned'), 'yellow',
  'a malformed checkout never breaks the whole run');
update public.admin_health_check_runs
   set detail = '[{"code": "HMSYNTH0001", "guest": "Synthetic Guest", "checkout": "2026-10-08"}]'::jsonb
 where property_id = 'e1000000-0000-4000-8000-000000000044' and check_key = 'checkouts_cleaned';

-- V10:stale: red when the stored run is old, absent when fresh --------------------
select is((select count(*) from jsonb_array_elements(
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000044', 'daily', '2026-10-10T10:00:00Z')->'found') e
   where e->>'key' = 'V10:stale'), 0::bigint,
  'an hour-old run raises no staleness finding');
select is((select e->>'severity' from jsonb_array_elements(
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000044', 'daily', '2026-10-13T10:00:00Z')->'found') e
   where e->>'key' = 'V10:stale'), 'red',
  'a three-day-old run is red: every V10 check has gone silent');

-- An acknowledgement survives the nightly refresh, and only a real change reopens it --
select lives_ok($$select public.apply_verifier_run_v1('daily',
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000044', 'daily', '2026-10-10T10:00:00Z')->'found',
    '2026-10-10T10:00:00Z')$$, 'night one records the findings');
update public.verifier_findings set status = 'acknowledged' where key = 'V10:checkouts_cleaned';
update public.admin_health_check_runs set ran_at = '2026-10-11T09:00:00Z'
 where property_id = 'e1000000-0000-4000-8000-000000000044';
create temp table night2 as select public.apply_verifier_run_v1('daily',
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000044', 'daily', '2026-10-11T10:00:00Z')->'found',
    '2026-10-11T10:00:00Z') r;
select is((select status from public.verifier_findings where key = 'V10:checkouts_cleaned'), 'acknowledged',
  'night two refreshed the health run and the acknowledgement held');
select is((select status from public.verifier_findings where key = 'V10:ledger_duplicates'), 'acknowledged',
  'K16 stays acknowledged across a refresh');
update public.admin_health_check_runs set count = 2, ran_at = '2026-10-12T09:00:00Z'
 where property_id = 'e1000000-0000-4000-8000-000000000044' and check_key = 'checkouts_cleaned';
create temp table night3 as select public.apply_verifier_run_v1('daily',
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000044', 'daily', '2026-10-12T10:00:00Z')->'found',
    '2026-10-12T10:00:00Z') r;
select is((select status from public.verifier_findings where key = 'V10:checkouts_cleaned'), 'open',
  'a second un-cleaned checkout is a real change and reopens it');

-- Seeded heartbeats are born alive; an explicit null is still null ---------------
insert into public.job_heartbeats (job_name, expected_interval_seconds) values ('synthetic-seeded-44', 86400);
select ok((select last_succeeded_at is not null from public.job_heartbeats where job_name = 'synthetic-seeded-44'),
  'a row seeded before its cron exists does not read as never succeeded');
insert into public.job_heartbeats (job_name, expected_interval_seconds, last_succeeded_at) values ('synthetic-never-44', 86400, null);
select ok((select last_succeeded_at is null from public.job_heartbeats where job_name = 'synthetic-never-44'),
  'a row written as never-succeeded on purpose keeps saying so');

-- Opening balances and journals refuse a line with no amount -----------------------
insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-0000000000c4', 'Synthetic Ledger 44', true);
insert into auth.users(id) values ('e2000000-0000-4000-8000-0000000000c4');
insert into public.staff_access_profiles(user_id, role) values ('e2000000-0000-4000-8000-0000000000c4', 'owner');
select set_config('request.jwt.claims', json_build_object('sub','e2000000-0000-4000-8000-0000000000c4','role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select ok((public.acct_seed_chart_v1('e1000000-0000-4000-8000-0000000000c4')->>'ok')::boolean, 'a synthetic chart of accounts');

create temp table ob44 as select (public.save_opening_balance_batch_v1('e1000000-0000-4000-8000-0000000000c4', jsonb_build_object(
  'accounting_start', '2026-03-01', 'reference_notes', 'Synthetic bank statement',
  'lines', jsonb_build_array(
    jsonb_build_object('account_code', '1010', 'debit', '100', 'credit', ''),
    jsonb_build_object('account_code', '3000', 'debit', '', 'credit', '100'),
    jsonb_build_object('account_code', '1020', 'amount', '5'))))) res;
select throws_ok($$select public.approve_opening_balances_v1((select (res->>'id')::uuid from ob44), 'ok', 'key-000000000044-ob-renamed')$$,
  '22023', 'an opening balance line has no debit or credit amount; nothing was posted',
  'a line whose amount key is missing is refused, not posted as zero');

select ok((public.save_opening_balance_batch_v1('e1000000-0000-4000-8000-0000000000c4', jsonb_build_object(
  'id', (select res->>'id' from ob44), 'expected_version', 1,
  'lines', jsonb_build_array(
    jsonb_build_object('account_code', '1010', 'debit', '100', 'credit', ''),
    jsonb_build_object('account_code', '3000', 'debit', '', 'credit', '100'),
    jsonb_build_object('account_code', '', 'debit', '', 'credit', ''))))->>'ok')::boolean, 'the corrected batch saves');
select ok((public.approve_opening_balances_v1((select (res->>'id')::uuid from ob44), 'reviewed', 'key-000000000044-ob-approve')->>'ok')::boolean,
  'a blank form row with empty sides still approves, exactly as the dashboard sends it');

select throws_ok($$select public.post_journal_v1('e1000000-0000-4000-8000-0000000000c4', '2026-03-05', 'Renamed amount',
  '[{"account_code":"1010","amount":"10"},{"account_code":"3000","debit":"0","credit":"10"}]', null, null, null, null, 'key-000000000044-journal-noamt')$$,
  '22023', 'each line carries exactly one positive side with at most two decimals',
  'a journal line without an amount is rejected, never posted as zero');

select * from finish();
rollback;
