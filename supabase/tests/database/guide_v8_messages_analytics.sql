-- Session 135: release guide_v8_messages_analytics_20261206 (guest guide v8.0.0 backend): five guide_* tables (RLS, no grants), four anon guest RPCs (guide_session_v1, guide_thread_v1, guide_send_v1, guide_track_v1),
-- five staff RPCs (manage_guest_inbox gate), the push trigger and guide_sweep_v1. Synthetic fixtures only (uuids e1350000-..., names "Zz S135 ..."); everything rolls back.
-- Fixture rows and the reads run as the owner role (a --no-acl restore gives authenticated and anon no table grants); only the RPC calls run as anon / authenticated / service_role.
-- The push trigger is disabled inside this suite (rolled back with it) so a rehearsal copy can never queue an HTTP call to the production notify-staff-inbox function.
-- Run: scripts/recovery/p6/migration-rehearsal-on-host.sh <backup-set> supabase/releases/20261206_guide_v8.release.json supabase/tests/database/guide_v8_messages_analytics.sql
begin;
select plan(82);

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
insert into _t values ('ow_usage', pg_temp.try(format('select public.staff_guide_usage_v1(30, %L::uuid)', pg_temp.id('b1'))));
reset role;
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
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('us3', pg_temp.try(format('select public.staff_guide_usage_v1(3, %L::uuid)', pg_temp.id('b1'))));
insert into _t values ('us1', pg_temp.try(format('select public.staff_guide_usage_v1(1, %L::uuid)', pg_temp.id('b1'))));
insert into _t values ('us30', pg_temp.try(format('select public.staff_guide_usage_v1(30, %L::uuid)', pg_temp.id('b1'))));
reset role;
select ok((select (v ->> 'since')::date = pg_temp.today() - 2 from _t where k = 'us3') and (select (v ->> 'since')::date = pg_temp.today() from _t where k = 'us1'), 'usage window: since is the Manila date of the first plotted day (today minus p_days plus 1), today for one day');
select ok((select (v ->> 'devices')::int = 4 from _t where k = 'us3') and (select (v ->> 'devices')::int = 4 from _t where k = 'us30'), 'usage window: an event one minute after Manila midnight of the first day is counted, one minute before it is not in a 3-day window (3 original devices + dev71)');
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
insert into public.guide_events(at, device, name) values (now() - interval '200 days', 'zz135dev99', 'guide_open');
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
select ok((select (v ->> 'events')::int = 1 and (v ->> 'sessions')::int = 1 and (v ->> 'attempts')::int = 1 from _t where k = 'sweep'), 'sweep: service_role removes the 200-day event, the expired session and the 3-day-old attempt, one of each');
select ok((select count(*) = 0 from public.guide_events where device = 'zz135dev99') and (select count(*) = 5 from public.guide_events) and (select count(*) = 3 from public.guide_sessions), 'sweep: recent events and live sessions are left alone');
select ok((select v ->> 'ok' = 'true' and jsonb_array_length(v -> 'messages') = 3 from _t where k = 'read_after'), 'sweep: the live guest token still reads its three messages');

select * from finish();
rollback;
