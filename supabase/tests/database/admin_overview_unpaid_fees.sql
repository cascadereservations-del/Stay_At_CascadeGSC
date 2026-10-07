-- Session 76: release admin_overview_unpaid_fees_20261007. Today's "N cleaner fees unpaid" counts every cleaning with
-- fee_paid_at null whose fee is unpriced (NULL, the SPEC-37 state until the cleaner requests pay) or positive; an
-- explicit 0 is "no fee"; other properties never leak in. A cleaner (no finance) still gets finance = null.
-- Runs as the owner; roles are switched with set_config('role') + request.jwt.claims (as admin_read_models_v1.sql does).
-- Synthetic rows only: uuids e7600000-..., everything rolls back.
begin;
select plan(7);

select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.get_admin_overview_v1(uuid)'::regprocedure),
  'overview stays security definer with an empty search_path');
select ok(not has_function_privilege('anon', 'public.get_admin_overview_v1(uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.get_admin_overview_v1(uuid)', 'execute'),
  'anon cannot call the overview; a signed-in user can');

insert into public.properties(id, name, is_active) values
  ('e7600000-0000-4000-8000-0000000000a1', 'Synthetic Fees A', true),
  ('e7600000-0000-4000-8000-0000000000b2', 'Synthetic Fees B', true);
insert into auth.users(id) values ('e7600000-0000-4000-8000-000000000001'), ('e7600000-0000-4000-8000-000000000002');
insert into public.staff_access_profiles(user_id, role) values
  ('e7600000-0000-4000-8000-000000000001', 'owner'), ('e7600000-0000-4000-8000-000000000002', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values
  ('e7600000-0000-4000-8000-000000000002', 'e7600000-0000-4000-8000-0000000000a1');

-- Counted: unpriced turnover, unpriced deep clean, priced and unpaid. Not counted: explicit 0, paid (priced or not),
-- another property's unpriced clean.
insert into public.cleaning_sessions(id, property_id, submission_id, cleaner_name, cleaned_at, cleaning_type, fee_amount, fee_paid_at) values
  ('e7600000-0000-4000-8000-0000000000c1', 'e7600000-0000-4000-8000-0000000000a1', 'zz-fee-1', 'Fixture', '2026-10-04 10:00+08', 'turnover',   null, null),
  ('e7600000-0000-4000-8000-0000000000c2', 'e7600000-0000-4000-8000-0000000000a1', 'zz-fee-2', 'Fixture', '2026-10-05 10:00+08', 'deep_clean', null, null),
  ('e7600000-0000-4000-8000-0000000000c3', 'e7600000-0000-4000-8000-0000000000a1', 'zz-fee-3', 'Fixture', '2026-10-06 10:00+08', 'mid_stay',   500,  null),
  ('e7600000-0000-4000-8000-0000000000c4', 'e7600000-0000-4000-8000-0000000000a1', 'zz-fee-4', 'Fixture', '2026-10-01 10:00+08', 'turnover',   0,    null),
  ('e7600000-0000-4000-8000-0000000000c5', 'e7600000-0000-4000-8000-0000000000a1', 'zz-fee-5', 'Fixture', '2026-09-30 10:00+08', 'turnover',   650,  '2026-10-01 09:00+08'),
  ('e7600000-0000-4000-8000-0000000000c6', 'e7600000-0000-4000-8000-0000000000a1', 'zz-fee-6', 'Fixture', '2026-09-29 10:00+08', 'turnover',   null, '2026-10-01 09:00+08'),
  ('e7600000-0000-4000-8000-0000000000c7', 'e7600000-0000-4000-8000-0000000000b2', 'zz-fee-7', 'Fixture', '2026-10-04 10:00+08', 'turnover',   null, null);

-- owner, aal2 (finance visible)
select set_config('request.jwt.claims', json_build_object('sub','e7600000-0000-4000-8000-000000000001','role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select is((public.get_admin_overview_v1('e7600000-0000-4000-8000-0000000000a1')->'finance'->>'unpaidCleanerFees')::int, 3,
  'unpaid = unpriced turnover + unpriced deep clean + priced unpaid; explicit 0, paid and the other property excluded');
select is((public.get_admin_overview_v1('e7600000-0000-4000-8000-0000000000b2')->'finance'->>'unpaidCleanerFees')::int, 1,
  'property B counts only its own unpriced clean');
reset role;

-- once the unpriced turnover is paid it leaves the count
update public.cleaning_sessions set fee_amount = 650, fee_paid_at = now() where id = 'e7600000-0000-4000-8000-0000000000c1';
select set_config('role', 'authenticated', true);
select is((public.get_admin_overview_v1('e7600000-0000-4000-8000-0000000000a1')->'finance'->>'unpaidCleanerFees')::int, 2,
  'paying a clean (fee set, fee_paid_at set) drops it from the count');
reset role;

-- cleaner, aal1 (no finance)
select set_config('request.jwt.claims', json_build_object('sub','e7600000-0000-4000-8000-000000000002','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select ok(public.get_admin_overview_v1('e7600000-0000-4000-8000-0000000000a1') ? 'finance', 'the finance key is still returned to a cleaner');
select is(public.get_admin_overview_v1('e7600000-0000-4000-8000-0000000000a1')->'finance', 'null'::jsonb,
  'a cleaner gets finance = null, never a zero count');
reset role;

select * from finish();
rollback;
