begin;
select plan(70);
-- The rehearsal restore is --no-acl: give authenticated the table grants production has (rolled back with the suite),
-- so the guard trigger, not a missing grant, is what refuses the direct writes below.
grant select, insert, update, delete on public.cleaning_sessions to authenticated;
grant select on public.cleaning_expense_claims to authenticated;

-- SPEC-37 staff payment request. All inserts run as the owner (service_role has no BYPASSRLS in the rehearsal restore);
-- the staff RPCs run under a synthetic JWT, the Telegram step as the owner. Synthetic zz- fixtures only; the suite is inside
-- begin/rollback, so nothing persists.

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

-- Fixtures: a cleaner (C), another cleaner (D), an admin with a Telegram id (A); the property and the three rate rows a
-- baseline database lacks (a restored backup already has them, so each insert is guarded).
insert into auth.users(id) values ('f3700000-0000-4000-8000-0000000000a1'), ('f3700000-0000-4000-8000-0000000000a2'), ('f3700000-0000-4000-8000-0000000000a3');
insert into public.staff_access_profiles(user_id, role, telegram_user_id) values
  ('f3700000-0000-4000-8000-0000000000a1', 'cleaner', null),
  ('f3700000-0000-4000-8000-0000000000a2', 'cleaner', null),
  ('f3700000-0000-4000-8000-0000000000a3', 'admin', 920000003);
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.staff_property_access(user_id, property_id) values
  ('f3700000-0000-4000-8000-0000000000a1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'),
  ('f3700000-0000-4000-8000-0000000000a2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '1900-01-01', 250, 250, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '1900-01-01');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-05-07', 650, 1000, 'zz baseline'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-05-07');
insert into public.cleaner_rate_schedule(property_id, effective_from, regular_rate, general_rate, transport_rate, note)
select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', date '2026-09-30', 500, 1000, 150, 'zz baseline (the migration inserts it where the property exists)'
where not exists (select 1 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30');

-- C owns two unpaid cleans (Oct 2, Oct 4) and one pending claim; D owns one clean and one claim.
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, last_guest_name, submitted_by_user_id) values
  ('f3700000-0000-4000-8000-0000000000b1', 'zz-s37-a', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', date '2026-10-02', 'turnover', 'Ana Reyes', 'f3700000-0000-4000-8000-0000000000a1'),
  ('f3700000-0000-4000-8000-0000000000b2', 'zz-s37-b', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', date '2026-10-04', 'turnover', null, 'f3700000-0000-4000-8000-0000000000a1'),
  ('f3700000-0000-4000-8000-0000000000b3', 'zz-s37-d', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Other', date '2026-10-03', 'turnover', 'Dan', 'f3700000-0000-4000-8000-0000000000a2');
insert into public.cleaning_expense_claims(id, property_id, cleaning_session_id, submitted_by_user_id, expense_date, description, amount) values
  ('f3700000-0000-4000-8000-0000000000c1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f3700000-0000-4000-8000-0000000000b1', 'f3700000-0000-4000-8000-0000000000a1', date '2026-10-02', 'zz 2 pcs KitKat for the guest', 40),
  ('f3700000-0000-4000-8000-0000000000c2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f3700000-0000-4000-8000-0000000000b3', 'f3700000-0000-4000-8000-0000000000a2', date '2026-10-03', 'zz D claim', 99);

-- 1-2 the rate rows
select ok((select regular_rate = 500 and general_rate = 1000 and transport_rate = 150 from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30'),
          'the 2026-09-30 schedule row is 500 / 1000 / 150');
select is((select transport_rate from public.cleaner_rate_schedule where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-05-07'),
          null::numeric, 'the 650 era row has no transport rate');

-- 3-9 candidates
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'cand', public.staff_pay_candidates_v1();
reset role;
select is((select v->>'ok' from _t where k = 'cand'), 'true', 'candidates answers the cleaner');
select is((select jsonb_array_length(v->'sessions') from _t where k = 'cand'), 2, 'candidates lists her two unpaid cleans, not another user''s');
select ok((select (v->'sessions'->0->>'base')::numeric = 500 and (v->'sessions'->0->>'transport')::numeric = 150 from _t where k = 'cand'), 'a clean after 2026-09-30 is 500 with a 150 transport toggle');
select is((select jsonb_array_length(v->'claims') from _t where k = 'cand'), 1, 'candidates lists her one claim only');
select is((select jsonb_typeof(v->'missing_reports') from _t where k = 'cand'), 'array', 'missing_reports is a list of dates');
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a3','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'cand_admin', public.staff_pay_candidates_v1();
reset role;
select is((select v->>'reason' from _t where k = 'cand_admin'), 'not_authorized', 'an admin without property access is not a candidate payee');
select ok(not has_function_privilege('anon', 'public.staff_pay_candidates_v1()', 'execute') and not has_function_privilege('anon', 'public.staff_pay_request_create_v1(jsonb,uuid[],jsonb,text)', 'execute'), 'anon cannot call candidates or create');

-- 10-17 create: A with transport + B + the claim + one 120 extra = 500+150+500+40+120
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'r1', public.staff_pay_request_create_v1(
  '[{"id":"f3700000-0000-4000-8000-0000000000b1","transport":true},{"id":"f3700000-0000-4000-8000-0000000000b2"}]'::jsonb,
  array['f3700000-0000-4000-8000-0000000000c1']::uuid[],
  '[{"description":"zz extra for the guest","amount":120}]'::jsonb,
  'zz-s37-key-0001');
insert into _t select 'r1_replay', public.staff_pay_request_create_v1(
  '[{"id":"f3700000-0000-4000-8000-0000000000b1","transport":true},{"id":"f3700000-0000-4000-8000-0000000000b2"}]'::jsonb,
  array['f3700000-0000-4000-8000-0000000000c1']::uuid[],
  '[{"description":"zz extra for the guest","amount":120}]'::jsonb,
  'zz-s37-key-0001');
reset role;
select is((select v->>'ok' || ' ' || (v->>'total') from _t where k = 'r1'), 'true 1310.00', 'create: 650 + 500 + 40 + 120 = 1,310');
select is((select count(*)::int from public.cleaning_sessions where pay_request_id = (select (v->>'request_id')::uuid from _t where k = 'r1')), 2, 'both cleans carry pay_request_id');
select is((select count(*)::int from public.cleaning_expense_claims where pay_request_id = (select (v->>'request_id')::uuid from _t where k = 'r1')), 2, 'the claim and the new extra claim carry pay_request_id');
select is((select count(*)::int from public.cleaning_expense_claims where description = 'zz extra for the guest' and amount = 120 and status = 'pending_review'), 1, 'the extra became a pending claim row');
select is((select jsonb_array_length(v->'lines') from _t where k = 'r1'), 4, 'the snapshot holds four lines');
select is((select v->'lines'->0->>'guest' from _t where k = 'r1'), 'Ana', 'the first clean line carries the guest first name');
select is((select (v->>'request_id') || (v->>'replay') from _t where k = 'r1_replay'), (select (v->>'request_id') || 'true' from _t where k = 'r1'), 'the same key replays the same request');
select is((select count(*)::int from public.staff_pay_requests where payee_user_id = 'f3700000-0000-4000-8000-0000000000a1'), 1, 'a replay writes no second request');

-- 18-24 refusals (each leaves nothing behind)
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, last_guest_name, submitted_by_user_id) values
  ('f3700000-0000-4000-8000-0000000000b4', 'zz-s37-old', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', date '2026-09-20', 'turnover', 'Old', 'f3700000-0000-4000-8000-0000000000a1');
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'taken', public.staff_pay_request_create_v1('[{"id":"f3700000-0000-4000-8000-0000000000b1"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-s37-key-0002');
insert into _t select 'notyours', public.staff_pay_request_create_v1('[{"id":"f3700000-0000-4000-8000-0000000000b3"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-s37-key-0003');
insert into _t select 'notransport', public.staff_pay_request_create_v1('[{"id":"f3700000-0000-4000-8000-0000000000b4","transport":true}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-s37-key-0004');
insert into _t select 'toomany', public.staff_pay_request_create_v1('[]'::jsonb, '{}'::uuid[],
  (select jsonb_agg(jsonb_build_object('description', 'zz extra ' || g, 'amount', 1)) from generate_series(1, 21) g), 'zz-s37-key-0005');
insert into _t select 'bigextra', public.staff_pay_request_create_v1('[]'::jsonb, '{}'::uuid[], '[{"description":"zz too much","amount":5001}]'::jsonb, 'zz-s37-key-0006');
insert into _t select 'otherreceipt', public.staff_pay_request_create_v1('[]'::jsonb, '{}'::uuid[],
  '[{"description":"zz receipt of another","amount":10,"receipt_path":"6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/f3700000-0000-4000-8000-0000000000a2/x/1-r.jpg"}]'::jsonb, 'zz-s37-key-0007');
insert into _t select 'dupclaim', public.staff_pay_request_create_v1('[]'::jsonb, array['f3700000-0000-4000-8000-0000000000c1']::uuid[], '[]'::jsonb, 'zz-s37-key-0008');
insert into _t select 'shortkey', public.staff_pay_request_create_v1('[{"id":"f3700000-0000-4000-8000-0000000000b4"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'short');
reset role;
select is((select v->>'reason' from _t where k = 'taken'), 'session_taken', 'a clean already in a request is session_taken');
select is((select v->>'reason' from _t where k = 'notyours'), 'session_not_yours', 'another user''s clean is session_not_yours');
select is((select v->>'reason' from _t where k = 'notransport'), 'transport_not_allowed', 'transport on a 650-era clean is refused');
select is((select v->>'reason' from _t where k = 'toomany'), 'too_many_lines', '21 lines is too_many_lines');
select is((select v->>'reason' from _t where k = 'bigextra'), 'bad_extra', 'an extra over 5,000 is bad_extra');
select is((select v->>'reason' from _t where k = 'otherreceipt'), 'bad_extra', 'a receipt path under another user''s folder is bad_extra');
select is((select v->>'reason' from _t where k = 'dupclaim'), 'claim_taken', 'a claim already in a request is claim_taken');
select is((select v->>'reason' from _t where k = 'shortkey'), 'bad_request', 'an idempotency key under 8 characters is bad_request');
select is((select count(*)::int from public.staff_pay_requests where payee_user_id = 'f3700000-0000-4000-8000-0000000000a1'), 1, 'no refusal wrote a request');
select is((select count(*)::int from public.cleaning_expense_claims where description like 'zz extra %' or description = 'zz too much' or description = 'zz receipt of another'), 1, 'no refusal left a claim row behind (only the first request''s extra exists)');

-- 25 own receipt path
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'ownreceipt', public.staff_pay_request_create_v1('[{"id":"f3700000-0000-4000-8000-0000000000b4"}]'::jsonb, '{}'::uuid[],
  '[{"description":"zz receipted extra","amount":30,"receipt_path":"6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/f3700000-0000-4000-8000-0000000000a1/f3700000-0000-4000-8000-0000000000e1/1-r.jpg"}]'::jsonb,
  'zz-s37-key-0009');
reset role;
select is((select receipt_path from public.cleaning_expense_claims where description = 'zz receipted extra'),
          '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/f3700000-0000-4000-8000-0000000000a1/f3700000-0000-4000-8000-0000000000e1/1-r.jpg', 'her own receipt path is stored on the claim row');
select is((select v->>'total' from _t where k = 'ownreceipt'), '680.00', 'a 650-era clean plus a 30 extra is 680');

-- 27-29 the guard trigger and the grants
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select throws_ok($$update public.cleaning_sessions set pay_request_id = null where id = 'f3700000-0000-4000-8000-0000000000b1'$$,
  '42501', 'pay_request_id moves only through the payment request RPCs', 'a cleaner cannot clear the lock on her own session');
select throws_ok($$insert into public.cleaning_sessions(submission_id, property_id, cleaner_name, submitted_by_user_id, pay_request_id)
  values ('zz-s37-ins', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', 'f3700000-0000-4000-8000-0000000000a1', 'f3700000-0000-4000-8000-0000000000f1')$$,
  '42501', 'pay_request_id moves only through the payment request RPCs', 'a cleaner cannot insert a session already locked');
reset role;
select ok(not has_function_privilege('authenticated', 'public.telegram_staff_pay_step_v1(uuid,text,bigint,text,jsonb)', 'execute')
      and not has_function_privilege('anon', 'public.telegram_staff_pay_step_v1(uuid,text,bigint,text,jsonb)', 'execute')
      and has_function_privilege('service_role', 'public.telegram_staff_pay_step_v1(uuid,text,bigint,text,jsonb)', 'execute'), 'the Telegram step is service_role only');
select ok(not has_function_privilege('authenticated', 'public.staff_pay_settle_v1(uuid,bigint,text,text,jsonb)', 'execute')
      and not has_function_privilege('authenticated', 'public.staff_pay_rate_v1(date)', 'execute'), 'the internal helpers have no API grant');
select ok(not has_table_privilege('authenticated', 'public.staff_pay_requests', 'select') and not has_table_privilege('anon', 'public.staff_pay_requests', 'select'), 'the request table is closed to the API roles');

-- 32-40 steps on R1 (1,310): pay, second pay, sent, cancel after sent, mismatch proof, not_sent after proof, direct paid without proof
select set_config('zz.r1', (select v->>'request_id' from _t where k = 'r1'), true);
insert into _t select 's_pay', public.telegram_staff_pay_step_v1(current_setting('zz.r1')::uuid, 'pay', 920000001, 'Marifel');
insert into _t select 's_pay2', public.telegram_staff_pay_step_v1(current_setting('zz.r1')::uuid, 'pay', 920000002, 'Lloyd');
select is((select v->>'status' from _t where k = 's_pay'), 'paying', 'pay: requested -> paying');
select is((select v->>'reason' from _t where k = 's_pay2'), 'not_open', 'a second pay is not_open');
insert into _t select 's_sent', public.telegram_staff_pay_step_v1(current_setting('zz.r1')::uuid, 'sent', 920000001, 'Marifel');
insert into _t select 's_cancel', public.telegram_staff_pay_step_v1(current_setting('zz.r1')::uuid, 'cancel', 920000001, 'Marifel');
select is((select v->>'reason' from _t where k = 's_cancel'), 'money_may_be_sent', 'cancel after "Yes, sent" is refused');
insert into _t select 's_proof_early', public.telegram_staff_pay_step_v1((select (v->>'request_id')::uuid from _t where k = 'ownreceipt'), 'proof', 920000001, 'Marifel',
  '{"file_unique_id":"zz-early","file_id":"x","sha256":"zz-sha-early","amount":680,"reference":"ZZREFEARLY","verdict":"match"}'::jsonb);
select is((select v->>'reason' from _t where k = 's_proof_early'), 'not_waiting_for_proof', 'a screenshot before pay and "Yes, sent" is refused');
insert into _t select 's_mismatch', public.telegram_staff_pay_step_v1(current_setting('zz.r1')::uuid, 'proof', 920000001, 'Marifel',
  '{"file_unique_id":"zz-file-1","file_id":"tg-file-1","sha256":"zz-sha-1","amount":1300,"reference":"ZZREF0001","read":{"amount":1300},"verdict":"mismatch"}'::jsonb);
select is((select v->>'status' || ' ' || (v->>'verdict') from _t where k = 's_mismatch'), 'paying mismatch', 'a mismatch screenshot leaves the request paying');
select is((select proof_file_unique_id || ' ' || proof_amount::text from public.staff_pay_requests where id = current_setting('zz.r1')::uuid), 'zz-file-1 1300.00', 'the mismatching screenshot is stored');
select is((select count(*)::int from public.transactions where external_ref in ('cleanfee:f3700000-0000-4000-8000-0000000000b1', 'cleanfee:f3700000-0000-4000-8000-0000000000b2')), 0, 'nothing reached the ledger on a mismatch');
insert into _t select 's_notsent', public.telegram_staff_pay_step_v1(current_setting('zz.r1')::uuid, 'not_sent', 920000001, 'Marifel');
select is((select v->>'reason' from _t where k = 's_notsent'), 'proof_already_sent', 'No, not sent is refused once a screenshot is stored');
select throws_ok($$update public.staff_pay_requests set status = 'paid' where id = current_setting('zz.r1')::uuid$$, '23514', null, 'PAID without a verdict, paid_at and a payer is refused by the table');

-- 41-52 settle by a matching screenshot: the same file as an earlier one is refused, then the match pays
insert into _t select 's_match', public.telegram_staff_pay_step_v1(current_setting('zz.r1')::uuid, 'proof', 920000001, 'Marifel',
  '{"file_unique_id":"zz-file-2","file_id":"tg-file-2","sha256":"zz-sha-2","amount":1310,"reference":"ZZREF0001","read":{"amount":1310},"verdict":"match"}'::jsonb);
select is((select v->>'status' || ' ' || (v->>'verdict') from _t where k = 's_match'), 'paid match', 'a matching screenshot settles the request');
select is((select count(*)::int from public.transactions where source = 'cleaner_fee' and category = 'cleaning' and external_ref in ('cleanfee:f3700000-0000-4000-8000-0000000000b1', 'cleanfee:f3700000-0000-4000-8000-0000000000b2')), 2, 'two cleaning ledger rows, cleanfee:<session>');
select ok((select count(*) = 2 and sum(gross_amount) = 1150 and max(gross_amount) = 650 from public.transactions where external_ref in ('cleanfee:f3700000-0000-4000-8000-0000000000b1', 'cleanfee:f3700000-0000-4000-8000-0000000000b2')), 'the transport clean is 650, the other 500');
select is((select count(*)::int from public.transactions where source = 'cleaner_fee' and category = 'supplies' and external_ref like 'claim:%' and external_ref in (select 'claim:' || id from public.cleaning_expense_claims where pay_request_id = current_setting('zz.r1')::uuid)), 2, 'two supplies ledger rows, claim:<id>');
select is((select count(*)::int from public.cleaning_sessions where pay_request_id = current_setting('zz.r1')::uuid and fee_paid_at is not null and fee_txn_id is not null and fee_amount in (500, 650)), 2, 'both sessions carry fee_amount, fee_paid_at and fee_txn_id');
select is((select count(*)::int from public.cleaning_expense_claims where pay_request_id = current_setting('zz.r1')::uuid and status = 'paid' and review_note like 'Paid in request %'), 2, 'both claims are paid with a note naming the request');
select is((select status || ' ' || proof_verdict || ' ' || coalesce(paid_by_user_id::text, 'unmapped') || ' ' || paid_by_name from public.staff_pay_requests where id = current_setting('zz.r1')::uuid), 'paid match unmapped Marifel', 'an unmapped Finance member may confirm (D-298.2)');
select ok((select count(*) from public.admin_audit_log where entity_table = 'staff_pay_requests' and entity_id = current_setting('zz.r1')::uuid) >= 2, 'the request transitions are in the audit log');
select is((select logged_by from public.transactions where external_ref = 'cleanfee:f3700000-0000-4000-8000-0000000000b1'), 'Telegram: Marifel', 'the ledger row names the person who confirmed');

-- 50-52 a second request cannot reuse the first one's reference or file (R2 = the 650-era clean)
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, last_guest_name, submitted_by_user_id) values
  ('f3700000-0000-4000-8000-0000000000b7', 'zz-s37-g', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', date '2026-09-21', 'turnover', 'Gus', 'f3700000-0000-4000-8000-0000000000a1');
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'r2', public.staff_pay_request_create_v1('[{"id":"f3700000-0000-4000-8000-0000000000b7"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-s37-key-0010');
reset role;
select set_config('zz.r2', (select v->>'request_id' from _t where k = 'r2'), true);
insert into _t select 'r2_pay', public.telegram_staff_pay_step_v1(current_setting('zz.r2')::uuid, 'pay', 920000001, 'Marifel');
insert into _t select 'r2_sent', public.telegram_staff_pay_step_v1(current_setting('zz.r2')::uuid, 'sent', 920000001, 'Marifel');
insert into _t select 'r2_dup', public.telegram_staff_pay_step_v1(current_setting('zz.r2')::uuid, 'proof', 920000001, 'Marifel',
  '{"file_unique_id":"zz-file-9","file_id":"tg-file-9","sha256":"zz-sha-9","amount":650,"reference":"ZZREF0001","verdict":"match"}'::jsonb);
select is((select v->>'reason' || ' ' || (v->>'other_ref') from _t where k = 'r2_dup'), 'duplicate_proof ' || (select ref from public.staff_pay_requests where id = current_setting('zz.r1')::uuid), 'a reused reference is duplicate_proof naming the other request');
insert into _t select 'r2_dupfile', public.telegram_staff_pay_step_v1(current_setting('zz.r2')::uuid, 'proof', 920000001, 'Marifel',
  '{"file_unique_id":"zz-file-2","file_id":"tg-file-9","sha256":"zz-sha-9b","amount":650,"reference":"ZZREF0009","verdict":"match"}'::jsonb);
select is((select v->>'reason' from _t where k = 'r2_dupfile'), 'duplicate_proof', 'a reused Telegram file is duplicate_proof');
insert into _t select 'r2_override_early', public.telegram_staff_pay_step_v1(current_setting('zz.r2')::uuid, 'override', 920000001, 'Marifel');
select is((select v->>'reason' from _t where k = 'r2_override_early'), 'no_screenshot', 'override without a stored screenshot is no_screenshot');

-- 53-55 override after a mismatch pays with verdict override, and a mapped admin is recorded as the payer
insert into _t select 'r2_unread', public.telegram_staff_pay_step_v1(current_setting('zz.r2')::uuid, 'proof', 920000003, 'Admin',
  '{"file_unique_id":"zz-file-10","file_id":"tg-file-10","sha256":"zz-sha-10","verdict":"unread"}'::jsonb);
insert into _t select 'r2_override', public.telegram_staff_pay_step_v1(current_setting('zz.r2')::uuid, 'override', 920000003, 'Admin');
select is((select v->>'status' || ' ' || (v->>'verdict') from _t where k = 'r2_override'), 'paid override', 'Amount is right pays with verdict override');
select is((select paid_by_user_id from public.staff_pay_requests where id = current_setting('zz.r2')::uuid), 'f3700000-0000-4000-8000-0000000000a3'::uuid, 'a mapped owner/admin is recorded as paid_by_user_id');
select is((select proof_amount from public.staff_pay_requests where id = current_setting('zz.r2')::uuid), null::numeric, 'an unreadable screenshot stores no amount');

-- 56-58 cancel before "Yes, sent" frees the clean; settle refuses when a clean was paid another way
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, cleaning_type, last_guest_name, submitted_by_user_id) values
  ('f3700000-0000-4000-8000-0000000000b5', 'zz-s37-e', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', date '2026-10-06', 'turnover', 'Eve', 'f3700000-0000-4000-8000-0000000000a1'),
  ('f3700000-0000-4000-8000-0000000000b6', 'zz-s37-f', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-Cleaner', date '2026-10-07', 'turnover', 'Fay', 'f3700000-0000-4000-8000-0000000000a1');
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'r3', public.staff_pay_request_create_v1('[{"id":"f3700000-0000-4000-8000-0000000000b5"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-s37-key-0011');
insert into _t select 'r4', public.staff_pay_request_create_v1('[{"id":"f3700000-0000-4000-8000-0000000000b6"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-s37-key-0012');
reset role;
insert into _t select 'r3_cancel', public.telegram_staff_pay_step_v1((select (v->>'request_id')::uuid from _t where k = 'r3'), 'cancel', 920000001, 'Marifel');
select is((select v->>'status' from _t where k = 'r3_cancel') || ' ' || (select pay_request_id is null from public.cleaning_sessions where id = 'f3700000-0000-4000-8000-0000000000b5')::text, 'cancelled true', 'cancel before "Yes, sent" frees the clean');
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'cand2', public.staff_pay_candidates_v1();
insert into _t select 'r3_again', public.staff_pay_request_create_v1('[{"id":"f3700000-0000-4000-8000-0000000000b5"}]'::jsonb, '{}'::uuid[], '[]'::jsonb, 'zz-s37-key-0011');
reset role;
select ok((select v->'sessions' @> '[{"id":"f3700000-0000-4000-8000-0000000000b5"}]'::jsonb from _t where k = 'cand2'), 'the freed clean is listed again');
select is((select v->>'reason' from _t where k = 'r3_again'), 'key_cancelled', 'a cancelled request keeps its key, so a retry must use a new one');
update public.cleaning_sessions set fee_paid_at = now() where id = 'f3700000-0000-4000-8000-0000000000b6';
select set_config('zz.r4', (select v->>'request_id' from _t where k = 'r4'), true);
insert into _t select 'r4_pay', public.telegram_staff_pay_step_v1(current_setting('zz.r4')::uuid, 'pay', 920000001, 'Marifel');
insert into _t select 'r4_sent', public.telegram_staff_pay_step_v1(current_setting('zz.r4')::uuid, 'sent', 920000001, 'Marifel');
select set_config('zz.tx_before', (select count(*)::text from public.transactions), true);
insert into _t select 'r4_proof', public.telegram_staff_pay_step_v1(current_setting('zz.r4')::uuid, 'proof', 920000001, 'Marifel',
  '{"file_unique_id":"zz-file-11","file_id":"tg-file-11","sha256":"zz-sha-11","amount":500,"reference":"ZZREF0011","verdict":"match"}'::jsonb);
select is((select v->>'reason' || ' ' || (v->>'date') from _t where k = 'r4_proof'), 'already_paid 2026-10-07', 'settle refuses when a clean was paid another way');
select is((select count(*)::text from public.transactions), current_setting('zz.tx_before'), 'a refused settle wrote nothing');
select is((select status || ' ' || coalesce(proof_file_unique_id, 'none') from public.staff_pay_requests where id = current_setting('zz.r4')::uuid), 'paying none', 'a refused settle stores no screenshot and leaves the request paying');

-- 63 the awaiting_reply row for the screenshot question still inserts (the kind CHECK is untouched)
select lives_ok($$insert into public.telegram_pending(chat_id, kind, payload) values (-900000004, 'awaiting_reply', '{"flow":"payreq_proof","from_id":1,"rid":"x"}')$$, 'an awaiting_reply row with flow payreq_proof inserts');

-- 64-66 staff_details: the payout QR saves through the RPC, history keeps a masked marker, the cleaner is refused, a malformed value is refused
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a3','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
insert into _t select 'qr', public.save_staff_details_v1('f3700000-0000-4000-8000-0000000000a1'::uuid, '{"payout_qrph":"0002010102116304ABCD"}'::jsonb, null, 'zz payout QR');
select throws_ok($$select public.save_staff_details_v1('f3700000-0000-4000-8000-0000000000a1'::uuid, '{"payout_qrph":"000201zz"}'::jsonb, null, 'zz bad')$$, '23514', null, 'a value that does not end 6304 + four hex characters is refused');
select set_config('request.jwt.claims', json_build_object('sub','f3700000-0000-4000-8000-0000000000a1','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select throws_ok($$select public.save_staff_details_v1('f3700000-0000-4000-8000-0000000000a1'::uuid, '{"payout_qrph":"0002010102116304ABCD"}'::jsonb, null, 'zz self')$$, '42501', 'manage_staff denied', 'the cleaner cannot save her own payout QR');
reset role;
select is((select payout_qrph from public.staff_details where user_id = 'f3700000-0000-4000-8000-0000000000a1'), '0002010102116304ABCD', 'the payout QR is saved');
select is((select after_state->>'payout_qrph' from public.staff_details_history where user_id = 'f3700000-0000-4000-8000-0000000000a1' order by changed_at desc limit 1), '[set ABCD]', 'the history row holds a masked marker, never the payload');
select ok(has_column_privilege('service_role', 'public.staff_details', 'payout_qrph', 'select') and not has_column_privilege('service_role', 'public.staff_details', 'id_number', 'select'), 'service_role reads the payout QR column and nothing else of staff_details');

select * from finish();
rollback;
