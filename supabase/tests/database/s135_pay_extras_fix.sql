-- Session 135: release s135_pay_extras_fix_20261204 (D-420). staff_pay_request_create_v2 resolved the session an extra attaches to behind a test of v_extras (empty until the validation
-- loop ran), so every request that carried an extra was refused with extra_needs_a_clean. The test now reads p_extras.
-- Synthetic fixtures only (uuids f1350000-...); every lookup is scoped to them because a real backup holds real rows. Fixture rows and reads run as the owner role; only the RPC calls run as
-- the staff roles. Everything rolls back.
begin;
select plan(21);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
do $sr$ begin if not (select rolbypassrls from pg_roles where rolname = 'service_role') then alter role service_role bypassrls; end if; end $sr$;
grant select, insert, update, delete on public.cleaning_sessions to authenticated;
grant select on public.cleaning_expense_claims to authenticated;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

-- Fixtures: C (cleaner with one unpaid clean), N (cleaner with no cleaning session at all), the property and the rate rows a baseline database lacks (each insert is guarded).
insert into auth.users(id) values ('f1350000-0000-4000-8000-0000000000a1'), ('f1350000-0000-4000-8000-0000000000a2');
insert into public.staff_access_profiles(user_id, role, telegram_user_id) values
  ('f1350000-0000-4000-8000-0000000000a1', 'cleaner', null),
  ('f1350000-0000-4000-8000-0000000000a2', 'cleaner', null);
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) values
  ('f1350000-0000-4000-8000-0000000000a1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'),
  ('f1350000-0000-4000-8000-0000000000a2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-05-07', 650, 1000, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-05-07');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline (the migration inserts it where the property exists)'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, last_guest_name, submitted_by_user_id) values
  ('f1350000-0000-4000-8000-0000000000b1', 'zz-s135-a', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', date '2026-10-02', 'turnover', 'Ana Reyes', 'f1350000-0000-4000-8000-0000000000a1');

-- 1-3 the function is what the release says it is
select is((select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)'::regprocedure),
          '2e29292fece7c5533395c663b29873a3', 'staff_pay_request_create_v2 is the s135 body');
select ok(position('jsonb_array_length(p_extras) > 0' in (select p.prosrc from pg_proc p where p.oid = 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)'::regprocedure)) > 0
      and position('if jsonb_array_length(v_extras) > 0 then' in (select p.prosrc from pg_proc p where p.oid = 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)'::regprocedure)) = 0,
          'the attach-session test reads p_extras, not v_extras');
select ok((select p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c in ('search_path=""', 'search_path=')) from pg_proc p where p.oid = 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)'::regprocedure),
          'still security definer with an empty search_path');

-- 4-7 grants unchanged
select ok(not has_function_privilege('anon', 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)', 'execute'), 'anon has no execute on v2');
select ok(has_function_privilege('authenticated', 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)', 'execute'), 'authenticated can execute v2');
select ok(not has_function_privilege('service_role', 'public.staff_pay_request_create_v2(jsonb,uuid[],jsonb,jsonb,text)', 'execute'), 'service_role has no execute on v2');
select ok(not has_function_privilege('anon', 'public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)', 'execute'), 'anon has no execute on the v1 wrapper');

-- 8-14 C: one eligible clean plus one extra is accepted (500 + 120)
select set_config('request.jwt.claims', json_build_object('sub','f1350000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'r1', public.staff_pay_request_create_v2(
  '[{"id":"f1350000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[],
  '[{"description":"zz s135 extra for the guest","amount":120}]'::jsonb, '[]'::jsonb, 'zz-s135-key-0001');
reset role;
select is((select v->>'ok' from _t where k = 'r1'), 'true', 'a clean plus an extra is ok');
select is((select v->>'total' from _t where k = 'r1'), '620.00', 'the total is the 500 clean plus the 120 extra');
select is((select count(*)::int from public.cleaning_expense_claims where description = 'zz s135 extra for the guest' and submitted_by_user_id = 'f1350000-0000-4000-8000-0000000000a1'), 1, 'one claim row was written for the extra');
select is((select status from public.cleaning_expense_claims where description = 'zz s135 extra for the guest'), 'pending_review', 'the claim row is pending_review');
select is((select cleaning_session_id from public.cleaning_expense_claims where description = 'zz s135 extra for the guest'), 'f1350000-0000-4000-8000-0000000000b1'::uuid, 'the claim is attached to her clean');
select is((select pay_request_id from public.cleaning_expense_claims where description = 'zz s135 extra for the guest'), (select (v->>'request_id')::uuid from _t where k = 'r1'), 'the claim carries the new request id');
select is((select jsonb_array_length(v->'lines') from _t where k = 'r1'), 2, 'the snapshot holds the clean and the extra');

-- 15-18 N: an extra with no clean and no session of her own is still refused, and leaves nothing behind
select set_config('request.jwt.claims', json_build_object('sub','f1350000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'r2', public.staff_pay_request_create_v2(
  '[]'::jsonb, '{}'::uuid[], '[{"description":"zz s135 orphan extra","amount":80}]'::jsonb, '[]'::jsonb, 'zz-s135-key-0002');
reset role;
select is((select v->>'ok' from _t where k = 'r2'), 'false', 'an extra with no clean and no session is refused');
select is((select v->>'reason' from _t where k = 'r2'), 'extra_needs_a_clean', 'the reason is extra_needs_a_clean');
select is((select count(*)::int from public.cleaning_expense_claims where description = 'zz s135 orphan extra'), 0, 'the refusal left no claim row behind');
select is((select count(*)::int from public.staff_pay_requests where payee_user_id = 'f1350000-0000-4000-8000-0000000000a2'), 0, 'the refusal wrote no request');

-- 19-20 an extra over the cap is still bad_extra for C (validation is untouched)
select set_config('request.jwt.claims', json_build_object('sub','f1350000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'r3', public.staff_pay_request_create_v2('[]'::jsonb, '{}'::uuid[], '[{"description":"zz s135 too much","amount":5001}]'::jsonb, '[]'::jsonb, 'zz-s135-key-0003');
reset role;
select is((select v->>'reason' from _t where k = 'r3'), 'bad_extra', 'an extra over 5,000 is still bad_extra');
select is((select count(*)::int from public.cleaning_expense_claims where description = 'zz s135 too much'), 0, 'and writes nothing');
select ok((select bool_and(not has_table_privilege('anon', t, p) and not has_any_column_privilege('anon', t, p))
             from unnest(array['public.staff_pay_requests', 'public.cleaning_expense_claims']) t, unnest(array['select', 'insert', 'update']) p),
  's136: anon holds no table or column privilege (select, insert, update) on staff_pay_requests or cleaning_expense_claims');

select * from finish();
rollback;
