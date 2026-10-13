-- Session 81, Lane C: release s81_staff_pay_push_20261014. Admin Pay actions, the stored-proof settle, her own requests only, the once-only paid
-- notice and the Web Push table. Synthetic fixtures only (uuids c5100000-...); every lookup is scoped to them. The payout payload is a made-up
-- string that is not a QR Ph payment. Grant assertions need ACLs, so they live in the release's forward checks. Everything rolls back.
begin;
select plan(59);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite; the forward checks prove the real ACLs)
grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant select, delete on public.staff_push_subscriptions to authenticated;
grant select on storage.objects to authenticated;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;

-- fixtures: Honey (cleaner), Other (cleaner), Admin, Finance. All four have property access.
insert into auth.users(id, email) values
  ('c5100000-0000-4000-8000-0000000000a1', 'zz-honey@example.com'), ('c5100000-0000-4000-8000-0000000000a2', 'zz-other@example.com'),
  ('c5100000-0000-4000-8000-0000000000a3', 'zz-admin@example.com'), ('c5100000-0000-4000-8000-0000000000a4', 'zz-finance@example.com');
insert into public.staff_access_profiles(user_id, role) values
  ('c5100000-0000-4000-8000-0000000000a1', 'cleaner'), ('c5100000-0000-4000-8000-0000000000a2', 'cleaner'),
  ('c5100000-0000-4000-8000-0000000000a3', 'admin'), ('c5100000-0000-4000-8000-0000000000a4', 'finance');
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) select u, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
  from unnest(array['c5100000-0000-4000-8000-0000000000a1', 'c5100000-0000-4000-8000-0000000000a2', 'c5100000-0000-4000-8000-0000000000a3', 'c5100000-0000-4000-8000-0000000000a4']::uuid[]) u;
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');
-- Honey's payout payload is synthetic: it satisfies the column check and nothing else.
insert into public.staff_details(user_id, payout_qrph, payout_bank_label) values ('c5100000-0000-4000-8000-0000000000a1', '000201010211ZZTESTPAYOUT6304ABCD', 'ZZBank');
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, submitted_by_user_id) values
  ('c5100000-0000-4000-8000-0000000000b1', 'zz-c81-a', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzhoney Reyes', date '2026-10-02', 'turnover', 'c5100000-0000-4000-8000-0000000000a1'),
  ('c5100000-0000-4000-8000-0000000000b2', 'zz-c81-b', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zzother', date '2026-10-03', 'turnover', 'c5100000-0000-4000-8000-0000000000a2');
insert into storage.buckets(id, name) values ('cleaning-photos', 'cleaning-photos') on conflict do nothing;

-- two requests, each made by its own owner through the real RPC
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a1');
insert into _t select 'r1', public.staff_pay_request_create_v1('[{"id":"c5100000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-c81-key-0001');
reset role;
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a2');
insert into _t select 'r2', public.staff_pay_request_create_v1('[{"id":"c5100000-0000-4000-8000-0000000000b2"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-c81-key-0002');
reset role;
select ok((select (v->>'ok')::boolean from _t where k = 'r1') and (select (v->>'ok')::boolean from _t where k = 'r2'), 'fixtures: both requests were made');

-- 2-10 who may call the admin RPCs
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a1');
insert into _t select 'cl_list', public.staff_pay_admin_list_v1();
insert into _t select 'cl_qr', public.staff_pay_payout_qr_v1((select (v->>'request_id')::uuid from _t where k = 'r1'));
insert into _t select 'cl_step', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'pay');
insert into _t select 'cl_settle', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), '{}'::jsonb);
reset role;
select is((select v->>'reason' from _t where k = 'cl_list'), 'not_authorized', 'a cleaner cannot list the admin queue');
select is((select v->>'reason' from _t where k = 'cl_qr'), 'not_authorized', 'a cleaner cannot read a payout QR, not even her own');
select is((select v->>'reason' from _t where k = 'cl_step'), 'not_authorized', 'a cleaner cannot mark a request as being paid');
select is((select v->>'reason' from _t where k = 'cl_settle'), 'not_authorized', 'a cleaner cannot settle a request');
select is((select status from public.staff_pay_requests where id = (select (v->>'request_id')::uuid from _t where k = 'r1')), 'requested', 'and her request is still requested');
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000e0'); -- a session with no staff profile
insert into _t select 'ghost_my', public.staff_pay_my_requests_v1();
insert into _t select 'ghost_sub', public.staff_push_subscribe_v1('https://push.example.com/zz', repeat('p', 87), repeat('a', 22), 'zz');
reset role;
select is((select v->>'reason' from _t where k = 'ghost_my'), 'not_authorized', 'no profile, no requests');
select is((select v->>'reason' from _t where k = 'ghost_sub'), 'not_authorized', 'no profile, no push subscription');

