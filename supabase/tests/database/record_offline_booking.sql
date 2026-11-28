-- Release record_offline_booking_20261211 (lane A): record_offline_booking_v1, the channel column and the one-predicate engine patch.
-- Contract: docs/record-booking-20261128/contract.md B1-B3. Synthetic fixtures only (public repo), on a property private to this suite; every row is
-- created here (the CI baseline database has no production rows) and goes with the closing rollback. Rows are inserted as the session owner, the RPC is
-- called as authenticated through pg_temp.rec, and results are read back as the owner.
--   users   b1 owner  b2 admin  b3 finance  b4 cleaner (all with access to the property)
--   windows (days from today)  300 Airbnb stay  310 direct hold  320 brownout  330 unexplained block  340 assumed block  350 owner_use block
--           360 replay  370+380 reference reuse  390 cash without note  400 partly paid  410 confirmation off  420/430/440 thread routing
--           450+455 thread save  460 site confirm  470 past stay thread  480 dates  490 validation
begin;
select plan(55);

-- Same numbers as run_system_verifier_v1 reads: no preparation night, so a block that is one night longer than the stay is V1m.
insert into public.app_settings(key, value) values ('airbnb_prep_nights', '0'::jsonb) on conflict (key) do update set value = excluded.value;

-- shape, grants, schema ------------------------------------------------------------------------------------------------------------------------------
select has_function('public', 'record_offline_booking_v1',
  array['uuid','date','date','text','text','text','text','integer','numeric','numeric','text','text','text','text','boolean','text[]','text'], 'record_offline_booking_v1 exists');
select ok(has_function_privilege('authenticated', 'public.record_offline_booking_v1(uuid,date,date,text,text,text,text,integer,numeric,numeric,text,text,text,text,boolean,text[],text)', 'execute')
      and not has_function_privilege('anon', 'public.record_offline_booking_v1(uuid,date,date,text,text,text,text,integer,numeric,numeric,text,text,text,text,boolean,text[],text)', 'execute')
      and not has_function_privilege('service_role', 'public.record_offline_booking_v1(uuid,date,date,text,text,text,text,integer,numeric,numeric,text,text,text,text,boolean,text[],text)', 'execute'),
  'grants: authenticated only, never anon or service_role');
select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.record_offline_booking_v1(uuid,date,date,text,text,text,text,integer,numeric,numeric,text,text,text,text,boolean,text[],text)'::regprocedure),
  'security definer with an empty search_path');
select ok(not has_function_privilege('anon', 'public.decide_direct_booking_without_finance_review(uuid,text,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.decide_direct_booking_without_finance_review(uuid,text,text)', 'execute')
      and not has_function_privilege('service_role', 'public.decide_direct_booking_without_finance_review(uuid,text,text)', 'execute'),
  'the engine stays unreachable for every client role');
select is((select (length(prosrc) - length(replace(prosrc, 'cascade.offline_booking_id', ''))) / length('cascade.offline_booking_id')
             from pg_proc where oid = 'public.decide_direct_booking_without_finance_review(uuid,text,text)'::regprocedure),
  1, 'the engine carries the offline setting exactly once');
