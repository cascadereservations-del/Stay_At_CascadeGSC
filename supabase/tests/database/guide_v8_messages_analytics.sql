-- Session 135: release guide_v8_messages_analytics_20261206 (guest guide v8.0.0 backend): five guide_* tables (RLS, no grants), four anon guest RPCs (guide_session_v1, guide_thread_v1, guide_send_v1, guide_track_v1),
-- five staff RPCs (manage_guest_inbox gate), the push trigger and guide_sweep_v1. Synthetic fixtures only (uuids e1350000-..., names "Zz S135 ..."); everything rolls back.
-- Fixture rows and the reads run as the owner role (a --no-acl restore gives authenticated and anon no table grants); only the RPC calls run as anon / authenticated / service_role.
-- The push trigger is disabled inside this suite (rolled back with it) so a rehearsal copy can never queue an HTTP call to the production notify-staff-inbox function.
-- Run: CASCADE_REHEARSAL_PRE_SQL=supabase/releases/support/s136_pre_grants.sql scripts/recovery/p6/migration-rehearsal-on-host.sh <backup-set> supabase/releases/20261206_guide_v8.release.json supabase/tests/database/guide_v8_messages_analytics.sql
-- Section 15 (s136 round 5): inline 30-day retention, exact caps (a batch is cut to the room left), bounded value and meta, measured worst-case and typical size
-- (30000 rows on a clone of guide_events), the 30-day usage window, sessions kept 95 days past expiry (guests report), lock_timeout (function-level, busy answer),
-- the push trigger fired by a service_role insert with net.http_post stubbed.
-- Sections 13 and 14 (s136 round 3, lane A-sqlguests): storage bound (round 5 values: 60 / minute and 1000 / 24 h global caps, 200 stored bytes of meta, 30-day sweep),
-- advisory locks, throttle key (x-real-ip is ignored; garbage and malformed headers), token expiry guard, explicit service_role ACLs. No concurrency test: two sessions
-- cannot run inside one pgTAP transaction, so the lock tests assert that the transaction holds the advisory lock after the call.
-- Section 12 (s136 lane A-guests): staff_guide_guests_v1 (20 tests).
-- Section 11 (s136 review round 2): placeholder names get no session, the throttle key ignores the client-controlled x-forwarded-for entry, per-date and per-thread caps,
-- the analytics caps and meta whitelist, the single-property usage report, explicit ACLs.
begin;
select plan(163);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

create function pg_temp.as_user(p_uid uuid, p_aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal, 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
grant execute on function pg_temp.as_user(uuid, text) to public;
create function pg_temp.as_anon() returns void language sql as $$ select set_config('role', 'anon', true) $$;
grant execute on function pg_temp.as_anon() to public;
create function pg_temp.as_service() returns void language sql as $$ select set_config('role', 'service_role', true) $$;
grant execute on function pg_temp.as_service() to public;
create function pg_temp.try(p text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  execute p into r;
  return coalesce(r, 'null'::jsonb);
exception when others then
  return jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
end $f$;
grant execute on function pg_temp.try(text) to public;
create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1350000-0000-4000-8000-0000000000' || p)::uuid $$;
grant execute on function pg_temp.id(text) to public;
create function pg_temp.today() returns date language sql stable as $$ select (now() at time zone 'Asia/Manila')::date $$;
grant execute on function pg_temp.today() to public;
create function pg_temp.dp() returns uuid language sql immutable as $$ select '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid $$;
grant execute on function pg_temp.dp() to public;
create function pg_temp.tok() returns text language sql stable as $$ select v ->> 'token' from _t where k = 'mint' $$;
grant execute on function pg_temp.tok() to public;
create function pg_temp.tid() returns text language sql stable as $$ select v ->> 'thread_id' from _t where k = 'mint' $$;
grant execute on function pg_temp.tid() to public;

-- =============================================================================================================================================
-- Fixtures: 01 owner, 03 cleaner (staff, has the house, but no manage_guest_inbox), 04 outsider (staff user with no profile); house b1
--   stays at b1: "Zz Tester" today (checks in today, Manila), "Zz Later" in ten days (too early), "Zz Past" ended eight days ago (expired)
-- =============================================================================================================================================
insert into auth.users(id, email) values (pg_temp.id('01'), 'zz135-owner@example.com'), (pg_temp.id('03'), 'zz135-cleaner@example.com'), (pg_temp.id('04'), 'zz135-outsider@example.com');
insert into public.properties(id, name, is_active) values (pg_temp.id('b1'), 'Zz S135 House', true);
insert into public.staff_access_profiles(user_id, role) values (pg_temp.id('01'), 'owner'), (pg_temp.id('03'), 'cleaner');
insert into public.staff_property_access(user_id, property_id) values (pg_temp.id('03'), pg_temp.id('b1'));
insert into public.calendar_events(property_id, uid, source, checkin_date, checkout_date, guest_name, status, raw_summary) values
  (pg_temp.id('b1'), 'zz135-now', 'airbnb', pg_temp.today(), pg_temp.today() + 2, 'Zz Tester', 'confirmed', 'Reserved'),
  (pg_temp.id('b1'), 'zz135-later', 'airbnb', pg_temp.today() + 10, pg_temp.today() + 12, 'Zz Later', 'confirmed', 'Reserved'),
  (pg_temp.id('b1'), 'zz135-past', 'airbnb', pg_temp.today() - 10, pg_temp.today() - 8, 'Zz Past', 'confirmed', 'Reserved');

-- =============================================================================================================================================
-- 1. Shape: tables, RLS, grants, functions, trigger
-- =============================================================================================================================================
select ok((select count(*) = 5 from pg_tables where schemaname = 'public' and tablename in ('guide_threads', 'guide_sessions', 'guide_messages', 'guide_auth_attempts', 'guide_events')), 'tables: the five guide_* tables exist');
select ok((select bool_and(c.relrowsecurity) and count(*) = 5 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('guide_threads', 'guide_sessions', 'guide_messages', 'guide_auth_attempts', 'guide_events')), 'tables: row level security is on for all five');
select ok(not exists (select 1 from pg_policies where schemaname = 'public' and tablename in ('guide_threads', 'guide_sessions', 'guide_messages', 'guide_auth_attempts', 'guide_events')), 'tables: no policy is defined (only the definer functions touch them)');
select ok(not exists (select 1 from unnest(array['guide_threads', 'guide_sessions', 'guide_messages', 'guide_auth_attempts', 'guide_events']) t, unnest(array['select', 'insert', 'update', 'delete']) p where has_table_privilege('anon', 'public.' || t, p) or has_table_privilege('authenticated', 'public.' || t, p)), 'tables: anon and authenticated hold no table privilege on any of them');
select ok(not exists (select 1 from unnest(array['guide_threads', 'guide_sessions', 'guide_messages', 'guide_auth_attempts', 'guide_events']) t, unnest(array['select', 'insert', 'update']) p where has_any_column_privilege('anon', 'public.' || t, p) or has_any_column_privilege('authenticated', 'public.' || t, p)), 's136: and no column-level select, insert or update privilege either (a column grant would not show in has_table_privilege)');
select ok((select bool_and(has_function_privilege('anon', f, 'execute') and has_function_privilege('authenticated', f, 'execute')) from unnest(array['public.guide_session_v1(date,text,text,uuid)', 'public.guide_thread_v1(text,timestamptz)', 'public.guide_send_v1(text,text,text)', 'public.guide_track_v1(text,jsonb,text,text)']::regprocedure[]) f), 'functions: anon and authenticated may execute the four guest functions');
select ok((select not bool_or(has_function_privilege('anon', f, 'execute')) from unnest(array['public.staff_guide_threads_v1(uuid)', 'public.staff_guide_thread_v1(uuid)', 'public.staff_guide_reply_v1(uuid,text,text)', 'public.staff_guide_resolve_v1(uuid,boolean)', 'public.staff_guide_usage_v1(integer,uuid)', 'public.guide_token_thread_v1(text)', 'public.guide_sweep_v1()', 'public.guide_messages_push_trg()']::regprocedure[]) f), 'functions: anon may execute none of the five staff functions, the token helper, the sweep or the trigger function');
select ok((select bool_and(has_function_privilege('authenticated', f, 'execute')) from unnest(array['public.staff_guide_threads_v1(uuid)', 'public.staff_guide_thread_v1(uuid)', 'public.staff_guide_reply_v1(uuid,text,text)', 'public.staff_guide_resolve_v1(uuid,boolean)', 'public.staff_guide_usage_v1(integer,uuid)']::regprocedure[]) f), 'functions: authenticated may execute the five staff functions (the body gates them)');
select ok((select not bool_or(has_function_privilege('authenticated', f, 'execute')) from unnest(array['public.guide_token_thread_v1(text)', 'public.guide_sweep_v1()', 'public.guide_messages_push_trg()']::regprocedure[]) f) and has_function_privilege('service_role', 'public.guide_sweep_v1()', 'execute'), 'functions: the token helper, sweep and trigger function are closed to authenticated; the sweep belongs to service_role');
select ok((select bool_and(p.prosecdef and p.proconfig @> array['search_path=""']) and count(*) >= 12 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and (p.proname like 'guide\_%' or p.proname like 'staff\_guide\_%')), 'functions: every guide_* / staff_guide_* function (at least the 12 of this release) is SECURITY DEFINER with search_path pinned to empty');
select ok(exists (select 1 from pg_trigger t where t.tgrelid = 'public.guide_messages'::regclass and t.tgname = 'guide_messages_push' and t.tgenabled = 'O' and not t.tgisinternal), 'trigger: guide_messages_push is present and enabled');
alter table public.guide_messages disable trigger guide_messages_push;

-- =============================================================================================================================================
-- 2. Guest: mint a session (wrong initial, right initial, same stay twice, too early, expired, missing)
-- =============================================================================================================================================
select pg_temp.as_anon();
insert into _t values ('bad_initial', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), 'Q', 'zz135-a', pg_temp.id('b1'))));
insert into _t values ('mint', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), 'T', 'zz135-b', pg_temp.id('b1'))));
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'no_match' and not v ? 'token' from _t where k = 'bad_initial'), 'session: a wrong initial on a seeded booking answers no_match and carries no token');
select ok((select count(*) = 1 from public.guide_auth_attempts where client = 'zz135-a' and not ok and tried_date = pg_temp.today()) and (select count(*) = 0 from public.guide_auth_attempts where client = 'zz135-a' and ok) and (select count(*) = 1 from public.guide_threads) and (select count(*) = 1 from public.guide_sessions), 'session: the wrong initial is logged as one failed attempt and mints nothing (the one thread and one session are the right initial''s)');
select ok((select v ->> 'ok' = 'true' and v ->> 'token' ~ '^[a-f0-9]{64}$' and v ->> 'thread_id' is not null from _t where k = 'mint'), 'session: the right initial (the last-name initial counts) mints a 64-hex token and a thread id');
select ok((select v ->> 'guest_label' = 'Zz' and v ->> 'channel' = 'airbnb' and (v ->> 'checkin_date')::date = pg_temp.today() and (v ->> 'checkout_date')::date = pg_temp.today() + 2 from _t where k = 'mint'), 'session: the answer carries first name only, channel airbnb and the stay dates');
select ok((select count(*) = 1 from public.guide_sessions s where s.token_hash = encode(extensions.digest(pg_temp.tok(), 'sha256'), 'hex') and s.thread_id = pg_temp.tid()::uuid) and not exists (select 1 from public.guide_sessions s where s.token_hash = pg_temp.tok()), 'session: only the sha256 of the token is stored, never the token');
select ok((select expires_at = ((pg_temp.today() + 4)::timestamp at time zone 'Asia/Manila') from public.guide_sessions limit 1), 'session: the token lives until checkout + 2 days at Manila midnight');
select ok((select count(*) = 1 from public.guide_auth_attempts where client = 'zz135-b' and ok), 'session: the successful mint is logged as an ok attempt');
select pg_temp.as_anon();
insert into _t values ('mint2', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), 'z', 'zz135-c', pg_temp.id('b1'))));
insert into _t values ('too_early', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 10, 'L', 'zz135-d', pg_temp.id('b1'))));
insert into _t values ('expired', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() - 10, 'P', 'zz135-e', pg_temp.id('b1'))));
insert into _t values ('missing', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), '   ', 'zz135-f', pg_temp.id('b1'))));
reset role;
select ok((select (m.v ->> 'ok')::boolean and m.v ->> 'thread_id' = pg_temp.tid() and m.v ->> 'token' <> pg_temp.tok() from _t m where m.k = 'mint2') and (select count(*) = 1 from public.guide_threads) and (select count(*) = 2 from public.guide_sessions), 'session: minting again for the same stay (first-name initial, lower case) reuses the one thread and adds a second token');
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'too_early' and (v ->> 'opens_on')::date = pg_temp.today() + 7 from _t where k = 'too_early'), 'session: a stay more than three days away answers too_early with opens_on = check-in - 3');
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'expired' from _t where k = 'expired'), 'session: a stay that ended long ago answers expired');
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'missing' from _t where k = 'missing') and (select count(*) = 1 from public.guide_threads), 'session: a blank initial answers missing, and no thread appears for the too-early or expired stays');