-- 11-20 the admin queue and the QR reader
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a3');
insert into _t select 'ad_list', public.staff_pay_admin_list_v1();
insert into _t select 'ad_qr', public.staff_pay_payout_qr_v1((select (v->>'request_id')::uuid from _t where k = 'r1'));
insert into _t select 'ad_qr_none', public.staff_pay_payout_qr_v1((select (v->>'request_id')::uuid from _t where k = 'r2'));
insert into _t select 'ad_qr_missing', public.staff_pay_payout_qr_v1('c5100000-0000-4000-8000-0000000000ff');
reset role;
select is((select v->>'ok' from _t where k = 'ad_list'), 'true', 'an admin can list the queue');
select is((select count(*)::int from _t, jsonb_array_elements(v->'requests') r where k = 'ad_list' and r->>'payee_name' in ('Zzhoney Reyes', 'Zzother')), 2, 'the queue holds both fixture requests');
select ok((select position('ZZTESTPAYOUT' in v::text) = 0 and v::text !~ 'payout_qrph' from _t where k = 'ad_list'), 'the list never carries the payout payload');
select ok((select bool_or((r->>'has_qr')::boolean) and not bool_and((r->>'has_qr')::boolean) from _t, jsonb_array_elements(v->'requests') r where k = 'ad_list' and r->>'payee_name' in ('Zzhoney Reyes', 'Zzother')), 'has_qr tells which payee has a payout QR saved, without the QR');
select is((select v->>'payout_qrph' from _t where k = 'ad_qr'), '000201010211ZZTESTPAYOUT6304ABCD', 'the admin reads Honey''s payout payload for her open request');
select is((select v->>'total' from _t where k = 'ad_qr'), '500.00', 'with the request total beside it');
select ok((select v->>'ok' = 'true' and v->'payout_qrph' = 'null'::jsonb from _t where k = 'ad_qr_none'), 'a payee with no QR saved answers ok with a null payload (the screen falls back)');
select is((select v->>'reason' from _t where k = 'ad_qr_missing'), 'not_found', 'an unknown request is not_found');
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a4');
insert into _t select 'fi_qr', public.staff_pay_payout_qr_v1((select (v->>'request_id')::uuid from _t where k = 'r1'));
reset role;
select is((select v->>'payout_qrph' from _t where k = 'fi_qr'), '000201010211ZZTESTPAYOUT6304ABCD', 'finance can read it too');
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a2');
insert into _t select 'ot_qr', public.staff_pay_payout_qr_v1((select (v->>'request_id')::uuid from _t where k = 'r1'));
reset role;
select is((select v->>'reason' from _t where k = 'ot_qr'), 'not_authorized', 'another cleaner cannot read Honey''s payout payload');

-- 21-27 her own requests only (two staff fixtures)
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a1');
insert into _t select 'my1', public.staff_pay_my_requests_v1();
reset role;
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a2');
insert into _t select 'my2', public.staff_pay_my_requests_v1();
reset role;
select is((select jsonb_array_length(v->'requests') from _t where k = 'my1'), 1, 'Honey sees one request');
select is((select v->'requests'->0->>'ref' from _t where k = 'my1'), (select v->>'ref' from _t where k = 'r1'), 'and it is hers');
select is((select v->'requests'->0->>'ref' from _t where k = 'my2'), (select v->>'ref' from _t where k = 'r2'), 'the other cleaner sees hers');
select ok((select position((select v->>'ref' from _t where k = 'r2') in v::text) = 0 from _t where k = 'my1'), 'Honey''s payload does not mention the other cleaner''s request');
select ok((select v::text !~ 'ZZTESTPAYOUT|payout_qrph|paying_by|paid_by' from _t where k = 'my1'), 'her payload carries no payout payload and no one else''s name');
select is((select v->'requests'->0->>'bank_label' from _t where k = 'my1'), 'ZZBank', 'her own bank label rides along');
select is((select v->'requests'->0->>'date_from' from _t where k = 'my1'), '2026-10-02', 'and the dates of her work');

