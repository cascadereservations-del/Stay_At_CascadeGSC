-- Session 84, lane C: release s84_calendar_20261017, part 3. staff_pay_admin_step_v1: 'cancel' on a request another admin is paying is refused
-- (not_yours); the payer cancelling her own payment, and any admin cancelling a request that is only 'requested', still work.
-- Synthetic fixtures only (uuids c8400000-...); the payout payload is a made-up string. Everything rolls back.
begin;
select plan(10);

grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant execute on function public.staff_pay_admin_step_v1(uuid, text) to authenticated;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;

insert into auth.users(id, email) values
  ('c8400000-0000-4000-8000-0000000000a1', 'zz-s84-honey@example.com'), ('c8400000-0000-4000-8000-0000000000a2', 'zz-s84-other@example.com'),
  ('c8400000-0000-4000-8000-0000000000a3', 'zz-s84-adminA@example.com'), ('c8400000-0000-4000-8000-0000000000a5', 'zz-s84-adminB@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('c8400000-0000-4000-8000-0000000000a1', 'cleaner'), ('c8400000-0000-4000-8000-0000000000a2', 'cleaner'),
  ('c8400000-0000-4000-8000-0000000000a3', 'admin'), ('c8400000-0000-4000-8000-0000000000a5', 'admin');
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) select u, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
  from unnest(array['c8400000-0000-4000-8000-0000000000a1', 'c8400000-0000-4000-8000-0000000000a2', 'c8400000-0000-4000-8000-0000000000a3', 'c8400000-0000-4000-8000-0000000000a5']::uuid[]) u;
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');
insert into public.staff_details(user_id, payout_qrph, payout_bank_label) values ('c8400000-0000-4000-8000-0000000000a1', '000201010211ZZTESTPAYOUT6304ABCD', 'ZZBank');
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id) values
  ('c8400000-0000-4000-8000-0000000000b1', 'zz-c84-a', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', date '2026-10-02', 'turnover', 'c8400000-0000-4000-8000-0000000000a1'),
  ('c8400000-0000-4000-8000-0000000000b2', 'zz-c84-b', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzother', date '2026-10-03', 'turnover', 'c8400000-0000-4000-8000-0000000000a2'),
  ('c8400000-0000-4000-8000-0000000000b3', 'zz-c84-c', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', date '2026-10-04', 'turnover', 'c8400000-0000-4000-8000-0000000000a1');

-- three requests, each made by its own owner through the real RPC
select pg_temp.as_user('c8400000-0000-4000-8000-0000000000a1');
insert into _t select 'r1', public.staff_pay_request_create_v1('[{"id":"c8400000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-c84-key-0001');
insert into _t select 'r3', public.staff_pay_request_create_v1('[{"id":"c8400000-0000-4000-8000-0000000000b3"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-c84-key-0003');
reset role;
select pg_temp.as_user('c8400000-0000-4000-8000-0000000000a2');
insert into _t select 'r2', public.staff_pay_request_create_v1('[{"id":"c8400000-0000-4000-8000-0000000000b2"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-c84-key-0002');
reset role;
select ok((select bool_and((v->>'ok')::boolean) from _t where k in ('r1', 'r2', 'r3')), 'fixtures: the three requests were made');

-- admin A is paying request 1; admin B, on a stale screen, tries to cancel it
select pg_temp.as_user('c8400000-0000-4000-8000-0000000000a3');
insert into _t select 'a_pay', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'pay');
reset role;
select pg_temp.as_user('c8400000-0000-4000-8000-0000000000a5');
insert into _t select 'b_cancel', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'cancel');
reset role;
select is((select v->>'reason' from _t where k = 'a_pay'), null, 'A starts paying request 1 (no refusal)');
select is((select v->>'reason' from _t where k = 'b_cancel'), 'not_yours', 'B cannot cancel a request A is paying');
select ok((select status = 'paying' and paying_by_user_id = 'c8400000-0000-4000-8000-0000000000a3' from public.staff_pay_requests where id = (select (v->>'request_id')::uuid from _t where k = 'r1')), 'and the request is still paying, still A''s');
select is((select v->>'paying_by_name' is not null from _t where k = 'b_cancel'), true, 'the refusal says who is paying');

-- B takes it over (nobody has said sent), then cancels her own payment
select pg_temp.as_user('c8400000-0000-4000-8000-0000000000a5');
insert into _t select 'b_take', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'takeover');
insert into _t select 'b_cancel_own', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'cancel');
reset role;
select is((select v->>'ok' from _t where k = 'b_take'), 'true', 'B takes over while sent has not been said');
select is((select v->>'ok' from _t where k = 'b_cancel_own'), 'true', 'B can cancel her own payment');
select is((select status from public.staff_pay_requests where id = (select (v->>'request_id')::uuid from _t where k = 'r1')), 'cancelled', 'and it is cancelled');

-- a request that is only 'requested' can be cancelled by any admin
select pg_temp.as_user('c8400000-0000-4000-8000-0000000000a3');
insert into _t select 'a_cancel_req', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r2'), 'cancel');
-- the payer cancelling her own payment (the 98B7AB4E sequence: the payer account cancels its own request)
insert into _t select 'a_pay3', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r3'), 'pay');
insert into _t select 'a_cancel_own', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r3'), 'cancel');
reset role;
select is((select v->>'ok' from _t where k = 'a_cancel_req'), 'true', 'an admin cancels a request that is only requested');
select ok((select (v->>'ok')::boolean from _t where k = 'a_cancel_own') and (select status = 'cancelled' from public.staff_pay_requests where id = (select (v->>'request_id')::uuid from _t where k = 'r3')), 'the payer cancels her own payment');

select * from finish();
rollback;