-- =============================================================================================================================================
-- 3. Guest: read and send
-- =============================================================================================================================================
select pg_temp.as_anon();
insert into _t values ('read0', pg_temp.try(format('select public.guide_thread_v1(%L)', pg_temp.tok())));
insert into _t values ('read_bad', pg_temp.try(format('select public.guide_thread_v1(%L)', repeat('0', 64))));
insert into _t values ('read_short', pg_temp.try(format('select public.guide_thread_v1(%L)', 'abc')));
insert into _t values ('send1', pg_temp.try(format('select public.guide_send_v1(%L, %L, %L)', pg_temp.tok(), '  Hello from the guide  ', 'zz135-msg-0001')));
insert into _t values ('send_dup', pg_temp.try(format('select public.guide_send_v1(%L, %L, %L)', pg_temp.tok(), 'A different body', 'zz135-msg-0001')));
insert into _t values ('send_empty', pg_temp.try(format('select public.guide_send_v1(%L, %L, %L)', pg_temp.tok(), '   ', 'zz135-msg-0002')));
insert into _t values ('send_long', pg_temp.try(format('select public.guide_send_v1(%L, %L, %L)', pg_temp.tok(), repeat('x', 2001), 'zz135-msg-0003')));
insert into _t values ('send_cid', pg_temp.try(format('select public.guide_send_v1(%L, %L, %L)', pg_temp.tok(), 'Hi', 'short')));
insert into _t values ('send_badtok', pg_temp.try(format('select public.guide_send_v1(%L, %L, %L)', repeat('0', 64), 'Hi', 'zz135-msg-0004')));
insert into _t values ('read1', pg_temp.try(format('select public.guide_thread_v1(%L)', pg_temp.tok())));
reset role;
select ok((select v ->> 'ok' = 'true' and jsonb_array_length(v -> 'messages') = 0 and v ->> 'status' = 'open' and v ->> 'thread_id' = pg_temp.tid() from _t where k = 'read0'), 'read: a valid token returns its own open thread with no messages yet');
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'session' from _t where k = 'read_bad') and (select v ->> 'reason' = 'session' from _t where k = 'read_short'), 'read: an unknown token and a too-short token are both refused with reason session');
select ok((select v ->> 'ok' = 'true' and v ->> 'id' is not null and not v ? 'already' from _t where k = 'send1') and (select count(*) = 1 from public.guide_messages where sender = 'guest' and body = 'Hello from the guide' and client_msg_id = 'zz135-msg-0001' and staff_user_id is null), 'send: a message is stored once, trimmed, as sender guest');
select ok((select t.last_guest_at is not null and t.status = 'open' and t.guest_read_at is not null from public.guide_threads t where t.id = pg_temp.tid()::uuid), 'send: the thread records last_guest_at and the guest read stamp');
select ok((select d.v ->> 'already' = 'true' and d.v ->> 'id' = s.v ->> 'id' from _t d, _t s where d.k = 'send_dup' and s.k = 'send1') and (select count(*) = 1 from public.guide_messages), 'send: repeating a client_msg_id returns the first message (already) and stores nothing new');
select ok((select v ->> 'reason' = 'length' from _t where k = 'send_empty') and (select v ->> 'reason' = 'length' from _t where k = 'send_long'), 'send: a blank body and a 2001-character body are refused with reason length');
select ok((select v ->> 'reason' = 'client_msg_id' from _t where k = 'send_cid') and (select v ->> 'reason' = 'session' from _t where k = 'send_badtok') and (select count(*) = 1 from public.guide_messages), 'send: a short client_msg_id and a bad token are refused, nothing stored');
select ok((select jsonb_array_length(v -> 'messages') = 1 and v -> 'messages' -> 0 ->> 'from' = 'guest' and v -> 'messages' -> 0 ->> 'body' = 'Hello from the guide' from _t where k = 'read1'), 'read: the thread now returns the one guest message');

-- one transaction means one now(): move the first guest line three hours back so the thread has a real order
update public.guide_messages set created_at = now() - interval '3 hours' where client_msg_id = 'zz135-msg-0001';

-- =============================================================================================================================================
-- 4. Guest: analytics batch
-- =============================================================================================================================================
select pg_temp.as_anon();
insert into _t values ('track_anon', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz135dev01', jsonb_build_array(
  jsonb_build_object('name', 'guide_open'),
  jsonb_build_object('name', 'section_view', 'section', 'wifi', 'value', 12),
  jsonb_build_object('name', 'tap', 'section', 'home', 'target', 'card:wifi', 'meta', jsonb_build_object('k', 1)),
  jsonb_build_object('name', 'Bad Name'),
  jsonb_build_object('name', 'tap_ok', 'section', 'UPPER CASE'),
  jsonb_build_object('name', 'tap_ok', 'target', 'has space'))::text)));
insert into _t values ('track_tok', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb, %L)', 'zz135dev02', jsonb_build_array(jsonb_build_object('name', 'verify_ok'))::text, pg_temp.tok())));
insert into _t values ('track_clamp', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb, null, %L)', 'zz135dev03', jsonb_build_array(jsonb_build_object('name', 'guide_open', 'at', '2020-01-01T00:00:00Z'))::text, '8.0.0')));
insert into _t values ('track_dev', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'bad dev!', '[]')));
insert into _t values ('track_obj', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz135dev04', '{"name": "tap"}')));
insert into _t values ('track_big', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz135dev04', (select jsonb_agg(jsonb_build_object('name', 'tap_ok'))::text from generate_series(1, 51)))));
reset role;
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 3 from _t where k = 'track_anon'), 'track: of six events the three valid ones are stored (bad name, bad section and bad target are skipped, the batch survives)');
select ok((select count(*) = 3 and bool_and(not verified) and bool_and(thread_id is null) and bool_and(version is null) from public.guide_events where device = 'zz135dev01'), 'track: an anonymous batch is stored unverified with no thread id');
select ok((select e.value = 12 and e.section = 'wifi' from public.guide_events e where e.device = 'zz135dev01' and e.name = 'section_view') and (select e.target = 'card:wifi' and e.meta = '{"k": 1}'::jsonb from public.guide_events e where e.device = 'zz135dev01' and e.name = 'tap'), 'track: section, value, target and meta land in their columns');
select ok((select (v ->> 'stored')::int = 1 from _t where k = 'track_tok') and (select count(*) = 1 and bool_and(verified) and bool_and(thread_id = pg_temp.tid()::uuid) from public.guide_events where device = 'zz135dev02'), 'track: a valid guide token marks the event verified and ties it to the thread');
select ok((select (v ->> 'stored')::int = 1 from _t where k = 'track_clamp') and (select e.at > now() - interval '2 days 1 minute' and e.at <= now() and e.version = '8.0.0' from public.guide_events e where e.device = 'zz135dev03'), 'track: an old client timestamp is clamped to two days back and the app version is kept');
select ok((select v ->> 'reason' = 'device' from _t where k = 'track_dev') and (select v ->> 'reason' = 'events' from _t where k = 'track_obj') and (select v ->> 'reason' = 'events' from _t where k = 'track_big') and (select count(*) = 0 from public.guide_events where device in ('bad dev!', 'zz135dev04')), 'track: a bad device id, a non-array payload and a 51-event batch are refused whole (reasons device, events, events)');

-- =============================================================================================================================================
-- 5. Anon is walled off from tables and staff functions
-- =============================================================================================================================================
select pg_temp.as_anon();
insert into _t values ('anon_tables', (select jsonb_agg(pg_temp.try(format('select to_jsonb(count(*)) from public.%I', t)) order by t) from unnest(array['guide_threads', 'guide_sessions', 'guide_messages', 'guide_auth_attempts', 'guide_events']) t));
insert into _t values ('anon_threads', pg_temp.try(format('select public.staff_guide_threads_v1(%L::uuid)', pg_temp.id('b1'))));
insert into _t values ('anon_thread', pg_temp.try(format('select public.staff_guide_thread_v1(%L::uuid)', pg_temp.tid())));
insert into _t values ('anon_usage', pg_temp.try(format('select public.staff_guide_usage_v1(30, %L::uuid)', pg_temp.id('b1'))));
insert into _t values ('anon_sweep', pg_temp.try('select public.guide_sweep_v1()'));
insert into _t values ('anon_helper', pg_temp.try(format('select to_jsonb(public.guide_token_thread_v1(%L))', pg_temp.tok())));
reset role;
select ok((select jsonb_array_length(v) = 5 and (select bool_and(e ->> 'err' = '42501') from jsonb_array_elements(v) e) from _t where k = 'anon_tables'), 'anon: a direct select on each of the five tables (rows now exist) raises 42501');
select ok((select bool_and(v ->> 'err' = '42501') from _t where k in ('anon_threads', 'anon_thread', 'anon_usage')), 'anon: calling the staff list, thread and usage functions raises 42501');
select ok((select bool_and(v ->> 'err' = '42501') from _t where k in ('anon_sweep', 'anon_helper')), 'anon: the sweep and the token helper cannot be called (42501)');

-- =============================================================================================================================================
-- 6. Throttle: 8 failures per caller, then the door is shut, even for the right initial
-- =============================================================================================================================================
select pg_temp.as_anon();
do $$
declare i int; r jsonb; n int := 0;
begin
  for i in 1..8 loop
    r := public.guide_session_v1(pg_temp.today(), 'Q', 'zz135-t', pg_temp.id('b1'));
    if r ->> 'reason' = 'no_match' then n := n + 1; end if;
  end loop;
  insert into _t values ('throttle_first8', to_jsonb(n));
end $$;
insert into _t values ('throttle_9th', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), 'Q', 'zz135-t', pg_temp.id('b1'))));
insert into _t values ('throttle_right', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), 'T', 'zz135-t', pg_temp.id('b1'))));
insert into _t values ('throttle_other', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), 'T', 'zz135-g', pg_temp.id('b1'))));
reset role;
select is((select (v #>> '{}')::int from _t where k = 'throttle_first8'), 8, 'throttle: the first eight wrong initials each answer no_match');
select ok((select count(*) = 8 from public.guide_auth_attempts where client = 'zz135-t' and not ok), 'throttle: eight failures are on record for the caller');
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'throttled' and v ->> 'throttled' = 'true' from _t where k = 'throttle_9th'), 'throttle: the ninth attempt answers throttled');
select ok((select v ->> 'reason' = 'throttled' and not v ? 'token' from _t where k = 'throttle_right') and (select count(*) = 8 from public.guide_auth_attempts where client = 'zz135-t'), 'throttle: the right initial from the shut-out caller is still refused, and the refusal adds no attempt row');
select ok((select (v ->> 'ok')::boolean from _t where k = 'throttle_other'), 'throttle: a different caller is not affected');

-- =============================================================================================================================================
-- 7. Staff gate: no staff access, no answer (42501)
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('03'));
insert into _t values ('cl_threads', pg_temp.try(format('select public.staff_guide_threads_v1(%L::uuid)', pg_temp.id('b1'))));
insert into _t values ('cl_thread', pg_temp.try(format('select public.staff_guide_thread_v1(%L::uuid)', pg_temp.tid())));
insert into _t values ('cl_reply', pg_temp.try(format('select public.staff_guide_reply_v1(%L::uuid, %L, %L)', pg_temp.tid(), 'hi there', 'zz135-rep-0001')));
insert into _t values ('cl_resolve', pg_temp.try(format('select public.staff_guide_resolve_v1(%L::uuid, true)', pg_temp.tid())));
insert into _t values ('cl_usage', pg_temp.try(format('select public.staff_guide_usage_v1(30, %L::uuid)', pg_temp.id('b1'))));
reset role;
select pg_temp.as_user(pg_temp.id('04'));
insert into _t values ('out_threads', pg_temp.try(format('select public.staff_guide_threads_v1(%L::uuid)', pg_temp.id('b1'))));
insert into _t values ('out_thread', pg_temp.try(format('select public.staff_guide_thread_v1(%L::uuid)', pg_temp.tid())));
reset role;
select is((select v ->> 'err' from _t where k = 'cl_threads'), '42501', 'staff gate: a cleaner cannot list the guide threads');
select is((select v ->> 'err' from _t where k = 'cl_thread'), '42501', 'staff gate: a cleaner cannot open a thread');
select is((select v ->> 'err' from _t where k = 'cl_reply'), '42501', 'staff gate: a cleaner cannot reply');
select is((select v ->> 'err' from _t where k = 'cl_resolve'), '42501', 'staff gate: a cleaner cannot resolve');
select is((select v ->> 'err' from _t where k = 'cl_usage'), '42501', 'staff gate: a cleaner cannot read the usage report');
select ok((select bool_and(v ->> 'err' = '42501' and v ->> 'msg' = 'staff access denied') from _t where k in ('cl_threads', 'cl_thread', 'cl_reply', 'cl_resolve', 'cl_usage', 'out_threads', 'out_thread')), 'staff gate: every refusal carries the message "staff access denied"');
select ok((select v ->> 'err' = '42501' from _t where k = 'out_threads') and (select v ->> 'err' = '42501' from _t where k = 'out_thread'), 'staff gate: a signed-in user with no staff profile is refused too');
select ok((select count(*) = 1 from public.guide_messages) and (select last_staff_at is null and staff_read_at is null from public.guide_threads where id = pg_temp.tid()::uuid), 'staff gate: the refused calls changed nothing (still one message, no staff stamps)');