-- 28-31 the admin steps
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a3');
insert into _t select 'pre_settle', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), '{}'::jsonb);
insert into _t select 'bad_step', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'override');
insert into _t select 'pay1', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'pay');
insert into _t select 'pay2', public.staff_pay_admin_step_v1((select (v->>'request_id')::uuid from _t where k = 'r2'), 'pay');
reset role;
select is((select v->>'reason' from _t where k = 'pre_settle'), 'not_paying', 'settle before "I am paying this" is refused');
select is((select v->>'reason' from _t where k = 'bad_step'), 'bad_step', 'the web steps cannot override or add proof');
select is((select v->>'status' from _t where k = 'pay1'), 'paying', 'I am paying this moves the request to paying');
select ok((select paying_by_name is not null and paying_by_tg is null from public.staff_pay_requests where id = (select (v->>'request_id')::uuid from _t where k = 'r1')), 'with the signed-in person as the payer');

-- 32-39 settle refusals: nothing becomes PAID without a stored screenshot
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a3');
insert into _t select 's_empty', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), '{}'::jsonb);
insert into _t select 's_nostore', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a3/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg', 'sha256', repeat('a', 64), 'amount', 500, 'reference', 'AB 1234 5678 90'));
insert into _t select 's_othername', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a1/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg', 'sha256', repeat('a', 64), 'amount', 500, 'reference', 'AB1234567890'));
insert into _t select 's_nosha', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a3/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg', 'sha256', 'xyz', 'amount', 500, 'reference', 'AB1234567890'));
insert into _t select 's_noref', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a3/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg', 'sha256', repeat('a', 64), 'amount', 500));
insert into _t select 's_noamt', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a3/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg', 'sha256', repeat('a', 64), 'reference', 'AB1234567890'));
reset role;
select is((select v->>'reason' from _t where k = 's_empty'), 'bad_proof', 'an empty proof is refused');
select is((select v->>'reason' from _t where k = 's_nostore'), 'no_stored_proof', 'a screenshot that is not in the bucket is refused');
select is((select v->>'reason' from _t where k = 's_othername'), 'bad_proof', 'a path under someone else''s folder is refused');
select is((select v->>'reason' from _t where k = 's_nosha'), 'bad_proof', 'a missing sha256 is refused');
select is((select v->>'reason' from _t where k = 's_noref'), 'bad_proof', 'a missing reference is refused');
select is((select v->>'reason' from _t where k = 's_noamt'), 'bad_proof', 'a missing amount is refused');
select is((select status from public.staff_pay_requests where id = (select (v->>'request_id')::uuid from _t where k = 'r1')), 'paying', 'after six refusals the request is still not paid');
select throws_ok(format($q$update public.staff_pay_requests set status = 'paid' where id = %L$q$, (select v->>'request_id' from _t where k = 'r2')), '23514', null, 'the table itself refuses PAID without a screenshot (staff_pay_paid_needs_proof)');