select is((select column_default || '|' || is_nullable from information_schema.columns
            where table_schema = 'public' and table_name = 'booking_inquiries' and column_name = 'channel'),
  '''site''::text|NO', 'booking_inquiries.channel defaults to site and is not null');

-- fixtures -------------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('ab0f0000-0000-4000-8000-0000000000a1', 'Synthetic Record Offline', true);
insert into auth.users(id) values ('ab0f0000-0000-4000-8000-0000000000b1'), ('ab0f0000-0000-4000-8000-0000000000b2'),
                                  ('ab0f0000-0000-4000-8000-0000000000b3'), ('ab0f0000-0000-4000-8000-0000000000b4');
insert into public.staff_access_profiles(user_id, role, note) values
  ('ab0f0000-0000-4000-8000-0000000000b1', 'owner',   'Owner B1'),
  ('ab0f0000-0000-4000-8000-0000000000b2', 'admin',   'Admin B2'),
  ('ab0f0000-0000-4000-8000-0000000000b3', 'finance', 'Finance B3'),
  ('ab0f0000-0000-4000-8000-0000000000b4', 'cleaner', 'Cleaner B4');
insert into public.staff_property_access(user_id, property_id)
select u, 'ab0f0000-0000-4000-8000-0000000000a1'::uuid
  from unnest(array['ab0f0000-0000-4000-8000-0000000000b1', 'ab0f0000-0000-4000-8000-0000000000b2',
                    'ab0f0000-0000-4000-8000-0000000000b3', 'ab0f0000-0000-4000-8000-0000000000b4']::uuid[]) u;

-- d(n): n days from today; bid(key): the booking id the function derives from a key; ref8: the booking reference
create function pg_temp.d(n integer) returns date language sql as $$ select current_date + n $$;
create function pg_temp.bid(k text) returns uuid language sql as $$ select md5('offline-v1|' || k)::uuid $$;
create function pg_temp.ref8(k text) returns text language sql as $$ select upper(left(md5('offline-v1|' || k)::uuid::text, 8)) $$;

-- The RPC as a signed-in user. Defaults: owner b1, a two-night GCash booking paid in full on day 300; p_over replaces any key.
create function pg_temp.rec(p_over jsonb default '{}'::jsonb, p_user uuid default 'ab0f0000-0000-4000-8000-0000000000b1') returns jsonb language plpgsql as $f$
declare
  a jsonb := jsonb_build_object(
    'property', 'ab0f0000-0000-4000-8000-0000000000a1', 'checkin', (current_date + 300)::text, 'checkout', (current_date + 302)::text,
    'channel', 'facebook', 'name', 'Synthetic Guest', 'phone', '09171234567', 'email', null, 'pax', 2, 'total', 4000, 'paid', 4000,
    'method', 'gcash_qr', 'ref', 'GCASH1234567', 'note', null, 'psid', null, 'send', true, 'override', null, 'key', 'rb-key-default-0001') || p_over;
  r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
  execute 'set local role authenticated';
  r := public.record_offline_booking_v1(
    (a ->> 'property')::uuid, (a ->> 'checkin')::date, (a ->> 'checkout')::date, a ->> 'channel', a ->> 'name', a ->> 'phone', a ->> 'email',
    (a ->> 'pax')::integer, (a ->> 'total')::numeric, (a ->> 'paid')::numeric, a ->> 'method', a ->> 'ref', a ->> 'note', a ->> 'psid',
    (a ->> 'send')::boolean,
    case when jsonb_typeof(a -> 'override') = 'array' then (select array_agg(x) from jsonb_array_elements_text(a -> 'override') x) end,
    a ->> 'key');
  execute 'reset role';
  return r;
end $f$;

-- Rows a booking leaves behind, by key.
create function pg_temp.rows_of(k text) returns text language sql as $$
  select (select count(*) from public.booking_inquiries where id = pg_temp.bid(k))::text || '/'
      || (select count(*) from public.calendar_events where uid in ('direct:' || pg_temp.bid(k)::text, 'cascade-direct-' || pg_temp.bid(k)::text))::text || '/'
      || (select count(*) from public.transactions where external_ref = pg_temp.bid(k)::text)::text
$$;

-- 1. gate --------------------------------------------------------------------------------------------------------------------------------------------
select is(pg_temp.rec('{"key":"rb-key-gate-cleaner-1"}', 'ab0f0000-0000-4000-8000-0000000000b4') ->> 'outcome', 'denied', 'refuses a non-admin');
select is(pg_temp.rec('{"key":"rb-key-gate-finance-1"}', 'ab0f0000-0000-4000-8000-0000000000b3') ->> 'outcome', 'denied', 'refuses finance role');
select is(pg_temp.rows_of('rb-key-gate-cleaner-1') || '|' || pg_temp.rows_of('rb-key-gate-finance-1'), '0/0/0|0/0/0', 'a refused caller writes nothing');
select is(pg_temp.rec('{"key":"rb-key-gate-anon-0001"}', '00000000-0000-4000-8000-000000000000') ->> 'outcome', 'denied', 'a user without a staff profile is denied');

-- 2. conflicts ---------------------------------------------------------------------------------------------------------------------------------------
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, guest_name) values
  ('ab0f0000-0000-4000-8000-0000000000a1', 'rb-airbnb-stay@airbnb.com', 'airbnb', 'confirmed', pg_temp.d(300), pg_temp.d(304), 'Synthetic Airbnb'),
  ('ab0f0000-0000-4000-8000-0000000000a1', 'direct:ab0f0d01-0000-4000-8000-000000000001', 'direct', 'blocked', pg_temp.d(310), pg_temp.d(313), 'Synthetic Hold');
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, guest_name) values
  ('ab0f0000-0000-4000-8000-0000000000a1', 'brownout:rb-synthetic-1', 'manual', 'blocked', pg_temp.d(320), pg_temp.d(322), 'Brownout');
select is(pg_temp.rec('{"key":"rb-key-conflict-airbnb","checkin":"d301","checkout":"d303"}'::jsonb || jsonb_build_object('checkin', pg_temp.d(301)::text, 'checkout', pg_temp.d(303)::text)) ->> 'reason',
  'airbnb_stay', 'refuses overlap with a confirmed Airbnb stay');
select is(pg_temp.rec(jsonb_build_object('key', 'rb-key-conflict-direct', 'checkin', pg_temp.d(311)::text, 'checkout', pg_temp.d(312)::text)) ->> 'reason',
  'direct_booking', 'refuses overlap with a live direct row');
select is(pg_temp.rec(jsonb_build_object('key', 'rb-key-conflict-brown1', 'checkin', pg_temp.d(320)::text, 'checkout', pg_temp.d(321)::text)) ->> 'reason',
  'brownout_hold', 'refuses a brownout hold');
select is(pg_temp.rows_of('rb-key-conflict-airbnb') || '|' || pg_temp.rows_of('rb-key-conflict-direct') || '|' || pg_temp.rows_of('rb-key-conflict-brown1'),
  '0/0/0|0/0/0|0/0/0', 'a conflict writes nothing');
-- checkout day = next check-in day is not an overlap (the stay may start the morning the Airbnb stay ends)
select is(pg_temp.rec(jsonb_build_object('key', 'rb-key-edge-checkout', 'checkin', pg_temp.d(304)::text, 'checkout', pg_temp.d(306)::text, 'ref', 'EDGE12345678')) ->> 'outcome',
  'recorded', 'a stay may start on the day an Airbnb stay checks out');

-- 3. Airbnb blocks -----------------------------------------------------------------------------------------------------------------------------------
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, recon_status, block_reason, block_reason_source) values
  ('ab0f0000-0000-4000-8000-0000000000a1', 'rb-block-unexplained@airbnb.com', 'airbnb', 'blocked', pg_temp.d(330), pg_temp.d(333), 'pending', null, null),
  ('ab0f0000-0000-4000-8000-0000000000a1', 'rb-block-assumed@airbnb.com',     'airbnb', 'blocked', pg_temp.d(340), pg_temp.d(342), 'pending', 'maintenance', 'assumed'),
  ('ab0f0000-0000-4000-8000-0000000000a1', 'rb-block-owner@airbnb.com',       'airbnb', 'blocked', pg_temp.d(350), pg_temp.d(352), 'admin_block', 'owner_use', 'staff');

create temp table rb_r(k text primary key, r jsonb);
insert into rb_r values ('unexplained', pg_temp.rec(jsonb_build_object('key', 'rb-key-block-unexpl1', 'checkin', pg_temp.d(330)::text, 'checkout', pg_temp.d(333)::text, 'ref', 'UNEXP1234567')));
select is((select r ->> 'outcome' from rb_r where k = 'unexplained'), 'recorded', 'accepts over an unexplained Airbnb block');
select is((select block_reason || '|' || block_reason_source || '|' || recon_status || '|' || block_note || '|' || coalesce(block_answered_by::text, '-') || '|' || coalesce(block_answered_at::text, '-')
             from public.calendar_events where uid = 'rb-block-unexplained@airbnb.com'),
  'direct|auto|skipped|DIR ' || pg_temp.ref8('rb-key-block-unexpl1') || ' confirmed|-|-',
  'accepts over an unexplained Airbnb block and relabels it DIR <ref> confirmed');
select is((select r -> 'blocks_relabelled' from rb_r where k = 'unexplained'), '["rb-block-unexplained@airbnb.com"]'::jsonb, 'the reply names the relabelled block');
select is((select (r -> 'airbnb_nights_uncovered')::text || '|' || (r ->> 'block_runs_past_stay') from rb_r where k = 'unexplained'), '[]|false',
  'a block that matches the stay leaves no night uncovered and does not run past it');

insert into rb_r values ('assumed', pg_temp.rec(jsonb_build_object('key', 'rb-key-block-assume1', 'checkin', pg_temp.d(340)::text, 'checkout', pg_temp.d(342)::text, 'ref', 'ASSUM1234567')));
select is((select (r ->> 'outcome') || '|' || (select block_reason || '|' || block_reason_source from public.calendar_events where uid = 'rb-block-assumed@airbnb.com')
             from rb_r where k = 'assumed'),
  'recorded|direct|auto', 'accepts over an assumed-maintenance block');

insert into rb_r values ('owner_noover', pg_temp.rec(jsonb_build_object('key', 'rb-key-block-owner-1', 'checkin', pg_temp.d(350)::text, 'checkout', pg_temp.d(352)::text, 'ref', 'OWNER1234567')));
select is((select (r ->> 'outcome') || '|' || (r ->> 'reason') || '|' || (r -> 'blocks' -> 0 ->> 'uid') || '|' || (r -> 'blocks' -> 0 ->> 'reason')
             from rb_r where k = 'owner_noover'),
  'conflict|labelled_block|rb-block-owner@airbnb.com|owner_use', 'refuses a staff-labelled owner_use block without override');
select is((select block_reason || '|' || block_reason_source from public.calendar_events where uid = 'rb-block-owner@airbnb.com') || '|' || pg_temp.rows_of('rb-key-block-owner-1'),
  'owner_use|staff|0/0/0', 'the refused block is untouched and nothing is written');
select is(pg_temp.rec(jsonb_build_object('key', 'rb-key-block-owner-2', 'checkin', pg_temp.d(350)::text, 'checkout', pg_temp.d(352)::text, 'ref', 'OWNER7654321',
                                         'override', jsonb_build_array('some-other-uid@airbnb.com'))) ->> 'reason',
  'labelled_block', 'an override list that does not name the block does not help');
select is(pg_temp.rec(jsonb_build_object('key', 'rb-key-block-owner-3', 'checkin', pg_temp.d(350)::text, 'checkout', pg_temp.d(352)::text, 'ref', 'OWNER1357911',
                                         'override', jsonb_build_array('rb-block-owner@airbnb.com'))) ->> 'outcome',
  'recorded', 'accepts it with the uid in the override list');
select is((select block_reason || '|' || block_reason_source from public.calendar_events where uid = 'rb-block-owner@airbnb.com'), 'direct|auto', 'the overridden block is relabelled');

-- 4. replay, rollback, money -------------------------------------------------------------------------------------------------------------------------
create temp table rb_replay(n int primary key, r jsonb);
insert into rb_replay values (1, pg_temp.rec(jsonb_build_object('key', 'rb-key-replay-0001', 'checkin', pg_temp.d(360)::text, 'checkout', pg_temp.d(362)::text, 'ref', 'REPLAY123456')));
insert into rb_replay values (2, pg_temp.rec(jsonb_build_object('key', 'rb-key-replay-0001', 'checkin', pg_temp.d(360)::text, 'checkout', pg_temp.d(362)::text, 'ref', 'REPLAY123456')));
select is((select (r ->> 'already_processed') from rb_replay where n = 1) || '|' || (select (r ->> 'already_processed') || '|' || (r ->> 'outcome') from rb_replay where n = 2)
          || '|' || ((select r ->> 'booking_id' from rb_replay where n = 1) = (select r ->> 'booking_id' from rb_replay where n = 2))::text,
  'false|true|recorded|true', 'a replay answers with the stored booking');
select is(pg_temp.rows_of('rb-key-replay-0001')
          || '|' || (select count(*) from public.payment_evidence_candidates where booking_id = pg_temp.bid('rb-key-replay-0001'))::text
          || '|' || (select count(*) from public.booking_decisions where booking_id = pg_temp.bid('rb-key-replay-0001'))::text,
  '1/1/1|1|1', 'same key twice is one booking and one income row (and one evidence row, one decision)');

-- reference reuse: booking A takes the reference, booking B (over an unexplained block) is refused and nothing of it stays
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, recon_status) values
  ('ab0f0000-0000-4000-8000-0000000000a1', 'rb-block-reuse@airbnb.com', 'airbnb', 'blocked', pg_temp.d(380), pg_temp.d(382), 'pending');
select is(pg_temp.rec(jsonb_build_object('key', 'rb-key-reuse-first-A', 'checkin', pg_temp.d(370)::text, 'checkout', pg_temp.d(372)::text, 'ref', 'REUSE1234567')) ->> 'outcome',
  'recorded', 'the first booking with a reference is recorded');
insert into rb_r values ('reuse', pg_temp.rec(jsonb_build_object('key', 'rb-key-reuse-second-B', 'checkin', pg_temp.d(380)::text, 'checkout', pg_temp.d(382)::text, 'ref', 'REUSE1234567')));
select is((select (r ->> 'outcome') || '|' || (r ->> 'prior_ref') from rb_r where k = 'reuse'), 'reference_reused|' || pg_temp.ref8('rb-key-reuse-first-A'),
  'a reference already used on another booking is refused and names it');
select is(pg_temp.rows_of('rb-key-reuse-second-B') || '|' || (select coalesce(block_reason, 'none') || '|' || recon_status from public.calendar_events where uid = 'rb-block-reuse@airbnb.com')
          || '|' || (select count(*) from public.payment_evidence_candidates where booking_id = pg_temp.bid('rb-key-reuse-second-B'))::text
          || '|' || (select count(*) from public.booking_decisions where booking_id = pg_temp.bid('rb-key-reuse-second-B'))::text,
  '0/0/0|none|pending|0|0', 'reference reused rolls back the hold, the inquiry, the income row and the block label');

insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, recon_status) values
  ('ab0f0000-0000-4000-8000-0000000000a1', 'rb-block-cash@airbnb.com', 'airbnb', 'blocked', pg_temp.d(390), pg_temp.d(392), 'pending');
insert into rb_r values ('cash', pg_temp.rec(jsonb_build_object('key', 'rb-key-cash-nonote-1', 'checkin', pg_temp.d(390)::text, 'checkout', pg_temp.d(392)::text, 'method', 'cash', 'ref', null, 'note', null)));
select is((select r ->> 'outcome' from rb_r where k = 'cash') || '|' || pg_temp.rows_of('rb-key-cash-nonote-1')
          || '|' || (select coalesce(block_reason, 'none') from public.calendar_events where uid = 'rb-block-cash@airbnb.com'),
  'note_required|0/0/0|none', 'cash without a note returns note_required and writes nothing');
select is(pg_temp.rec(jsonb_build_object('key', 'rb-key-cash-withnote1', 'checkin', pg_temp.d(390)::text, 'checkout', pg_temp.d(392)::text, 'method', 'cash', 'ref', null,
                                         'note', 'cash at the desk, Marifel received')) ->> 'outcome',
  'recorded', 'cash with a note is recorded without a reference');

insert into rb_r values ('partly', pg_temp.rec(jsonb_build_object('key', 'rb-key-partly-paid-1', 'checkin', pg_temp.d(400)::text, 'checkout', pg_temp.d(404)::text,
                                                                   'total', 6000, 'paid', 2500, 'method', 'bank', 'ref', 'BANK12345678')));
select is((select (r ->> 'outcome') || '|' || (r ->> 'balance') from rb_r where k = 'partly'), 'recorded|3500.00', 'a partly paid booking answers with the balance owed');
select is((select b.deposit_amount::text || '|' || b.total_amount::text || '|' || b.status || '|' || b.channel from public.booking_inquiries b where b.id = pg_temp.bid('rb-key-partly-paid-1'))
          || '|' || (select t.gross_amount::text || '|' || t.status || '|' || t.txn_type || '|' || t.logged_by || '|' || t.transaction_date::text from public.transactions t where t.external_ref = pg_temp.bid('rb-key-partly-paid-1')::text),
  '2500.00|6000.00|confirmed|facebook|6000.00|confirmed|income|record_offline_booking_v1|' || pg_temp.d(400)::text,
  'partly paid stores deposit_amount = paid and income = total');

-- 5. confirmation off ---------------------------------------------------------------------------------------------------------------------------------
select pg_temp.rec(jsonb_build_object('key', 'rb-key-confirm-off-01', 'checkin', pg_temp.d(410)::text, 'checkout', pg_temp.d(412)::text, 'send', false, 'ref', 'CONFOFF12345'));
select is((select channel || '|' || status || '|' || detail from public.guest_message_log where booking_id = pg_temp.bid('rb-key-confirm-off-01') and message_key = 'confirmation'),
  'card_only|skipped|recorded offline: host confirmed in the chat', 'confirmation off writes the lock row');
select is((select count(*)::int from public.due_guest_messages_v1() d where d.booking_id = pg_temp.bid('rb-key-confirm-off-01') and d.message_key = 'confirmation'), 0,
  'confirmation off: due_guest_messages_v1 omits confirmation');
select is((select count(*)::int from public.due_guest_messages_v1() d where d.booking_id = pg_temp.bid('rb-key-partly-paid-1') and d.message_key = 'confirmation'), 1,
  'confirmation on: due_guest_messages_v1 still lists it, and no lock row was written');

-- 6. Messenger threads --------------------------------------------------------------------------------------------------------------------------------
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, pax, status, source, total_amount, deposit_amount) values
  ('ab0f0c01-0000-4000-8000-000000000001', 'ab0f0000-0000-4000-8000-0000000000a1', 'Synthetic Pending', '09170000001', pg_temp.d(420), pg_temp.d(422), 2, 'pending',   'direct', 2000, 1000),
  ('ab0f0c02-0000-4000-8000-000000000002', 'ab0f0000-0000-4000-8000-0000000000a1', 'Synthetic Staying', '09170000002', pg_temp.d(430), pg_temp.d(436), 2, 'confirmed', 'direct', 6000, 3000),
  ('ab0f0c03-0000-4000-8000-000000000003', 'ab0f0000-0000-4000-8000-0000000000a1', 'Synthetic Past',    '09170000003', pg_temp.d(-14), pg_temp.d(-10), 2, 'confirmed', 'direct', 4000, 2000);
insert into public.concierge_threads(psid, guest_name, booking_flow) values
  ('rb-psid-pending', 'Synthetic Pending', '{"step":"await_receipt","booking_id":"ab0f0c01-0000-4000-8000-000000000001"}'::jsonb),
  ('rb-psid-linked',  'Synthetic Staying', '{"step":"confirmed","booking_id":"ab0f0c02-0000-4000-8000-000000000002"}'::jsonb),
  ('rb-psid-past',    'Synthetic Past',    '{"step":"confirmed","booking_id":"ab0f0c03-0000-4000-8000-000000000003"}'::jsonb),
  ('rb-psid-save',    'Synthetic Save',    '{"step":"await_receipt","lang":"tl"}'::jsonb),
  ('rb-psid-junk',    'Synthetic Junk',    '{"step":"await_receipt","booking_id":"not-a-uuid"}'::jsonb);
insert into rb_r values ('t_pending', pg_temp.rec(jsonb_build_object('key', 'rb-key-thread-pend-01', 'checkin', pg_temp.d(440)::text, 'checkout', pg_temp.d(442)::text, 'psid', 'rb-psid-pending', 'ref', 'THRPEND12345')));
select is((select (r ->> 'outcome') || '|' || (r ->> 'booking_id') from rb_r where k = 't_pending'), 'thread_has_pending|ab0f0c01-0000-4000-8000-000000000001',
  'thread with a pending booking returns thread_has_pending');
insert into rb_r values ('t_linked', pg_temp.rec(jsonb_build_object('key', 'rb-key-thread-link-01', 'checkin', pg_temp.d(440)::text, 'checkout', pg_temp.d(442)::text, 'psid', 'rb-psid-linked', 'ref', 'THRLINK12345')));
select is((select r ->> 'outcome' from rb_r where k = 't_linked'), 'thread_linked_other', 'thread linked to a live confirmed stay returns thread_linked_other');
select is(pg_temp.rows_of('rb-key-thread-pend-01') || '|' || pg_temp.rows_of('rb-key-thread-link-01') || '|'
          || (select booking_flow ->> 'booking_id' from public.concierge_threads where psid = 'rb-psid-linked'), '0/0/0|0/0/0|ab0f0c02-0000-4000-8000-000000000002',
  'a thread routing refusal writes nothing and leaves the thread alone');
select is(pg_temp.rec(jsonb_build_object('key', 'rb-key-thread-past-01', 'checkin', pg_temp.d(440)::text, 'checkout', pg_temp.d(442)::text, 'psid', 'rb-psid-past', 'ref', 'THRPAST12345')) ->> 'outcome',
  'recorded', 'a thread whose stay is over takes a new booking');
select is(pg_temp.rec(jsonb_build_object('key', 'rb-key-thread-junk-01', 'checkin', pg_temp.d(444)::text, 'checkout', pg_temp.d(446)::text, 'psid', 'rb-psid-junk', 'ref', 'THRJUNK12345')) ->> 'outcome',
  'recorded', 'a thread flow with a malformed booking_id does not break the call');

insert into rb_r values ('t_save', pg_temp.rec(jsonb_build_object('key', 'rb-key-thread-save-01', 'checkin', pg_temp.d(450)::text, 'checkout', pg_temp.d(452)::text, 'psid', 'rb-psid-save', 'ref', 'THRSAVE12345', 'total', 3000, 'paid', 1500)));
select is((select booking_flow ->> 'booking_id' || '|' || (booking_flow ->> 'step') || '|' || (booking_flow ->> 'ref') || '|' || (booking_flow ->> 'lang') || '|' || (booking_flow ->> 'checkin')
                  || '|' || (booking_flow ->> 'total') || '|' || (booking_flow ->> 'deposit') || '|' || (booking_flow ->> 'pax') || '|' || (booking_flow ->> 'name')
             from public.concierge_threads where psid = 'rb-psid-save'),
  pg_temp.bid('rb-key-thread-save-01')::text || '|confirmed|DIR-' || pg_temp.ref8('rb-key-thread-save-01') || '|tl|' || pg_temp.d(450)::text || '|3000.00|1500.00|2|Synthetic Guest',
  'thread flow carries booking_id after a save');
select is((select p.messenger_psid from public.guest_profile_details p join public.booking_inquiries b on b.guest_id = p.guest_id where b.id = pg_temp.bid('rb-key-thread-save-01')), 'rb-psid-save',
  'the guest takes the PSID when it had none');
-- same guest (same phone) books again from another thread: the first PSID is kept
select pg_temp.rec(jsonb_build_object('key', 'rb-key-thread-save-02', 'checkin', pg_temp.d(455)::text, 'checkout', pg_temp.d(457)::text, 'psid', 'rb-psid-second', 'ref', 'THRSAVE54321'));
select is((select p.messenger_psid from public.guest_profile_details p join public.booking_inquiries b on b.guest_id = p.guest_id where b.id = pg_temp.bid('rb-key-thread-save-02')) || '|'
          || (select booking_flow ->> 'booking_id' from public.concierge_threads where psid = 'rb-psid-second'),
  'rb-psid-save|' || pg_temp.bid('rb-key-thread-save-02')::text, 'a guest that already has a PSID keeps it; the new thread still points at the booking');

-- 7. the engine patch cannot be reached without the label and the setting ------------------------------------------------------------------------------
insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, pax, status, source, total_amount, deposit_amount) values
  ('ab0f0e02-0000-4000-8000-0000000000e2', 'ab0f0000-0000-4000-8000-0000000000a1', 'Synthetic Site', '09170000009', pg_temp.d(460), pg_temp.d(462), 2, 'pending', 'direct', 2000, 1000);
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, recon_status) values
  ('ab0f0000-0000-4000-8000-0000000000a1', 'direct:ab0f0e02-0000-4000-8000-0000000000e2', 'direct', 'blocked', pg_temp.d(460), pg_temp.d(462), 'manual_entry');
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, recon_status, block_reason, block_reason_source, block_note) values
  ('ab0f0000-0000-4000-8000-0000000000a1', 'rb-block-site@airbnb.com', 'airbnb', 'blocked', pg_temp.d(460), pg_temp.d(462), 'skipped', 'direct', 'auto', 'DIR AB0F0E02 confirmed');
select is(coalesce(current_setting('cascade.offline_booking_id', true), ''), '', 'the offline setting is empty after a recorded booking');
select set_config('request.jwt.claims', json_build_object('sub', 'ab0f0000-0000-4000-8000-0000000000b1', 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select set_config('rb.site1', public.staff_confirm_direct_booking_v1('ab0f0e02-0000-4000-8000-0000000000e2', 'cash', null, 2000, 'paid at the desk, synthetic', null, 'rb-site-confirm-key-0001')::text, true);
reset role;
select is((current_setting('rb.site1')::jsonb) ->> 'outcome', 'conflict', 'a site confirm over a direct-labelled block still conflicts (setting absent)');
-- the setting names ANOTHER booking: still a conflict
select set_config('cascade.offline_booking_id', 'ab0f0000-0000-4000-8000-0000000000ff', true);
select set_config('request.jwt.claims', json_build_object('sub', 'ab0f0000-0000-4000-8000-0000000000b1', 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select set_config('rb.site2', public.staff_confirm_direct_booking_v1('ab0f0e02-0000-4000-8000-0000000000e2', 'cash', null, 2000, 'paid at the desk, synthetic', null, 'rb-site-confirm-key-0002')::text, true);
reset role;
select is((current_setting('rb.site2')::jsonb) ->> 'outcome', 'conflict', 'the engine keeps conflicting when the setting names another booking');
select set_config('cascade.offline_booking_id', '', true);
select is((select status from public.booking_inquiries where id = 'ab0f0e02-0000-4000-8000-0000000000e2'), 'pending', 'the refused site booking stays pending');

-- 8. what a recorded booking leaves behind -----------------------------------------------------------------------------------------------------------
select ok(exists (select 1 from public.automation_outbox where event_type = 'booking.confirmed' and aggregate_id = pg_temp.bid('rb-key-block-unexpl1')),
  'the outbox has booking.confirmed for the booking');
select is((select count(*)::int from public.airbnb_reservations where confirmation_code = 'DIRECT:' || pg_temp.bid('rb-key-block-unexpl1')::text and status = 'confirmed')
          || '|' || (select count(*) from public.calendar_events where uid = 'cascade-direct-' || pg_temp.bid('rb-key-block-unexpl1')::text and status = 'confirmed')::text
          || '|' || (select count(*) from public.calendar_events where uid = 'direct:' || pg_temp.bid('rb-key-block-unexpl1')::text)::text,
  '1|1|0', 'DIRECT: reservation exists and the calendar uid is cascade-direct-<id>');

-- the verifier reads the relabelled block as our own mirror (V1) and not as a run past the stay (V1m); a block that names another booking is still raised
select is((select count(*)::int from jsonb_array_elements(public.run_system_verifier_v1('ab0f0000-0000-4000-8000-0000000000a1', 'hourly', (pg_temp.d(328)::text || ' 02:00+00')::timestamptz)->'found') e
            where e ->> 'check_id' = 'V1'),
  0, 'the verifier shows no V1 for the relabelled block');
update public.calendar_events set block_note = 'DIR FFFFFFFF confirmed' where uid = 'rb-block-unexplained@airbnb.com';
select is((select count(*)::int from jsonb_array_elements(public.run_system_verifier_v1('ab0f0000-0000-4000-8000-0000000000a1', 'hourly', (pg_temp.d(328)::text || ' 02:00+00')::timestamptz)->'found') e
            where e ->> 'key' like 'V1:%'),
  1, 'control: a block that names another booking is still raised as V1');

-- 9. input -------------------------------------------------------------------------------------------------------------------------------------------
select is((select string_agg(coalesce(pg_temp.rec(o) ->> 'field', pg_temp.rec(o) ->> 'outcome'), ',' order by ord)
             from (values
               (1, jsonb_build_object('key', 'rb-key-input-0000001', 'checkin', pg_temp.d(490)::text, 'checkout', pg_temp.d(490)::text)),
               (2, jsonb_build_object('key', 'rb-key-input-0000002', 'checkin', pg_temp.d(-5)::text, 'checkout', pg_temp.d(-2)::text)),
               (3, jsonb_build_object('key', 'rb-key-input-0000003', 'checkin', pg_temp.d(490)::text, 'checkout', pg_temp.d(492)::text, 'pax', 5)),
               (4, jsonb_build_object('key', 'rb-key-input-0000004', 'checkin', pg_temp.d(490)::text, 'checkout', pg_temp.d(492)::text, 'total', 0)),
               (5, jsonb_build_object('key', 'rb-key-input-0000005', 'checkin', pg_temp.d(490)::text, 'checkout', pg_temp.d(492)::text, 'paid', 0)),
               (6, jsonb_build_object('key', 'rb-key-input-0000006', 'checkin', pg_temp.d(490)::text, 'checkout', pg_temp.d(492)::text, 'paid', 6000)),
               (7, jsonb_build_object('key', 'rb-key-input-0000007', 'checkin', pg_temp.d(490)::text, 'checkout', pg_temp.d(492)::text, 'name', '  ')),
               (8, jsonb_build_object('key', 'rb-key-input-0000008', 'checkin', pg_temp.d(490)::text, 'checkout', pg_temp.d(492)::text, 'channel', 'site')),
               (9, jsonb_build_object('key', 'rb-key-input-0000009', 'checkin', pg_temp.d(490)::text, 'checkout', pg_temp.d(492)::text, 'method', 'paypal')),
               (10, jsonb_build_object('key', 'short')),
               (11, jsonb_build_object('key', 'rb-key-input-0000011', 'checkin', pg_temp.d(490)::text, 'checkout', pg_temp.d(492)::text, 'ref', null))
             ) v(ord, o)),
  'dates,checkout,pax,total,amount_required,paid,guest_name,channel,method,idempotency_key,reference_required',
  'validation answers invalid_input with the field (amount_required for a missing payment, reference_required for a GCash booking without a reference)');
select is(pg_temp.rows_of('rb-key-input-0000001') || pg_temp.rows_of('rb-key-input-0000006') || pg_temp.rows_of('rb-key-input-0000011'), '0/0/00/0/00/0/0', 'invalid input writes nothing');

select * from finish();
rollback;