-- =============================================================================================================================================
-- 8. Staff owner: list, open, reply (idempotent), resolve; the guest sees the reply; a new guest message reopens
-- =============================================================================================================================================
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('ow_threads', pg_temp.try(format('select public.staff_guide_threads_v1(%L::uuid)', pg_temp.id('b1'))));
insert into _t values ('ow_missing', pg_temp.try(format('select public.staff_guide_thread_v1(%L::uuid)', pg_temp.id('ff'))));
insert into _t values ('ow_thread', pg_temp.try(format('select public.staff_guide_thread_v1(%L::uuid)', pg_temp.tid())));
reset role;
select ok((select jsonb_array_length(v) = 1 and v -> 0 ->> 'guest_label' = 'Zz' and v -> 0 ->> 'channel' = 'airbnb' and v -> 0 ->> 'status' = 'open' and (v -> 0 ->> 'unread')::int = 1 and v -> 0 -> 'last' ->> 'from' = 'guest' and v -> 0 -> 'last' ->> 'body' = 'Hello from the guide' from _t where k = 'ow_threads'), 'staff: the owner lists one thread with guest label, channel, one unread and the last line');
select ok((select v ->> 'err' = 'P0002' and v ->> 'msg' = 'guide thread not found' from _t where k = 'ow_missing'), 'staff: a thread id that does not exist raises P0002 (guide thread not found) for an authorised owner, ahead of the access check');
select ok((select jsonb_array_length(v -> 'messages') = 1 and v -> 'messages' -> 0 ->> 'from' = 'guest' and not (v -> 'thread') ? 'property_id' and v -> 'thread' ->> 'id' = pg_temp.tid() from _t where k = 'ow_thread'), 'staff: opening the thread returns its messages and leaves the property id out');
select ok((select staff_read_at is not null from public.guide_threads where id = pg_temp.tid()::uuid), 'staff: opening the thread stamps staff_read_at');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('ow_threads2', pg_temp.try(format('select public.staff_guide_threads_v1(%L::uuid)', pg_temp.id('b1'))));
insert into _t values ('ow_reply', pg_temp.try(format('select public.staff_guide_reply_v1(%L::uuid, %L, %L)', pg_temp.tid(), '  Welcome, see you at check-in  ', 'zz135-rep-0001')));
insert into _t values ('ow_reply_dup', pg_temp.try(format('select public.staff_guide_reply_v1(%L::uuid, %L, %L)', pg_temp.tid(), 'Other words', 'zz135-rep-0001')));
insert into _t values ('ow_reply_empty', pg_temp.try(format('select public.staff_guide_reply_v1(%L::uuid, %L, %L)', pg_temp.tid(), '   ', 'zz135-rep-0002')));
insert into _t values ('ow_reply_cid', pg_temp.try(format('select public.staff_guide_reply_v1(%L::uuid, %L, %L)', pg_temp.tid(), 'Hi', 'short')));
reset role;
select ok((select (v -> 0 ->> 'unread')::int = 0 from _t where k = 'ow_threads2'), 'staff: after the thread was opened the unread count is 0');
select ok((select v ->> 'ok' = 'true' and not v ? 'already' from _t where k = 'ow_reply') and (select count(*) = 1 from public.guide_messages where sender = 'staff' and body = 'Welcome, see you at check-in' and staff_user_id = pg_temp.id('01')), 'staff: a reply is stored once, trimmed, with the replying user');
select ok((select d.v ->> 'already' = 'true' and d.v ->> 'id' = r.v ->> 'id' from _t d, _t r where d.k = 'ow_reply_dup' and r.k = 'ow_reply') and (select count(*) = 2 from public.guide_messages), 'staff: repeating a client_msg_id returns the first reply (already) and stores nothing new');
select ok((select v ->> 'err' = '22023' and v ->> 'msg' = 'reply length' from _t where k = 'ow_reply_empty') and (select v ->> 'err' = '22023' and v ->> 'msg' = 'client_msg_id' from _t where k = 'ow_reply_cid'), 'staff: a blank reply and a short client_msg_id are refused with 22023');
select ok((select t.last_staff_at is not null and t.last_staff_at = (select m.created_at from public.guide_messages m where m.sender = 'staff') from public.guide_threads t where t.id = pg_temp.tid()::uuid), 'staff: the thread records last_staff_at at the reply time');
select pg_temp.as_anon();
insert into _t values ('read2', pg_temp.try(format('select public.guide_thread_v1(%L)', pg_temp.tok())));
reset role;
select ok((select jsonb_array_length(v -> 'messages') = 2 and v -> 'messages' -> 0 ->> 'from' = 'guest' and v -> 'messages' -> 1 ->> 'from' = 'staff' and v -> 'messages' -> 1 ->> 'body' = 'Welcome, see you at check-in' and v ->> 'staff_read_at' is not null from _t where k = 'read2'), 'guest read: the thread shows the guest line then the staff reply, and when staff read it');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('ow_resolve', pg_temp.try(format('select public.staff_guide_resolve_v1(%L::uuid, true)', pg_temp.tid())));
reset role;
select ok((select v ->> 'ok' = 'true' from _t where k = 'ow_resolve') and (select status = 'resolved' from public.guide_threads where id = pg_temp.tid()::uuid), 'staff: resolve closes the thread');
select pg_temp.as_anon();
insert into _t values ('send3', pg_temp.try(format('select public.guide_send_v1(%L, %L, %L)', pg_temp.tok(), 'One more question', 'zz135-msg-0005')));
reset role;
select ok((select v ->> 'ok' = 'true' from _t where k = 'send3') and (select status = 'open' from public.guide_threads where id = pg_temp.tid()::uuid) and (select count(*) = 3 from public.guide_messages), 'send: a new guest message reopens a resolved thread');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('ow_reopen', pg_temp.try(format('select public.staff_guide_resolve_v1(%L::uuid, false)', pg_temp.tid())));
reset role;
-- s136: the usage report is single-property (default property only); the fixture thread joins it for the report calls and goes back after
update public.guide_threads set property_id = pg_temp.dp();
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('ow_usage', pg_temp.try(format('select public.staff_guide_usage_v1(30, %L::uuid)', pg_temp.dp())));
reset role;
update public.guide_threads set property_id = pg_temp.id('b1');
select ok((select status = 'open' from public.guide_threads where id = pg_temp.tid()::uuid), 'staff: resolve with false reopens the thread');

-- =============================================================================================================================================
-- 9. Staff usage report (the table was new, so the counts are exact)
-- =============================================================================================================================================
select ok((select (v ->> 'devices')::int = 3 and (v ->> 'verified_stays')::int = 1 and (v ->> 'opens')::int = 2 from _t where k = 'ow_usage'), 'usage: three devices, one verified stay and two guide_open events');
select ok((select (v -> 'funnel' ->> 'verify_ok')::int = 1 and (v -> 'funnel' ->> 'message_sent')::int = 2 and (v -> 'funnel' ->> 'verify_start')::int = 0 from _t where k = 'ow_usage'), 'usage: the funnel counts one verify_ok device and the two guest messages');
select ok((select jsonb_array_length(v -> 'sections') = 2 and exists (select 1 from jsonb_array_elements(v -> 'sections') s where s ->> 'section' = 'wifi' and (s ->> 'views')::int = 1 and (s ->> 'devices')::int = 1) from _t where k = 'ow_usage'), 'usage: sections lists wifi with one view from one device');
select ok((select jsonb_array_length(v -> 'top_taps') = 1 and v -> 'top_taps' -> 0 ->> 'target' = 'card:wifi' and (v -> 'top_taps' -> 0 ->> 'taps')::int = 1 and v -> 'searches_without_result' = '[]'::jsonb and jsonb_array_length(v -> 'by_day') >= 1 from _t where k = 'ow_usage'), 'usage: the single tap is listed, no empty searches, and the by_day series is present');

-- =============================================================================================================================================
-- 9b. Review round 1: usage window is exactly p_days Manila dates; the list hides message-less threads; staff replies are capped
-- =============================================================================================================================================
-- two probe events straddling Manila midnight of the first plotted day of a 3-day window (today - 2): one minute after it, one minute before it
insert into public.guide_events(at, device, name) values
  (((pg_temp.today() - 2)::timestamp at time zone 'Asia/Manila') + interval '1 minute', 'zz135dev71', 'guide_open'),
  (((pg_temp.today() - 2)::timestamp at time zone 'Asia/Manila') - interval '1 minute', 'zz135dev72', 'guide_open');
update public.guide_threads set property_id = pg_temp.dp();
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('us3', pg_temp.try(format('select public.staff_guide_usage_v1(3, %L::uuid)', pg_temp.dp())));
insert into _t values ('us1', pg_temp.try(format('select public.staff_guide_usage_v1(1, %L::uuid)', pg_temp.dp())));
insert into _t values ('us30', pg_temp.try(format('select public.staff_guide_usage_v1(30, %L::uuid)', pg_temp.dp())));
reset role;
update public.guide_threads set property_id = pg_temp.id('b1');
select ok((select (v ->> 'since')::date = pg_temp.today() - 2 from _t where k = 'us3') and (select (v ->> 'since')::date = pg_temp.today() from _t where k = 'us1'), 'usage window: since is the Manila date of the first plotted day (today minus p_days plus 1), today for one day');
select ok((select (v ->> 'devices')::int = 4 from _t where k = 'us3') and (select (v ->> 'devices')::int = 5 from _t where k = 'us30'), 'usage window: an event one minute after Manila midnight of the first day is counted, one minute before it is not in a 3-day window (3 original devices + dev71), while a 30-day window holds both probes (5)');
select ok((select (select min((d ->> 'day')::date) from jsonb_array_elements(v -> 'by_day') d) = pg_temp.today() - 2 and (select max((d ->> 'day')::date) from jsonb_array_elements(v -> 'by_day') d) <= pg_temp.today() from _t where k = 'us3'), 'usage window: by_day starts on the first plotted Manila date and never runs past today');
select ok((select jsonb_array_length(v -> 'by_day') <= 3 from _t where k = 'us3'), 'usage window: a 3-day window holds at most three Manila dates');
delete from public.guide_events where device in ('zz135dev71', 'zz135dev72');

-- a guest who only verified (thread, no message) is not an open conversation
insert into public.guide_threads(id, property_id, calendar_event_id, checkin_date, checkout_date, guest_label, channel)
values (pg_temp.id('d1'), pg_temp.id('b1'), pg_temp.id('d2'), pg_temp.today(), pg_temp.today() + 1, 'Zz Mute', 'airbnb');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('th_mute', pg_temp.try(format('select public.staff_guide_threads_v1(%L::uuid)', pg_temp.id('b1'))));
reset role;
insert into public.guide_messages(thread_id, sender, body, client_msg_id) values (pg_temp.id('d1'), 'guest', 'First words', 'zz135-mute-0001');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('th_spoke', pg_temp.try(format('select public.staff_guide_threads_v1(%L::uuid)', pg_temp.id('b1'))));
reset role;
select ok((select jsonb_array_length(v) = 1 and not exists (select 1 from jsonb_array_elements(v) t where t ->> 'guest_label' = 'Zz Mute') from _t where k = 'th_mute'), 'staff list: a thread with no message at all is not listed');
select ok((select jsonb_array_length(v) = 2 and exists (select 1 from jsonb_array_elements(v) t where t ->> 'guest_label' = 'Zz Mute' and t -> 'last' ->> 'body' = 'First words') from _t where k = 'th_spoke'), 'staff list: the same thread is listed as soon as it has one message');
delete from public.guide_messages where thread_id = pg_temp.id('d1');
delete from public.guide_threads where id = pg_temp.id('d1');