-- 40-49 the real settle
insert into storage.objects(bucket_id, name) values ('cleaning-photos', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a3/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg');
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a3');
insert into _t select 's_mismatch', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a3/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg', 'sha256', repeat('a', 64), 'amount', 400, 'reference', 'AB1234567890'));
insert into _t select 's_ok', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a3/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg', 'sha256', repeat('a', 64), 'amount', 500, 'reference', 'AB 1234 5678 90'));
insert into _t select 's_again', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r1'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a3/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg', 'sha256', repeat('a', 64), 'amount', 500, 'reference', 'AB1234567890'));
insert into _t select 's_dup', public.staff_pay_admin_settle_v1((select (v->>'request_id')::uuid from _t where k = 'r2'),
  jsonb_build_object('path', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/c5100000-0000-4000-8000-0000000000a3/c5100000-0000-4000-8000-0000000000f1/zz-proof.jpg', 'sha256', repeat('a', 64), 'amount', 500, 'reference', 'ZZ11112222'));
reset role;
select is((select v->>'reason' from _t where k = 's_mismatch'), 'amount_mismatch', 'an amount that is not the total is refused until the person confirms it');
select is((select v->>'ok' from _t where k = 's_ok'), 'true', 'a stored screenshot, sha256, amount and reference settle the request');
select is((select v->>'verdict' from _t where k = 's_ok'), 'match', 'as a match');
select ok((select status = 'paid' and proof_sha256 = repeat('a', 64) and proof_reference = 'AB1234567890' and proof_amount = 500 and proof_path like '%/zz-proof.jpg'
             and paid_by_user_id = 'c5100000-0000-4000-8000-0000000000a3' and paid_at is not null and proof_file_unique_id like 'web:%'
             from public.staff_pay_requests where id = (select (v->>'request_id')::uuid from _t where k = 'r1')), 'the row holds the proof, the reference normalised, and who paid');
select ok((select fee_paid_at is not null from public.cleaning_sessions where id = 'c5100000-0000-4000-8000-0000000000b1'), 'her clean is marked paid in the existing ledger path');
select is((select count(*)::int from public.transactions where external_ref = 'cleanfee:c5100000-0000-4000-8000-0000000000b1'), 1, 'with exactly one ledger row');
select is((select v->>'reason' from _t where k = 's_again'), 'not_paying', 'a second settle of a paid request changes nothing');
select is((select v->>'reason' from _t where k = 's_dup'), 'duplicate_proof', 'the same screenshot cannot settle a second request');
select is((select status from public.staff_pay_requests where id = (select (v->>'request_id')::uuid from _t where k = 'r2')), 'paying', 'which stays paying');
select ok(exists (select 1 from pg_trigger where tgname = 'staff_pay_notify_paid' and tgrelid = 'public.staff_pay_requests'::regclass), 'the paid trigger is installed (and a settle without pg_net did not fail)');

-- 50-53 the once-only notice
insert into _t select 'n_notpaid', public.staff_pay_notice_v1((select (v->>'request_id')::uuid from _t where k = 'r2'), 'claim');
insert into _t select 'n_claim', public.staff_pay_notice_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'claim');
insert into _t select 'n_again', public.staff_pay_notice_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'claim');
select public.staff_pay_notice_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'release');
insert into _t select 'n_after_release', public.staff_pay_notice_v1((select (v->>'request_id')::uuid from _t where k = 'r1'), 'claim');
select is((select v->>'reason' from _t where k = 'n_notpaid'), 'not_paid', 'an unpaid request has no notice');
select ok((select v->>'ok' = 'true' and v->>'first_name' = 'Zzhoney' and v->>'total' = '500.00' and v->>'bank_reference' = 'AB1234567890' and v->>'bank_label' = 'ZZBank'
             and v->>'date_from' = '2026-10-02' and v->'paid_by_tg' = 'null'::jsonb from _t where k = 'n_claim'), 'the claim returns the first name, amount, reference, bank label and dates for the sentences');
select is((select v->>'reason' from _t where k = 'n_again'), 'already_sent', 'a second claim is refused');
select is((select v->>'ok' from _t where k = 'n_after_release'), 'true', 'a release lets the notice be claimed again');

-- 54-61 Web Push subscriptions: a person manages only her own rows
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a1');
insert into _t select 'sub1', public.staff_push_subscribe_v1('https://push.example.com/zz-honey', repeat('p', 87), repeat('a', 22), 'zz agent');
insert into _t select 'sub_bad', public.staff_push_subscribe_v1('http://push.example.com/zz-honey', repeat('p', 87), repeat('a', 22), null);
insert into _t select 'own1', to_jsonb((select count(*) from public.staff_push_subscriptions));
reset role;
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a2');
insert into _t select 'own2', to_jsonb((select count(*) from public.staff_push_subscriptions));
with d as (delete from public.staff_push_subscriptions where endpoint = 'https://push.example.com/zz-honey' returning 1)
  insert into _t select 'del_other', to_jsonb((select count(*) from d));
reset role;
select is((select v->>'ok' from _t where k = 'sub1'), 'true', 'Honey turns the toggle on');
select is((select v->>'reason' from _t where k = 'sub_bad'), 'bad_request', 'a non-https endpoint is refused');
select is((select v::text from _t where k = 'own1'), '1', 'Honey sees her own subscription');
select is((select v::text from _t where k = 'own2'), '0', 'the other cleaner sees none of Honey''s');
select is((select v::text from _t where k = 'del_other'), '0', 'and cannot delete it');
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a2');
insert into _t select 'move', public.staff_push_subscribe_v1('https://push.example.com/zz-honey', repeat('q', 87), repeat('b', 22), 'zz shared phone');
reset role;
select is((select user_id::text from public.staff_push_subscriptions where endpoint = 'https://push.example.com/zz-honey'), 'c5100000-0000-4000-8000-0000000000a2', 'the same phone signed in as someone else moves to her');
select is((select count(*)::int from public.staff_push_subscriptions where endpoint = 'https://push.example.com/zz-honey'), 1, 'one endpoint, one row');
select pg_temp.as_user('c5100000-0000-4000-8000-0000000000a2');
select public.staff_push_subscribe_v1('https://push.example.com/zz-' || n, repeat('p', 87), repeat('a', 22), null) from generate_series(1, 6) n;
reset role;
select is((select count(*)::int from public.staff_push_subscriptions where user_id = 'c5100000-0000-4000-8000-0000000000a2'), 5, 'a person keeps at most five phones');

select * from finish();
rollback;
