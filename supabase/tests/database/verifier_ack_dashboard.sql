-- Session 49: release verifier_ack_dashboard_20260925 (SPEC-25, D-226).
-- The dashboard's "Known, stop reminding", who may press it, what it records, and that the D-217.2 hold survives.
-- Every fixture lives inside this transaction and goes with the closing rollback.
begin;
select plan(16);

select has_function('public', 'ack_verifier_finding_v1', array['text'], 'ack_verifier_finding_v1(text) exists');
select is_definer('public', 'ack_verifier_finding_v1', array['text'], 'it is security definer');
select ok((select proconfig = array['search_path=""'] from pg_proc where oid = 'public.ack_verifier_finding_v1(text)'::regprocedure),
  'its search_path is pinned empty');
select ok(has_function_privilege('authenticated', 'public.ack_verifier_finding_v1(text)', 'execute')
      and not has_function_privilege('anon', 'public.ack_verifier_finding_v1(text)', 'execute'),
  'signed-in staff may call it, anon may not');
select has_column('public', 'verifier_findings', 'acknowledged_at', 'acknowledged_at exists');
select has_column('public', 'verifier_findings', 'acknowledged_by', 'acknowledged_by exists');

insert into auth.users(id) values
  ('e2000000-0000-4000-8000-0000000004a1'), ('e2000000-0000-4000-8000-0000000004a2') on conflict(id) do nothing;
insert into public.staff_access_profiles(user_id, role, telegram_user_id) values
  ('e2000000-0000-4000-8000-0000000004a1', 'owner', 994911),
  ('e2000000-0000-4000-8000-0000000004a2', 'finance', null)
on conflict(user_id) do update set role = excluded.role, telegram_user_id = excluded.telegram_user_id, disabled_at = null, sessions_revoked_after = null;

insert into public.verifier_findings(key, check_id, severity, title, detail, status, first_seen, last_seen)
values ('VX:synthetic-ack-1', 'V10', 'yellow', 'Synthetic finding', '{"n": 2}', 'open', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z'),
       -- check_id outside every scope array, so the apply calls below never close it as gone
       ('VX:synthetic-ack-2', 'VX', 'yellow', 'Synthetic finding two', '{"n": 1}', 'open', '2026-10-10T00:00:00Z', '2026-10-10T00:00:00Z');

-- A finance user is refused.
set local role authenticated;
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-0000000004a2","aal":"aal1"}';
select throws_ok($$select public.ack_verifier_finding_v1('VX:synthetic-ack-1')$$, '42501', null,
  'finance cannot silence a finding');

-- The owner acknowledges it.
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-0000000004a1","aal":"aal1"}';
select is(public.ack_verifier_finding_v1('VX:synthetic-ack-1')->>'outcome', 'acknowledged', 'the owner can say it is known');
select is(public.ack_verifier_finding_v1('VX:synthetic-ack-1')->>'outcome', 'not_open', 'a second press says it is already handled');
reset role;

select is((select status from public.verifier_findings where key = 'VX:synthetic-ack-1'), 'acknowledged', 'the row is acknowledged');
select is((select acknowledged_by from public.verifier_findings where key = 'VX:synthetic-ack-1'), 'e2000000-0000-4000-8000-0000000004a1',
  'and records who');
select ok((select acknowledged_at is not null from public.verifier_findings where key = 'VX:synthetic-ack-1'), 'and when');

-- D-217.2: the same detail keeps it acknowledged; a changed detail reopens it.
select public.apply_verifier_run_v1('daily',
  '[{"key": "VX:synthetic-ack-1", "check_id": "V10", "severity": "yellow", "title": "Synthetic finding", "detail": {"n": 2}}]'::jsonb,
  '2026-10-11T00:00:00Z');
select is((select status from public.verifier_findings where key = 'VX:synthetic-ack-1'), 'acknowledged',
  'the nightly run with the same detail leaves the acknowledgement alone');
select public.apply_verifier_run_v1('daily',
  '[{"key": "VX:synthetic-ack-1", "check_id": "V10", "severity": "yellow", "title": "Synthetic finding", "detail": {"n": 3}}]'::jsonb,
  '2026-10-12T00:00:00Z');
select is((select status from public.verifier_findings where key = 'VX:synthetic-ack-1'), 'open',
  'a changed detail reopens it');

-- The Telegram path records who and when too.
select is(public.telegram_ack_verifier_finding_v1(994911, 'VX:synthetic-ack-2')->>'ok', 'true', 'the Telegram tap still works');
select is((select acknowledged_by from public.verifier_findings where key = 'VX:synthetic-ack-2'), 'e2000000-0000-4000-8000-0000000004a1',
  'and stamps the same columns');

select * from finish();
rollback;