-- staff reply cap: 60 per thread per hour; a replay of a stored client_msg_id is never counted or refused
insert into public.guide_messages(thread_id, sender, body, staff_user_id, client_msg_id)
select pg_temp.tid()::uuid, 'staff', 'Cap filler ' || g, pg_temp.id('01'), 'zz135-cap-' || lpad(g::text, 4, '0') from generate_series(1, 59) g;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('cap_over', pg_temp.try(format('select public.staff_guide_reply_v1(%L::uuid, %L, %L)', pg_temp.tid(), 'Sixty-first', 'zz135-rep-cap01')));
insert into _t values ('cap_replay', pg_temp.try(format('select public.staff_guide_reply_v1(%L::uuid, %L, %L)', pg_temp.tid(), 'Other words', 'zz135-rep-0001')));
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'rate' and not v ? 'err' from _t where k = 'cap_over') and (select count(*) = 60 from public.guide_messages where thread_id = pg_temp.tid()::uuid and sender = 'staff'), 'staff reply cap: the 61st reply in an hour is refused with reason rate (a JSON refusal, not an exception) and stores nothing');
select ok((select v ->> 'ok' = 'true' and v ->> 'already' = 'true' from _t where k = 'cap_replay') and (select count(*) = 60 from public.guide_messages where thread_id = pg_temp.tid()::uuid and sender = 'staff'), 'staff reply cap: replaying an existing client_msg_id at the cap still answers already, and is not counted');
update public.guide_messages set created_at = now() - interval '2 hours' where client_msg_id = 'zz135-cap-0001';
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('cap_after', pg_temp.try(format('select public.staff_guide_reply_v1(%L::uuid, %L, %L)', pg_temp.tid(), 'Fits again', 'zz135-rep-cap02')));
reset role;
select ok((select v ->> 'ok' = 'true' and not v ? 'already' from _t where k = 'cap_after'), 'staff reply cap: messages older than an hour are not counted, so one more reply fits');
delete from public.guide_messages where client_msg_id like 'zz135-cap-%' or client_msg_id in ('zz135-rep-cap01', 'zz135-rep-cap02');

-- =============================================================================================================================================
-- 10. Expiry and housekeeping
-- =============================================================================================================================================
insert into public.guide_sessions(token_hash, thread_id, expires_at) values (encode(extensions.digest('zz135-expired-token-0123456789abcdef', 'sha256'), 'hex'), pg_temp.tid()::uuid, now() - interval '1 hour');
insert into public.guide_events(at, received_at, device, name) values (now() - interval '31 days', now() - interval '31 days', 'zz135dev99', 'guide_open'), (now() - interval '29 days', now() - interval '29 days', 'zz135dev98', 'guide_open');
insert into public.guide_sessions(token_hash, thread_id, expires_at) values (encode(extensions.digest('zz135-ancient-token-0123456789abcdef', 'sha256'), 'hex'), pg_temp.tid()::uuid, now() - interval '100 days');
insert into public.guide_auth_attempts(client, tried_date, ok, at) values ('zz135-old', pg_temp.today(), false, now() - interval '3 days');
select pg_temp.as_anon();
insert into _t values ('read_expired', pg_temp.try(format('select public.guide_thread_v1(%L)', 'zz135-expired-token-0123456789abcdef')));
reset role;
select pg_temp.as_service();
insert into _t values ('sweep', pg_temp.try('select public.guide_sweep_v1()'));
reset role;
select pg_temp.as_anon();
insert into _t values ('read_after', pg_temp.try(format('select public.guide_thread_v1(%L)', pg_temp.tok())));
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'session' from _t where k = 'read_expired'), 'expiry: a token past its expiry is refused with reason session');
select ok((select (v ->> 'events')::int = 1 and (v ->> 'sessions')::int = 1 and (v ->> 'attempts')::int = 1 from _t where k = 'sweep'), 'sweep: service_role removes the 31-day event, the session expired 100 days ago and the 3-day-old attempt, one of each (the 29-day event and the session expired an hour ago are not removed)');
select ok((select count(*) = 0 from public.guide_events where device = 'zz135dev99') and (select count(*) = 1 from public.guide_events where device = 'zz135dev98') and (select count(*) = 6 from public.guide_events) and (select count(*) = 4 from public.guide_sessions), 'sweep: the 29-day event, recent events and sessions expired less than 95 days ago are left alone (event retention is 30 days)');
select ok((select v ->> 'ok' = 'true' and jsonb_array_length(v -> 'messages') = 3 from _t where k = 'read_after'), 'sweep: the live guest token still reads its three messages');

-- =============================================================================================================================================
-- 11. s136 review round 2: placeholder names, throttle key, caps, analytics caps and meta whitelist, single-property usage, explicit ACLs
-- =============================================================================================================================================
-- own house b2 with back-to-back stays: Beta (+1, real name), a placeholder-name stay (+2, no name, summary Reserved), "Airbnb Guest" (+3)
insert into public.properties(id, name, is_active) values (pg_temp.id('b2'), 'Zz S136 House', true);
insert into public.calendar_events(property_id, uid, source, checkin_date, checkout_date, guest_name, status, raw_summary) values
  (pg_temp.id('b2'), 'zz136-beta', 'airbnb', pg_temp.today() + 1, pg_temp.today() + 2, 'Zz Beta', 'confirmed', 'Reserved'),
  (pg_temp.id('b2'), 'zz136-blank', 'airbnb', pg_temp.today() + 2, pg_temp.today() + 3, null, 'confirmed', 'Reserved'),
  (pg_temp.id('b2'), 'zz136-airbnb', 'airbnb', pg_temp.today() + 3, pg_temp.today() + 4, 'Airbnb Guest', 'confirmed', 'Reserved');
-- a clean slate for the attempt counters (the earlier sections left failures on today's date)
delete from public.guide_auth_attempts where tried_date = pg_temp.today();

-- 11a. a placeholder name matches any initial in verify_booking: no session, no thread (reason no_name)
select pg_temp.as_anon();
insert into _t values ('nn1', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 2, 'R', 'zz136-n1', pg_temp.id('b2'))));
insert into _t values ('nn2', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 3, 'A', 'zz136-n2', pg_temp.id('b2'))));
insert into _t values ('nn3', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 2, 'Z', 'zz136-n3', pg_temp.id('b2'))));
reset role;
select ok((select bool_and(v ->> 'ok' = 'false' and v ->> 'reason' = 'no_name' and not v ? 'token' and not v ? 'thread_id' and not v ? 'guest_label') and count(*) = 3 from _t where k in ('nn1', 'nn2', 'nn3')), 's136 no_name: a booking with no name, or the name Airbnb Guest, answers no_name for any initial and carries no token, thread id or label');
select ok((select count(*) = 0 from public.guide_threads t join public.calendar_events c on c.id = t.calendar_event_id where c.property_id = pg_temp.id('b2')), 's136 no_name: no thread was created for the placeholder stays');
select ok((select count(*) = 3 from public.guide_auth_attempts where client in ('zz136-n1', 'zz136-n2', 'zz136-n3') and not ok) and (select count(*) = 0 from public.guide_sessions s join public.guide_threads t on t.id = s.thread_id join public.calendar_events c on c.id = t.calendar_event_id where c.property_id = pg_temp.id('b2')), 's136 no_name: each refusal is logged as a failed attempt (date probing is throttled) and mints nothing');

-- 11b. throttle key: cf-connecting-ip, else the RIGHTMOST x-forwarded-for entry; never the leftmost, never the caller's own client id
select set_config('request.headers', '{"x-forwarded-for": "1.1.1.1, 9.9.9.9"}', true);
select pg_temp.as_anon();
insert into _t values ('ip1', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-ipc', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '{"x-forwarded-for": "2.2.2.2, 9.9.9.9"}', true);
select pg_temp.as_anon();
insert into _t values ('ip2', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-ipc', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '{"cf-connecting-ip": "7.7.7.7", "x-forwarded-for": "3.3.3.3, 9.9.9.9"}', true);
select pg_temp.as_anon();
insert into _t values ('ip3', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-ipc', pg_temp.id('b2'))));
reset role;
select ok((select count(*) = 2 from public.guide_auth_attempts where client = 'ip:9.9.9.9' and not ok) and (select count(*) = 1 from public.guide_auth_attempts where client = 'ip:7.7.7.7' and not ok), 's136 key: two calls with different leftmost x-forwarded-for entries land on the same rightmost address; cf-connecting-ip wins over x-forwarded-for');
select ok((select count(*) = 0 from public.guide_auth_attempts where client in ('ip:1.1.1.1', 'ip:2.2.2.2', 'ip:3.3.3.3', 'zz136-ipc')), 's136 key: the leftmost entries and the caller''s own client id are never the key when an address header exists');
-- eight failures on one address shut it out however the leftmost entry rotates
insert into public.guide_auth_attempts(client, tried_date, ok) select 'ip:8.8.8.8', pg_temp.today() + 6, false from generate_series(1, 8);
select set_config('request.headers', '{"x-forwarded-for": "5.5.5.5, 8.8.8.8"}', true);
select pg_temp.as_anon();
insert into _t values ('rot1', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-rot', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '{"x-forwarded-for": "6.6.6.6, 8.8.8.8"}', true);
select pg_temp.as_anon();
insert into _t values ('rot2', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-rot', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '{"x-forwarded-for": "6.6.6.6, 8.8.4.4"}', true);
select pg_temp.as_anon();
insert into _t values ('rot3', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-rot', pg_temp.id('b2'))));
reset role;
select ok((select bool_and(v ->> 'reason' = 'throttled') from _t where k in ('rot1', 'rot2')), 's136 key: eight failures from one address shut it out although the leftmost entry rotates');
select ok((select v ->> 'reason' = 'no_match' from _t where k = 'rot3'), 's136 key: another rightmost address is not shut out');
-- no address header at all (a direct call, or a blank setting): the caller's client id is the key and nothing raises
select set_config('request.headers', '', true);
select pg_temp.as_anon();
insert into _t values ('nohdr', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-nohdr', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '{}', true);
select ok((select v ->> 'reason' = 'no_match' from _t where k = 'nohdr') and (select count(*) = 1 from public.guide_auth_attempts where client = 'zz136-nohdr' and not ok), 's136 key: with no address header (blank setting) the client id is the key and the call does not raise');

-- 11c. caps: 10 failures per check-in date per 15 minutes; 20 sessions per thread per day (busy)
insert into public.guide_auth_attempts(client, tried_date, ok) select 'zz136-d' || g, pg_temp.today() + 5, false from generate_series(1, 9) g;
select pg_temp.as_anon();
insert into _t values ('dc9', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 5, 'Q', 'zz136-dx', pg_temp.id('b2'))));
insert into _t values ('dc10', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 5, 'Q', 'zz136-dy', pg_temp.id('b2'))));
insert into _t values ('dc_other', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-dz', pg_temp.id('b2'))));
reset role;
select ok((select v ->> 'reason' = 'no_match' from _t where k = 'dc9') and (select v ->> 'reason' = 'throttled' and v ->> 'throttled' = 'true' from _t where k = 'dc10'), 's136 cap: nine failures for a check-in date still answer no_match, the tenth failure shuts the date (throttled), whoever asks');
select ok((select v ->> 'reason' = 'no_match' from _t where k = 'dc_other'), 's136 cap: a different check-in date is not affected');
-- fill the Tester thread to 20 sessions in the last day
insert into public.guide_sessions(token_hash, thread_id, expires_at)
select encode(extensions.digest('zz136-fill-' || g, 'sha256'), 'hex'), pg_temp.tid()::uuid, now() + interval '1 day'
  from generate_series(1, 20 - (select count(*) from public.guide_sessions where thread_id = pg_temp.tid()::uuid)::int) g;
select pg_temp.as_anon();
insert into _t values ('busy', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), 'T', 'zz136-busy', pg_temp.id('b1'))));
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'busy' and not v ? 'token' from _t where k = 'busy') and (select count(*) = 20 from public.guide_sessions where thread_id = pg_temp.tid()::uuid) and (select count(*) = 1 from public.guide_threads), 's136 cap: a thread with 20 sessions in the last day refuses a 21st (busy) and mints nothing');
update public.guide_sessions set created_at = now() - interval '2 days' where token_hash in (select encode(extensions.digest('zz136-fill-' || g, 'sha256'), 'hex') from generate_series(1, 20) g);
select pg_temp.as_anon();
insert into _t values ('busy_after', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), 'T', 'zz136-busy2', pg_temp.id('b1'))));
reset role;
select ok((select v ->> 'ok' = 'true' and v ->> 'thread_id' = pg_temp.tid() from _t where k = 'busy_after'), 's136 cap: sessions older than a day are not counted, so the thread mints again');

-- 11d. analytics: global cap, per-device cap by arrival time, meta whitelist
insert into public.guide_events(device, name) select 'zz136glob01', 'tap' from generate_series(1, 60);
select pg_temp.as_anon();
insert into _t values ('glob_full', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136dev11', jsonb_build_array(jsonb_build_object('name', 'guide_open'))::text)));
reset role;
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 0 from _t where k = 'glob_full') and (select count(*) = 0 from public.guide_events where device = 'zz136dev11'), 's136 track: at 60 events in the last minute across all devices a batch is dropped silently (ok, stored 0)');
delete from public.guide_events where device = 'zz136glob01';
select pg_temp.as_anon();
insert into _t values ('glob_open', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136dev11', jsonb_build_array(jsonb_build_object('name', 'guide_open'))::text)));
reset role;
select ok((select (v ->> 'stored')::int = 1 from _t where k = 'glob_open'), 's136 track: once the minute is below the cap the same call stores its event');
-- 600 events that arrived now but carry a client time of three days ago still count for the device (the cap reads arrival time)
insert into public.guide_events(at, device, name) select now() - interval '3 days', 'zz136dev12', 'tap' from generate_series(1, 600);
select pg_temp.as_anon();
insert into _t values ('dev_rate', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136dev12', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'rate' from _t where k = 'dev_rate') and (select count(*) = 600 from public.guide_events where device = 'zz136dev12'), 's136 track: 600 events in an hour from one device answer rate even when their client timestamps are old (arrival time counts)');
delete from public.guide_events where device = 'zz136dev12';
select pg_temp.as_anon();
insert into _t values ('meta1', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136dev13', jsonb_build_array(
  jsonb_build_object('name', 'tap', 'meta', jsonb_build_object('k', 'abc', 'n', 5, 'ok', true, 'lang', 'en', 'free', 'tok', 'src', 'has a space', 'kind', repeat('x', 41), 'tab', jsonb_build_object('a', 1), 'dir', jsonb_build_array(1))),
  jsonb_build_object('name', 'tap_ok', 'meta', jsonb_build_array(1, 2)),
  jsonb_build_object('name', 'tap_two', 'meta', jsonb_build_object('note', 'my room number is 12 and my phone is 0917'))
)::text)));
reset role;
select ok((select e.meta = '{"k": "abc", "n": 5, "ok": true, "lang": "en"}'::jsonb from public.guide_events e where e.device = 'zz136dev13' and e.name = 'tap'), 's136 track: meta keeps only whitelisted keys with a number, a boolean or a short token-like string (unknown keys, strings with spaces, 41-character strings, objects and arrays are dropped)');
select ok((select (v ->> 'stored')::int = 3 from _t where k = 'meta1') and (select count(*) = 2 and bool_and(e.meta = '{}'::jsonb) from public.guide_events e where e.device = 'zz136dev13' and e.name in ('tap_ok', 'tap_two')), 's136 track: a meta array and a meta object of free text store as an empty object, the events themselves are kept');

-- 11e. the staff usage report is single-property
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('us_other', pg_temp.try(format('select public.staff_guide_usage_v1(30, %L::uuid)', pg_temp.id('b2'))));
insert into _t values ('us_default', pg_temp.try(format('select public.staff_guide_usage_v1(30, %L::uuid)', pg_temp.dp())));
reset role;
select ok((select v ->> 'single_property' = 'true' and (v ->> 'devices')::int = 0 and v -> 'sections' = '[]'::jsonb from _t where k = 'us_other') and (select count(*) > 0 from public.guide_events), 's136 usage: for any property but the default one an authorised owner gets the flagged empty report although events exist');
select ok((select not v ? 'single_property' and (v ->> 'devices')::int >= 1 from _t where k = 'us_default'), 's136 usage: for the default property the report is the real one');

-- 11f. explicit ACLs
select ok((select bool_and(has_table_privilege('service_role', 'public.' || t, p)) from unnest(array['guide_threads', 'guide_sessions', 'guide_messages', 'guide_auth_attempts', 'guide_events']) t, unnest(array['select', 'insert', 'update', 'delete']) p), 's136 acl: service_role has select, insert, update and delete on all five guide tables');
select ok((select not bool_or(has_sequence_privilege(r, 'public.' || q, p)) from unnest(array['anon', 'authenticated']) r, unnest(array['guide_auth_attempts_id_seq', 'guide_events_id_seq']) q, unnest(array['usage', 'select', 'update']) p) and has_sequence_privilege('service_role', 'public.guide_events_id_seq', 'usage'), 's136 acl: anon and authenticated hold nothing on the two identity sequences; service_role may use them');

-- =============================================================================================================================================
-- 12. staff_guide_guests_v1 (s136 lane A-guests): guests who signed in to the guide. Clean slate: every earlier fixture thread is removed (its sessions and
--     messages cascade, its events keep thread_id null); fixtures below are on the default property. Times are relative to now() (constant inside the
--     transaction), so the window checks hold at any hour: A is stamped exactly now(), the rest minutes, hours or days back.
--   A f1 "Zzalpha"                  session 1 min ago, events: 2 guide_open, 3 checklist_done, 1 tap, newest event exactly now(); one guest message
--   B f3 "Zzbeta Mid Surnameson"    sessions 2 min and 90 min ago (no events), one STAFF message only
--   C f5 "Zzleak 0917123"           session 3 min ago (a digit in the label)      D f7 " " (blank label), session 4 min ago
--   E f9 40 days ago, F fb 30 hours ago, G fd 80 days ago, H ff 100 days ago
-- =============================================================================================================================================
delete from public.guide_threads;
insert into public.guide_threads(id, property_id, calendar_event_id, checkin_date, checkout_date, guest_label) values
  (pg_temp.id('f1'), pg_temp.dp(), pg_temp.id('f2'), pg_temp.today(), pg_temp.today() + 2, 'Zzalpha'),
  (pg_temp.id('f3'), pg_temp.dp(), pg_temp.id('f4'), pg_temp.today(), pg_temp.today() + 2, 'Zzbeta Mid Surnameson'),
  (pg_temp.id('f5'), pg_temp.dp(), pg_temp.id('f6'), pg_temp.today(), pg_temp.today() + 2, 'Zzleak 0917123'),
  (pg_temp.id('f7'), pg_temp.dp(), pg_temp.id('f8'), pg_temp.today(), pg_temp.today() + 2, ' '),
  (pg_temp.id('f9'), pg_temp.dp(), pg_temp.id('fa'), pg_temp.today() - 40, pg_temp.today() - 38, 'Zzold'),
  (pg_temp.id('fb'), pg_temp.dp(), pg_temp.id('fc'), pg_temp.today() - 2, pg_temp.today(), 'Zzedge'),
  (pg_temp.id('fd'), pg_temp.dp(), pg_temp.id('fe'), pg_temp.today() - 80, pg_temp.today() - 78, 'Zzeighty'),
  (pg_temp.id('ff'), pg_temp.dp(), pg_temp.id('f0'), pg_temp.today() - 100, pg_temp.today() - 98, 'Zzcentury');
insert into public.guide_sessions(token_hash, thread_id, expires_at, created_at) values
  (lpad(to_hex(1), 64, '0'), pg_temp.id('f1'), now() + interval '2 days', now() - interval '1 minute'),
  (lpad(to_hex(2), 64, '0'), pg_temp.id('f3'), now() + interval '2 days', now() - interval '2 minutes'),
  (lpad(to_hex(3), 64, '0'), pg_temp.id('f3'), now() + interval '2 days', now() - interval '90 minutes'),
  (lpad(to_hex(4), 64, '0'), pg_temp.id('f5'), now() + interval '2 days', now() - interval '3 minutes'),
  (lpad(to_hex(5), 64, '0'), pg_temp.id('f7'), now() + interval '2 days', now() - interval '4 minutes'),
  (lpad(to_hex(6), 64, '0'), pg_temp.id('f9'), now() + interval '2 days', now() - interval '40 days'),
  (lpad(to_hex(7), 64, '0'), pg_temp.id('fb'), now() + interval '2 days', now() - interval '30 hours'),
  (lpad(to_hex(8), 64, '0'), pg_temp.id('fd'), now() + interval '2 days', now() - interval '80 days'),
  (lpad(to_hex(9), 64, '0'), pg_temp.id('ff'), now() + interval '2 days', now() - interval '100 days');
insert into public.guide_events(at, device, thread_id, verified, name) values
  (now() - interval '30 seconds', 'zz136gdev01', pg_temp.id('f1'), true, 'guide_open'),
  (now() - interval '20 seconds', 'zz136gdev01', pg_temp.id('f1'), true, 'guide_open'),
  (now() - interval '25 seconds', 'zz136gdev01', pg_temp.id('f1'), true, 'checklist_done'),
  (now() - interval '15 seconds', 'zz136gdev01', pg_temp.id('f1'), true, 'checklist_done'),
  (now(), 'zz136gdev01', pg_temp.id('f1'), true, 'checklist_done'),
  (now() - interval '10 seconds', 'zz136gdev01', pg_temp.id('f1'), true, 'tap'),
  (now() - interval '5 seconds', 'zz136gdev02', null, false, 'guide_open'),       -- an anonymous device: belongs to no guest
  (now() - interval '5 minutes', 'zz136gdev03', pg_temp.id('f3'), true, 'section_view');  -- B has an event that is neither open nor checklist, older than its newest session
insert into public.guide_messages(thread_id, sender, body, client_msg_id) values
  (pg_temp.id('f1'), 'guest', 'Hello from A', 'zz136g-msg-0001'),
  (pg_temp.id('f3'), 'staff', 'Hello to B', 'zz136g-msg-0002');

select pg_temp.as_anon();
insert into _t values ('g_anon', pg_temp.try('select public.staff_guide_guests_v1(30)'));
reset role;
select pg_temp.as_user(pg_temp.id('03'));
insert into _t values ('g_cleaner', pg_temp.try('select public.staff_guide_guests_v1(30)'));
reset role;
select pg_temp.as_user(pg_temp.id('04'));
insert into _t values ('g_outsider', pg_temp.try('select public.staff_guide_guests_v1(30)'));
reset role;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('g30', pg_temp.try('select public.staff_guide_guests_v1(30)'));
insert into _t values ('g_other', pg_temp.try(format('select public.staff_guide_guests_v1(30, %L::uuid)', pg_temp.id('b2'))));
insert into _t values ('g1', pg_temp.try('select public.staff_guide_guests_v1(1)'));
insert into _t values ('g0', pg_temp.try('select public.staff_guide_guests_v1(0)'));
insert into _t values ('gneg', pg_temp.try('select public.staff_guide_guests_v1(-5)'));
insert into _t values ('g3', pg_temp.try('select public.staff_guide_guests_v1(3)'));
insert into _t values ('g90', pg_temp.try('select public.staff_guide_guests_v1(90)'));
insert into _t values ('g1000', pg_temp.try('select public.staff_guide_guests_v1(1000)'));
reset role;

select ok((select v ->> 'err' = '42501' from _t where k = 'g_anon'), 'guests: anon holds no execute and gets 42501');
select ok((select v ->> 'err' = '42501' and v ->> 'msg' = 'staff access denied' from _t where k = 'g_cleaner')
      and (select v ->> 'err' = '42501' and v ->> 'msg' = 'staff access denied' from _t where k = 'g_outsider'),
  'guests: a cleaner without manage_guest_inbox and a staff user with no profile are refused first with 42501 staff access denied (the usage report error shape)');
select ok((select v = '{"guests": [], "total": 0, "single_property": true}'::jsonb from _t where k = 'g_other'),
  'guests: any property but the default one answers exactly {"guests": [], "total": 0, "single_property": true} although sessions exist');
select ok((select (select array_agg(k order by k) from jsonb_object_keys(v) k) = array['guests', 'total'] and jsonb_typeof(v -> 'guests') = 'array' and jsonb_typeof(v -> 'total') = 'number' from _t where k = 'g30')
      and (select bool_and((select array_agg(k order by k) from jsonb_object_keys(g) k) = array['checkin_date', 'checklist_done', 'checkout_date', 'first_seen', 'guest_label', 'last_seen', 'messaged', 'opens', 'thread_id'])
             from _t, jsonb_array_elements(v -> 'guests') g where k = 'g30'),
  'guests: the one-argument call returns exactly guests and total, and each guest exactly the nine contract keys');
select ok((select array(select (g ->> 'thread_id')::uuid from jsonb_array_elements(v -> 'guests') g) = array[pg_temp.id('f1'), pg_temp.id('f3'), pg_temp.id('f5'), pg_temp.id('f7'), pg_temp.id('fb')] and (v ->> 'total')::int = 5 from _t where k = 'g30'),
  'guests: ordered last_seen desc A, B, C, D, F (the 40-, 80- and 100-day sessions are outside the 30-day window); total 5');
select ok((select array(select g ->> 'guest_label' from jsonb_array_elements(v -> 'guests') g) = array['Zzalpha', 'Zzbeta S.', 'Guest', 'Guest', 'Zzedge'] from _t where k = 'g30'),
  'guests: labels are first name, first name plus last initial for a longer label, and Guest for a label with a digit or a blank one');
select ok((select position('Surnameson' in v::text) = 0 and position('0917' in v::text) = 0 and position('@' in v::text) = 0 from _t where k = 'g30'),
  'guests: the report text never holds the surname, the digits of a phone-like label or an e-mail sign');
select ok((select (g ->> 'opens')::int = 2 and (g ->> 'checklist_done')::int = 3 and (g ->> 'messaged')::boolean is true from _t, jsonb_array_elements(v -> 'guests') g where k = 'g30' and g ->> 'thread_id' = pg_temp.id('f1')::text),
  'guests: A has 2 opens (two guide_open events beat one session), 3 checklist_done events (the tap and the anonymous device are not counted) and messaged true');
select ok((select (g ->> 'opens')::int = 2 and (g ->> 'checklist_done')::int = 0 and (g ->> 'messaged')::boolean is false from _t, jsonb_array_elements(v -> 'guests') g where k = 'g30' and g ->> 'thread_id' = pg_temp.id('f3')::text),
  'guests: B has 2 opens from its two sessions (no open events), 0 checklist_done, and messaged false because only staff wrote');
select ok((select (g ->> 'first_seen')::timestamptz = (select min(created_at) from public.guide_sessions where thread_id = pg_temp.id('f1')) and (g ->> 'last_seen')::timestamptz = now()
        from _t, jsonb_array_elements(v -> 'guests') g where k = 'g30' and g ->> 'thread_id' = pg_temp.id('f1')::text)
      and (select (g ->> 'first_seen')::timestamptz = now() - interval '90 minutes' and (g ->> 'last_seen')::timestamptz = now() - interval '2 minutes'
        from _t, jsonb_array_elements(v -> 'guests') g where k = 'g30' and g ->> 'thread_id' = pg_temp.id('f3')::text),
  'guests: first_seen is the first session; last_seen is the newest session or event (A: the event at now(); B: its second session, 2 minutes ago)');
select ok((select (g ->> 'checkin_date')::date = pg_temp.today() and (g ->> 'checkout_date')::date = pg_temp.today() + 2 from _t, jsonb_array_elements(v -> 'guests') g where k = 'g30' and g ->> 'thread_id' = pg_temp.id('f1')::text),
  'guests: check-in and check-out dates come from the thread');
select ok((select jsonb_array_length(v -> 'guests') = 5 and (v ->> 'total')::int = 5 and not exists (select 1 from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' in (pg_temp.id('f9')::text, pg_temp.id('fd')::text, pg_temp.id('ff')::text)) from _t where k = 'g30'),
  'guests: the 30-day window leaves out E (40 days), G (80 days) and H (100 days)');
select ok((select (v ->> 'total')::int = 7 and exists (select 1 from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' = pg_temp.id('f9')::text) and exists (select 1 from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' = pg_temp.id('fd')::text)
        and not exists (select 1 from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' = pg_temp.id('ff')::text) from _t where k = 'g90'),
  'guests: a 90-day window holds E (40 days) and G (80 days) but not H (100 days): total 7');
select ok((select v = (select v from _t where k = 'g90') from _t where k = 'g1000'),
  'guests: p_days above 90 is clamped to 90 (1000 answers exactly what 90 does, H still out)');
select ok((select v = (select v from _t where k = 'g1') and v = (select v from _t where k = 'gneg') and exists (select 1 from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' = pg_temp.id('f1')::text)
        and not exists (select 1 from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' = pg_temp.id('fb')::text) from _t where k = 'g0'),
  'guests: p_days 0 and -5 are clamped to 1 (same answer as 1: today only, A in, F from 30 hours ago out)');
select ok((select exists (select 1 from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' = pg_temp.id('fb')::text) from _t where k = 'g3'),
  'guests: a 3-day window holds F (a session 30 hours ago)');

-- cap: 65 more guests inside the window, each a session 31 to 95 seconds ago (all newer than B, C, D and F)
insert into public.guide_threads(id, property_id, calendar_event_id, checkin_date, checkout_date, guest_label)
select ('e1360000-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::uuid, pg_temp.dp(), ('e1360000-0000-4000-9000-' || lpad(to_hex(i), 12, '0'))::uuid,
       pg_temp.today(), pg_temp.today() + 1, 'Zzcap'
  from generate_series(1, 65) i;
insert into public.guide_sessions(token_hash, thread_id, expires_at, created_at)
select lpad(to_hex(1000 + i), 64, '0'), ('e1360000-0000-4000-8000-' || lpad(to_hex(i), 12, '0'))::uuid, now() + interval '2 days', now() - make_interval(secs => 30 + i)
  from generate_series(1, 65) i;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('gcap', pg_temp.try('select public.staff_guide_guests_v1(30)'));
reset role;
select ok((select jsonb_array_length(v -> 'guests') = 60 and (v ->> 'total')::int = 70 from _t where k = 'gcap'),
  'guests: 70 guests in the window answer 60 rows and total 70 (the uncapped count)');
select ok((select (v -> 'guests' -> 0 ->> 'thread_id')::uuid = pg_temp.id('f1')
        and not exists (select 1 from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' in (pg_temp.id('f3')::text, pg_temp.id('f5')::text, pg_temp.id('f7')::text, pg_temp.id('fb')::text)) from _t where k = 'gcap'),
  'guests: the capped 60 start with A and drop the oldest (B, C, D and F are cut)');
select ok((select bool_and(cur <= prev) from (select (g.value ->> 'last_seen')::timestamptz cur, lag((g.value ->> 'last_seen')::timestamptz) over (order by g.ordinality) prev
        from _t, jsonb_array_elements(v -> 'guests') with ordinality g(value, ordinality) where k = 'gcap') s where prev is not null),
  'guests: the 60 rows run in descending last_seen order');

select ok(has_function_privilege('authenticated', 'public.staff_guide_guests_v1(integer,uuid)', 'execute')
      and not has_function_privilege('anon', 'public.staff_guide_guests_v1(integer,uuid)', 'execute')
      and not has_function_privilege('service_role', 'public.staff_guide_guests_v1(integer,uuid)', 'execute')
      and (select p.prosecdef and p.proconfig @> array['search_path=""'] from pg_proc p where p.oid = 'public.staff_guide_guests_v1(integer,uuid)'::regprocedure),
  'guests acl: authenticated only (anon and service_role hold no execute), SECURITY DEFINER with search_path pinned');

-- =============================================================================================================================================
-- 13. s136 round 3: throttle key (x-real-ip, garbage, malformed headers), storage bound, advisory locks, explicit ACLs
-- =============================================================================================================================================
delete from public.guide_auth_attempts;
delete from public.guide_events;

-- 13a. throttle key: x-real-ip is NEVER used (a client can send it): the rightmost x-forwarded-for entry or cf-connecting-ip wins, else the client id
select set_config('request.headers', '{"x-real-ip": "4.4.4.4", "x-forwarded-for": "1.1.1.1, 9.9.9.9"}', true);
select pg_temp.as_anon();
insert into _t values ('rip1', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-rip1', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '{"cf-connecting-ip": "7.7.7.7", "x-real-ip": "4.4.4.4"}', true);
select pg_temp.as_anon();
insert into _t values ('rip2', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-rip2', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '{"x-real-ip": "4.4.4.4"}', true);
select pg_temp.as_anon();
insert into _t values ('rip3', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-rip3', pg_temp.id('b2'))));
reset role;
select ok((select count(*) = 1 from public.guide_auth_attempts where client = 'ip:9.9.9.9' and not ok) and (select count(*) = 1 from public.guide_auth_attempts where client = 'ip:7.7.7.7' and not ok)
      and (select count(*) = 1 from public.guide_auth_attempts where client = 'zz136-rip3' and not ok)
      and (select count(*) = 0 from public.guide_auth_attempts where client in ('ip:4.4.4.4', 'ip:1.1.1.1', 'zz136-rip1', 'zz136-rip2'))
      and (select bool_and(v ->> 'reason' = 'no_match') from _t where k in ('rip1', 'rip2', 'rip3')),
  's136 key: a spoofed x-real-ip is never the key (rightmost x-forwarded-for, cf-connecting-ip, else the client id win)');

-- 13b. garbage header values are ignored: a value that is not address-shaped is skipped (next header tried, else the client id)
select set_config('request.headers', '{"cf-connecting-ip": "evil;drop table", "x-real-ip": "not an ip!", "x-forwarded-for": "1.1.1.1, <b>x</b>"}', true);
select pg_temp.as_anon();
insert into _t values ('gar1', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-gar1', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', format('{"cf-connecting-ip": "%s", "x-real-ip": "1"}', repeat('a', 46)), true);
select pg_temp.as_anon();
insert into _t values ('gar2', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-gar2', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '{"cf-connecting-ip": "evil;drop table", "x-forwarded-for": "1.1.1.1,  5.5.5.5  "}', true);
select pg_temp.as_anon();
insert into _t values ('gar3', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-gar3', pg_temp.id('b2'))));
reset role;
select ok((select count(*) = 1 from public.guide_auth_attempts where client = 'zz136-gar1' and not ok) and (select count(*) = 1 from public.guide_auth_attempts where client = 'zz136-gar2' and not ok)
      and (select count(*) = 0 from public.guide_auth_attempts where client in ('ip:evil;drop table', 'ip:not an ip!', 'ip:1', 'ip:1.1.1.1') or client like 'ip:aaaa%' or client like 'ip:<%'),
  's136 key: garbage address headers (punctuation, spaces, a 46-character value, a one-character value, markup) are ignored and the client id is the key');
select ok((select count(*) = 1 from public.guide_auth_attempts where client = 'ip:5.5.5.5' and not ok) and (select count(*) = 0 from public.guide_auth_attempts where client = 'zz136-gar3')
      and (select bool_and(v ->> 'reason' = 'no_match') from _t where k in ('gar1', 'gar2', 'gar3')),
  's136 key: a garbage cf-connecting-ip is skipped and the next valid header (rightmost x-forwarded-for, trimmed) is used; every call answers no_match');

-- 13c. malformed request.headers (bad JSON, a JSON string, a JSON array) never raises: the call answers as usual and keys on the client id
select set_config('request.headers', '{not json', true);
select pg_temp.as_anon();
insert into _t values ('bad1', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-bad1', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '"just a string"', true);
select pg_temp.as_anon();
insert into _t values ('bad2', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-bad2', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '[1, 2]', true);
select pg_temp.as_anon();
insert into _t values ('bad3', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 1, 'Q', 'zz136-bad3', pg_temp.id('b2'))));
reset role;
select set_config('request.headers', '{}', true);
select ok((select bool_and(v ->> 'reason' = 'no_match' and not v ? 'err') and count(*) = 3 from _t where k in ('bad1', 'bad2', 'bad3'))
      and (select count(*) = 3 from public.guide_auth_attempts where client in ('zz136-bad1', 'zz136-bad2', 'zz136-bad3') and not ok),
  's136 key: a malformed request.headers setting (broken JSON, a JSON string, a JSON array) does not raise; the key falls back to the client id');

-- 13d. advisory locks: one transaction here, so the locks taken by the calls above and below are still held and visible in pg_locks
select ok(exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.granted
                    and ((l.classid::bigint << 32) | l.objid::bigint) = hashtext('guide_session:' || (pg_temp.today() + 1)::text)::bigint),
  's136 race: guide_session_v1 holds the transaction advisory lock for its check-in date (concurrent mints for one date are serialised; a real two-session race is not testable inside one pgTAP transaction)');

-- 13e. analytics caps: 60 / minute across all devices (59 stores, 60 and 61 drop), 1000 / rolling 24 h (999 stores, 1000 and 1001 drop)
insert into public.guide_events(device, name) select 'zz136c300a', 'tap' from generate_series(1, 59);
select pg_temp.as_anon();
insert into _t values ('m299', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136c300b', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
insert into _t values ('m300', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136c300c', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
reset role;
insert into public.guide_events(device, name) values ('zz136c300a', 'tap');
select pg_temp.as_anon();
insert into _t values ('m301', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136c300d', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
reset role;
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 1 from _t where k = 'm299') and (select count(*) = 1 from public.guide_events where device = 'zz136c300b'),
  's136 track: with 59 events in the last minute a batch is still stored (the 60th event)');
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 0 from _t where k = 'm300') and (select count(*) = 0 from public.guide_events where device = 'zz136c300c'),
  's136 track: with exactly 60 events in the last minute the next batch is dropped silently (ok, stored 0)');
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 0 from _t where k = 'm301') and (select count(*) = 0 from public.guide_events where device = 'zz136c300d') and (select count(*) = 61 from public.guide_events where received_at > now() - interval '1 minute'),
  's136 track: with 61 events in the last minute (a row written past the function) the next batch is dropped too');
select ok(exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.granted and ((l.classid::bigint << 32) | l.objid::bigint) = hashtext('guide_track')::bigint),
  's136 race: guide_track_v1 holds the global transaction advisory lock (pg_try_advisory_xact_lock) before it counts (parallel batches cannot read the same count and overshoot the caps together)');

delete from public.guide_events;
-- 24 h cap: five rows from 25 hours ago do not count (rolling window); 999 rows from two hours ago (old enough to stay clear of the per-minute cap) do
insert into public.guide_events(at, received_at, device, name) select now() - interval '25 hours', now() - interval '25 hours', 'zz136c24old', 'tap' from generate_series(1, 5);
insert into public.guide_events(at, received_at, device, name) select now() - interval '2 hours', now() - interval '2 hours', 'zz136c24fill', 'tap' from generate_series(1, 999);
select pg_temp.as_anon();
insert into _t values ('d999', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136c24a', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
insert into _t values ('d1000', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136c24b', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
reset role;
insert into _t values ('d1000_cnt', to_jsonb((select count(*) from public.guide_events where received_at > now() - interval '24 hours')));
insert into public.guide_events(at, received_at, device, name) values (now() - interval '2 hours', now() - interval '2 hours', 'zz136c24fill', 'tap');
select pg_temp.as_anon();
insert into _t values ('d1001', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136c24c', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
reset role;
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 1 from _t where k = 'd999') and (select count(*) = 1 from public.guide_events where device = 'zz136c24a'),
  's136 track: 999 events in the last 24 hours (five older ones not counted) still leave room for one more');
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 0 from _t where k = 'd1000') and (select count(*) = 0 from public.guide_events where device = 'zz136c24b') and (select (v #>> '{}')::int = 1000 from _t where k = 'd1000_cnt'),
  's136 track: with exactly 1000 events in the last 24 hours the next batch is dropped silently (ok, stored 0)');
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 0 from _t where k = 'd1001') and (select count(*) = 0 from public.guide_events where device = 'zz136c24c') and (select count(*) = 1001 from public.guide_events where received_at > now() - interval '24 hours'),
  's136 track: with 1001 events in the last 24 hours the next batch is dropped too');
delete from public.guide_events;

-- 13f. meta over 200 bytes AS STORED (pg_column_size) is replaced by an empty object, the event is kept. Hand-computed stored size of an object of four
--      string pairs k, src, kind, lang: 4 (varlena header) + 4 (container header) + 8 entries x 4 + 12 key bytes + the value bytes = 52 + values.
--      Values of 40 + 40 + 40 + 28 = 148 bytes give 200; 40 + 40 + 40 + 29 give 201.
select pg_temp.as_anon();
insert into _t values ('meta200', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136m200a', jsonb_build_array(jsonb_build_object('name', 'tap', 'meta',
  jsonb_build_object('k', repeat('a', 40), 'src', repeat('b', 40), 'kind', repeat('c', 40), 'lang', repeat('d', 28))))::text)));
insert into _t values ('meta201', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136m201a', jsonb_build_array(jsonb_build_object('name', 'tap', 'meta',
  jsonb_build_object('k', repeat('a', 40), 'src', repeat('b', 40), 'kind', repeat('c', 40), 'lang', repeat('d', 29))))::text)));
insert into _t values ('metabig', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136m999a', jsonb_build_array(jsonb_build_object('name', 'tap', 'section', 'home', 'meta',
  jsonb_build_object('k', repeat('a', 40), 'src', repeat('b', 40), 'kind', repeat('c', 40), 'lang', repeat('d', 40), 'tab', repeat('e', 40), 'theme', repeat('f', 40), 'dir', repeat('g', 40), 'from', repeat('h', 40))))::text)));
reset role;
select ok((select (v ->> 'stored')::int = 1 from _t where k = 'meta200') and (select e.meta = jsonb_build_object('k', repeat('a', 40), 'src', repeat('b', 40), 'kind', repeat('c', 40), 'lang', repeat('d', 28)) and pg_column_size(e.meta) = 200 from public.guide_events e where e.device = 'zz136m200a'),
  's136 track: a meta object of exactly 200 stored bytes is kept whole');
select ok(pg_column_size(jsonb_build_object('k', repeat('a', 40), 'src', repeat('b', 40), 'kind', repeat('c', 40), 'lang', repeat('d', 29))) = 201
      and (select (v ->> 'stored')::int = 1 from _t where k = 'meta201') and (select e.meta = '{}'::jsonb and e.name = 'tap' from public.guide_events e where e.device = 'zz136m201a')
      and (select (v ->> 'stored')::int = 1 from _t where k = 'metabig') and (select e.meta = '{}'::jsonb and e.section = 'home' from public.guide_events e where e.device = 'zz136m999a'),
  's136 track: a meta object of 201 stored bytes, or eight 40-character values, is replaced by an empty object and the event is stored with its other columns');
delete from public.guide_events;

-- 13g. explicit service_role ACLs: only the sweep is executable by service_role (no edge function calls any guide function)
select ok((select not bool_or(has_function_privilege('service_role', f, 'execute')) from unnest(array['public.guide_session_v1(date,text,text,uuid)', 'public.guide_thread_v1(text,timestamptz)', 'public.guide_send_v1(text,text,text)',
    'public.guide_track_v1(text,jsonb,text,text)', 'public.guide_token_thread_v1(text)', 'public.guide_messages_push_trg()', 'public.staff_guide_threads_v1(uuid)', 'public.staff_guide_thread_v1(uuid)',
    'public.staff_guide_reply_v1(uuid,text,text)', 'public.staff_guide_resolve_v1(uuid,boolean)', 'public.staff_guide_usage_v1(integer,uuid)', 'public.staff_guide_guests_v1(integer,uuid)']::regprocedure[]) f)
      and has_function_privilege('service_role', 'public.guide_sweep_v1()', 'execute'),
  's136 acl: service_role may execute guide_sweep_v1 and none of the other twelve guide_* / staff_guide_* functions (ML-21, restated in the migration)');

-- =============================================================================================================================================
-- 14. token expiry guard. verify_booking (UTC date) can say "not expired" for up to eight hours after the token's Manila expiry; a stub of it, replaced inside this
--     rolled-back transaction, makes both sides of the boundary deterministic. Runs last: the stub is not restored.
-- =============================================================================================================================================
create or replace function public.verify_booking(p_checkin_date date, p_initial text default null::text, p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb language sql as $$
  select jsonb_build_object('found', true, 'expired', false, 'match', true, 'first_name', 'Zzstub', 'checkin_date', p_checkin_date, 'checkout_date', p_checkin_date)
$$;
create temp table _cnt as select (select count(*) from public.guide_threads) threads, (select count(*) from public.guide_sessions) sessions;
select pg_temp.as_anon();
insert into _t values ('exp_dead', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() - 2, 'Z', 'zz136-exp1', pg_temp.id('b2'))));
insert into _t values ('exp_live', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() - 1, 'Z', 'zz136-exp2', pg_temp.id('b2'))));
reset role;
select ok((select v ->> 'ok' = 'false' and v ->> 'reason' = 'expired' and not v ? 'token' and not v ? 'thread_id' from _t where k = 'exp_dead')
      and (select (select count(*) from public.guide_threads) = c.threads and (select count(*) from public.guide_sessions) = c.sessions from _cnt c),
  's136 expiry: when verify_booking says not expired but the token would already be past its Manila expiry (checkout = today - 2), the answer is expired and no thread or session is created');
select ok((select v ->> 'reason' = 'no_match' from _t where k = 'exp_live'),
  's136 expiry: one day later (checkout = today - 1, expiry is still ahead) the guard lets the call through: it reaches the calendar lookup (no such stay: no_match), not expired');

-- =============================================================================================================================================
-- 15. s136 round 5: inline retention, exact caps, bounded value, measured size, 30-day usage window, sessions kept for the guests report, lock_timeout, trigger fire
-- =============================================================================================================================================
-- 15a. inline retention: every guide_track_v1 call that gets the lock deletes at most 200 events older than 30 days (oldest first); newer rows are untouched
delete from public.guide_events;
insert into public.guide_events(at, received_at, device, name) select now() - interval '31 days', now() - interval '31 days' - make_interval(secs => i), 'zz136old001', 'tap' from generate_series(1, 250) i;
insert into public.guide_events(at, received_at, device, name) values (now() - interval '29 days', now() - interval '29 days', 'zz136new001', 'tap');
select pg_temp.as_anon();
insert into _t values ('ret1', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136ret001', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
reset role;
select ok((select (v ->> 'stored')::int = 1 from _t where k = 'ret1') and (select count(*) = 50 from public.guide_events where device = 'zz136old001')
      and (select count(*) = 1 from public.guide_events where device = 'zz136new001'),
  's136 retention: one accepted call deletes exactly 200 of 250 events older than 30 days and leaves the 29-day-old event alone');
select ok((select min(received_at) > now() - interval '31 days' - interval '51 seconds' from public.guide_events where device = 'zz136old001') and (select count(*) = 1 from public.guide_events where device = 'zz136ret001'),
  's136 retention: the oldest rows go first (the 50 survivors are the newest of the stale ones)');
select pg_temp.as_anon();
insert into _t values ('ret2', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136ret002', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
reset role;
select ok((select count(*) = 0 from public.guide_events where device = 'zz136old001') and (select count(*) = 3 from public.guide_events),
  's136 retention: the next call removes the remaining 50 stale events; only the fresh ones remain');
delete from public.guide_events;

-- a call that the minute cap then drops still trims (the delete runs before the caps)
insert into public.guide_events(device, name) select 'zz136trim01', 'tap' from generate_series(1, 60);
insert into public.guide_events(at, received_at, device, name) select now() - interval '31 days', now() - interval '31 days', 'zz136old002', 'tap' from generate_series(1, 10);
select pg_temp.as_anon();
insert into _t values ('ret3', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136ret003', jsonb_build_array(jsonb_build_object('name', 'tap'))::text)));
reset role;
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 0 from _t where k = 'ret3') and (select count(*) = 0 from public.guide_events where device = 'zz136old002') and (select count(*) = 60 from public.guide_events),
  's136 retention: a call dropped by the minute cap (stored 0) still removes the stale events');
delete from public.guide_events;

-- 15b. the caps are exact: a batch is cut to the room left under the minute, the day and the device cap (never an overshoot)
insert into public.guide_events(device, name) select 'zz136room01', 'tap' from generate_series(1, 57);
select pg_temp.as_anon();
insert into _t values ('room_min', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136room02', (select jsonb_agg(jsonb_build_object('name', 'tap'))::text from generate_series(1, 5)))));
reset role;
select ok((select v ->> 'ok' = 'true' and (v ->> 'stored')::int = 3 from _t where k = 'room_min') and (select count(*) = 3 from public.guide_events where device = 'zz136room02')
      and (select count(*) = 60 from public.guide_events where received_at > now() - interval '1 minute'),
  's136 room: with 57 events in the last minute a batch of five stores three (60 - 57) and the minute holds exactly 60');
delete from public.guide_events;
insert into public.guide_events(at, received_at, device, name) select now() - interval '2 hours', now() - interval '2 hours', 'zz136room03', 'tap' from generate_series(1, 998);
select pg_temp.as_anon();
insert into _t values ('room_day', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136room04', (select jsonb_agg(jsonb_build_object('name', 'tap'))::text from generate_series(1, 5)))));
reset role;
select ok((select (v ->> 'stored')::int = 2 from _t where k = 'room_day') and (select count(*) = 2 from public.guide_events where device = 'zz136room04')
      and (select count(*) = 1000 from public.guide_events where received_at > now() - interval '24 hours'),
  's136 room: with 998 events in the last 24 hours a batch of five stores two (1000 - 998) and the day holds exactly 1000');
delete from public.guide_events;
insert into public.guide_events(at, received_at, device, name) select now() - interval '30 minutes', now() - interval '30 minutes', 'zz136room05', 'tap' from generate_series(1, 598);
select pg_temp.as_anon();
insert into _t values ('room_dev', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136room05', (select jsonb_agg(jsonb_build_object('name', 'tap'))::text from generate_series(1, 5)))));
reset role;
select ok((select (v ->> 'stored')::int = 2 from _t where k = 'room_dev') and (select count(*) = 600 from public.guide_events where device = 'zz136room05'),
  's136 room: with 598 events in the last hour from one device a batch of five stores two (600 - 598)');
delete from public.guide_events;

-- 15c. value is bounded: at most 1e9 in size, rounded to 3 decimals; anything larger is stored as null and the event is kept
select pg_temp.as_anon();
insert into _t values ('val', pg_temp.try(format('select public.guide_track_v1(%L, %L::jsonb)', 'zz136val001',
  '[{"name":"tap","target":"v1","value":12.34567},{"name":"tap","target":"v2","value":1000000000},{"name":"tap","target":"v3","value":1000000000.5},{"name":"tap","target":"v4","value":1e400},{"name":"tap","target":"v5","value":-1000000000.0004},{"name":"tap","target":"v6","value":"12"}]')));
reset role;
select ok((select (v ->> 'stored')::int = 6 from _t where k = 'val')
      and (select array_agg(e.value::text order by e.target) from public.guide_events e where e.device = 'zz136val001') is not distinct from array['12.346', '1000000000.000', null, null, null, null]::text[],
  's136 value: 12.34567 is stored as 12.346 and 1e9 is kept; 1000000000.5, 1e400, -1000000000.0004 and a string store null; all six events are kept');
delete from public.guide_events;

-- 15d. size, measured on clones of guide_events (like ... including all: same columns, CHECKs and all four indexes; a clone, so the dead rows this suite left in the
--      real table do not count). 30000 rows = 30 days x 1000 a day, loaded in arrival order. Worst case: every field at its maximum width, random device ids.
create temp table _sz_worst (like public.guide_events including all);
insert into _sz_worst(at, received_at, device, thread_id, verified, name, section, target, value, meta, version)
select now() - interval '30 days' + make_interval(secs => i * 86), now() - interval '30 days' + make_interval(secs => i * 86),
       md5(i::text) || 'abcdefgh', pg_temp.id('c9'), true, 'n' || repeat('z', 39), 's' || repeat('y', 39), 't' || repeat('w', 79), 999999999.999,
       jsonb_build_object('k', repeat('a', 40), 'src', repeat('b', 40), 'kind', repeat('c', 40), 'lang', repeat('d', 28)), '12345678.123'
  from generate_series(1, 30000) i;
create temp table _sz_typ (like public.guide_events including all);
insert into _sz_typ(at, received_at, device, verified, name, section, target, value, meta, version)
select now() - interval '30 days' + make_interval(secs => i * 86), now() - interval '30 days' + make_interval(secs => i * 86),
       md5((i % 400)::text) || 'abcd', false, 'section_view', 'house_rules', 'card:wifi-password', 12, '{"k": "abc", "src": "home"}'::jsonb, '8.0.0'
  from generate_series(1, 30000) i;
select ok((select count(*) = 30000 and bool_and(char_length(device) = 40 and char_length(name) = 40 and char_length(section) = 40 and char_length(target) = 80 and char_length(version) = 12
             and pg_column_size(meta) = 200 and thread_id is not null and value = 999999999.999) from _sz_worst)
      and (select count(*) = 4 from pg_indexes where tablename = '_sz_worst') and (select count(*) = 4 from pg_indexes where schemaname = 'public' and tablename = 'guide_events'),
  's136 size: the worst-case clone holds 30000 rows with every field at its maximum width and the same four indexes as guide_events');
insert into _t values ('wider', (select jsonb_agg(pg_temp.try('insert into public.guide_events(device, name, section, target, value, meta, version) values (' || x || ') returning to_jsonb(1)') ->> 'err') from unnest(array[
  format('%L, %L, null, null, null, %L, null', repeat('d', 41), 'tap', '{}'),
  format('%L, %L, null, null, null, %L, null', 'zz136wide01', 'n' || repeat('z', 40), '{}'),
  format('%L, %L, %L, null, null, %L, null', 'zz136wide01', 'tap', repeat('s', 41), '{}'),
  format('%L, %L, null, %L, null, %L, null', 'zz136wide01', 'tap', repeat('t', 81), '{}'),
  format('%L, %L, null, null, 1000000000.001, %L, null', 'zz136wide01', 'tap', '{}'),
  format('%L, %L, null, null, 1.0001, %L, null', 'zz136wide01', 'tap', '{}'),
  format('%L, %L, null, null, null, %L, null', 'zz136wide01', 'tap', jsonb_build_object('k', repeat('a', 40), 'src', repeat('b', 40), 'kind', repeat('c', 40), 'lang', repeat('d', 29))::text),
  format('%L, %L, null, null, null, %L, %L', 'zz136wide01', 'tap', '{}', '1234567890.12')]) x));
select ok((select v = '["23514", "23514", "23514", "23514", "23514", "23514", "23514", "23514"]'::jsonb from _t where k = 'wider') and (select count(*) = 0 from public.guide_events where device = 'zz136wide01'),
  's136 size: one character or byte more in device, name, section, target, value (size and decimals), meta or version is refused by the table itself (23514, eight probes)');
select ok(pg_total_relation_size('_sz_worst') < 30 * 1024 * 1024, 's136 size: 30000 maximum-width events with all four indexes stay under 30 MB');
select ok(pg_total_relation_size('_sz_typ') < 12 * 1024 * 1024, 's136 size: 30000 typical events with all four indexes stay under 12 MB');
select diag('SIZE worst total=' || pg_total_relation_size('_sz_worst') || ' heap=' || pg_relation_size('_sz_worst') || ' indexes=' || pg_indexes_size('_sz_worst') || ' per_row=' || pg_total_relation_size('_sz_worst') / 30000
  || ' [' || (select string_agg(indexname || '=' || pg_relation_size(quote_ident(indexname)::regclass), ' ' order by indexname) from pg_indexes where tablename = '_sz_worst') || ']');
select diag('SIZE typical total=' || pg_total_relation_size('_sz_typ') || ' heap=' || pg_relation_size('_sz_typ') || ' indexes=' || pg_indexes_size('_sz_typ') || ' per_row=' || pg_total_relation_size('_sz_typ') / 30000);
drop table _sz_worst, _sz_typ;

-- 15e. the usage report answers for at most 30 days (the retention): p_days 365 is clamped to 30
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('us365', pg_temp.try(format('select public.staff_guide_usage_v1(365, %L::uuid)', pg_temp.dp())));
reset role;
select ok((select (v ->> 'since')::date = pg_temp.today() - 29 from _t where k = 'us365'), 's136 usage: p_days 365 is clamped to 30 (since = today minus 29, Manila)');

-- 15f. sessions are swept 95 days after expiry, so the guests report keeps a guest who checked out 12 days ago (session expired 10 days ago, 30-day window); one expired 100 days ago goes.
--      The 65 cap-test guests of section 12 are removed first (they would fill the report's 60 rows ahead of a 12-day-old sign-in).
delete from public.guide_threads where guest_label = 'Zzcap';
insert into public.guide_threads(id, property_id, calendar_event_id, checkin_date, checkout_date, guest_label) values
  (pg_temp.id('c1'), pg_temp.dp(), pg_temp.id('c2'), pg_temp.today() - 14, pg_temp.today() - 12, 'Zzkept'),
  (pg_temp.id('c3'), pg_temp.dp(), pg_temp.id('c4'), pg_temp.today() - 104, pg_temp.today() - 102, 'Zzgone');
insert into public.guide_sessions(token_hash, thread_id, expires_at, created_at) values
  (lpad(to_hex(2001), 64, '0'), pg_temp.id('c1'), now() - interval '10 days', now() - interval '12 days'),
  (lpad(to_hex(2002), 64, '0'), pg_temp.id('c3'), now() - interval '100 days', now() - interval '102 days');
select pg_temp.as_service();
insert into _t values ('sweep2', pg_temp.try('select public.guide_sweep_v1()'));
reset role;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('g_after_sweep', pg_temp.try('select public.staff_guide_guests_v1(30)'));
reset role;
select ok((select (v ->> 'sessions')::int = 1 from _t where k = 'sweep2') and (select count(*) = 1 from public.guide_sessions where token_hash = lpad(to_hex(2001), 64, '0'))
      and (select count(*) = 0 from public.guide_sessions where token_hash = lpad(to_hex(2002), 64, '0')),
  's136 sweep: a session expired 10 days ago survives the sweep; one expired 100 days ago is swept');
select ok((select (select g ->> 'guest_label' = 'Zzkept' and (g ->> 'first_seen')::timestamptz = now() - interval '12 days' and (g ->> 'checkout_date')::date = pg_temp.today() - 12
                     from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' = pg_temp.id('c1')::text)
        and not exists (select 1 from jsonb_array_elements(v -> 'guests') g where g ->> 'thread_id' = pg_temp.id('c3')::text) from _t where k = 'g_after_sweep'),
  's136 sweep: after the sweep staff_guide_guests_v1(30) still lists the guest who checked out 12 days ago, with the first sign-in time');
select ok(public.guide_token_thread_v1(null) is null and (select public.guide_token_thread_v1('zz-not-a-real-token-0123456789abcdef0123')) is null, 's136 token: the helper refuses a null and an unknown token');
insert into public.guide_sessions(token_hash, thread_id, expires_at) values (encode(extensions.digest('zz136-kept-expired-token-0123456789abc', 'sha256'), 'hex'), pg_temp.id('c1'), now() - interval '10 days');
select ok(public.guide_token_thread_v1('zz136-kept-expired-token-0123456789abc') is null, 's136 token: a session row expired 10 days ago (kept by the sweep) still resolves to no thread');

-- 15g. lock_timeout: a function-level setting of 2 s (PostgreSQL restores the caller's value on every exit); lock_not_available anywhere in the call answers busy
--      and keeps nothing. verify_booking is still the section 14 stub (any initial matches); the stay of house b2 on today + 3 exists in calendar_events.
select ok((select p.proconfig @> array['lock_timeout=2s'] from pg_proc p where p.oid = 'public.guide_session_v1(date,text,text,uuid)'::regprocedure),
  's136 lock: guide_session_v1 carries lock_timeout = 2s as a function setting');
select set_config('lock_timeout', '7s', true);
select set_config('request.headers', '{}', true);
select pg_temp.as_anon();
insert into _t values ('lto', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 3, 'Z', 'zz136-lto', pg_temp.id('b2'))));
reset role;
select ok(current_setting('lock_timeout') = '7s' and (select v ->> 'ok' = 'true' and v ->> 'token' ~ '^[a-f0-9]{64}$' from _t where k = 'lto'),
  's136 lock: after a successful guide_session_v1 call the caller''s own lock_timeout (7s) is unchanged');
create or replace function public.verify_booking(p_checkin_date date, p_initial text default null::text, p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb language plpgsql as $$ begin raise exception using errcode = '55P03', message = 'zz136 synthetic lock timeout'; end $$;
create temp table _cnt2 as select (select count(*) from public.guide_auth_attempts) attempts, (select count(*) from public.guide_sessions) sessions, (select count(*) from public.guide_threads) threads;
select pg_temp.as_anon();
insert into _t values ('lbusy', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today() + 3, 'Z', 'zz136-lbusy', pg_temp.id('b2'))));
reset role;
select ok((select v = '{"ok": false, "reason": "busy"}'::jsonb from _t where k = 'lbusy') and current_setting('lock_timeout') = '7s'
      and (select (select count(*) from public.guide_auth_attempts) = c.attempts and (select count(*) from public.guide_sessions) = c.sessions and (select count(*) from public.guide_threads) = c.threads from _cnt2 c),
  's136 lock: a lock timeout (55P03) inside guide_session_v1 answers exactly {ok false, reason busy}, keeps no attempt, thread or session, and leaves the caller''s lock_timeout alone');
select set_config('lock_timeout', '0', true);

-- 15h. the push trigger ENABLED and fired by a service_role insert, with net.http_post and the vault secret stubbed (a rehearsal copy has neither; a stub also means no
--      real request can be queued; everything is rolled back with the suite). Production service_role has BYPASSRLS; the rehearsal role is created without it.
do $$
begin
  if to_regnamespace('net') is null then create schema net; end if;
  if to_regnamespace('vault') is null then create schema vault; end if;
  if to_regclass('vault.decrypted_secrets') is null then
    create table vault.decrypted_secrets(name text, decrypted_secret text);
    insert into vault.decrypted_secrets values ('cascade_cron_shared_secret', 'ZZ136-SYNTHETIC-ONLY');
  end if;
  if not (select rolbypassrls from pg_roles where rolname = 'service_role') then alter role service_role bypassrls; end if;
end $$;
create table net._zz136_calls(url text, body jsonb, has_secret boolean);
create or replace function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb, headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
returns bigint language plpgsql as $f$ begin insert into net._zz136_calls values (url, body, headers ? 'x-cascade-cron-secret'); return 1; end $f$;
alter table public.guide_messages enable trigger guide_messages_push;
select pg_temp.as_service();
insert into _t values ('trg_guest', pg_temp.try(format($q$insert into public.guide_messages(thread_id, sender, body, client_msg_id) values (%L, 'guest', 'trigger test', 'zz136-trg-0001') returning to_jsonb(1)$q$, pg_temp.id('c1'))));
insert into _t values ('trg_staff', pg_temp.try(format($q$insert into public.guide_messages(thread_id, sender, body, client_msg_id) values (%L, 'staff', 'trigger test', 'zz136-trg-0002') returning to_jsonb(1)$q$, pg_temp.id('c1'))));
reset role;
select ok((select v = '1'::jsonb from _t where k = 'trg_guest') and (select v = '1'::jsonb from _t where k = 'trg_staff') and (select count(*) = 2 from public.guide_messages where client_msg_id like 'zz136-trg-%')
      and (select tgenabled = 'O' from pg_trigger where tgname = 'guide_messages_push' and not tgisinternal)
      and not has_function_privilege('service_role', 'public.guide_messages_push_trg()', 'execute'),
  's136 trigger: with the push trigger enabled and service_role holding no execute on its function, service_role inserts into guide_messages (guest and staff) succeed');
select ok((select count(*) = 1 and bool_and(c.body = jsonb_build_object('kind', 'guest_wrote', 'psid', 'guide:' || pg_temp.id('c1')::text) and c.url like '%/functions/v1/notify-staff-inbox' and c.has_secret) from net._zz136_calls c),
  's136 trigger: the guest message queued exactly one net.http_post (kind guest_wrote, psid guide:<thread id>, the cron secret header); the staff message queued none');
create or replace function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb, headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
returns bigint language plpgsql as $f$ begin raise exception 'zz136 synthetic pg_net failure'; end $f$;
select pg_temp.as_service();
insert into _t values ('trg_fail', pg_temp.try(format($q$insert into public.guide_messages(thread_id, sender, body, client_msg_id) values (%L, 'guest', 'trigger test', 'zz136-trg-0003') returning to_jsonb(1)$q$, pg_temp.id('c1'))));
reset role;
select ok((select v = '1'::jsonb from _t where k = 'trg_fail') and (select count(*) = 1 from public.guide_messages where client_msg_id = 'zz136-trg-0003'),
  's136 trigger: when net.http_post raises, the guest message is still stored (the trigger only warns)');

select * from finish();
rollback;
