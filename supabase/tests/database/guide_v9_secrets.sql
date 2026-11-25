-- Session 137: release guide_v9_secrets_20261207 (guest guide v9): guide_secrets_v1 (stay secrets against a live guest or staff token), guide_staff_session_v1 (staff PIN -> 12 h token,
-- table guide_staff_sessions capped at 50 rows), get_public_settings (ten whitelisted keys) and the weather-proxy-warm cron job. Built on the guide v8 session system (guide_sessions).
-- Synthetic fixtures only (uuids e1370000-..., names "Zz S137 ..."); everything rolls back. app_settings test values and the admin PIN hash are set INSIDE the transaction.
-- Fixture rows and direct reads run as the owner role (a --no-acl restore gives anon and authenticated no table grants); only the RPC calls run as anon / authenticated / service_role.
-- Needs guide v8 applied first (the rehearsal contract stacks it). Run: CASCADE_REHEARSAL_PRE_SQL=supabase/releases/support/s136_pre_grants.sql scripts/recovery/p6/migration-rehearsal-on-host.sh <backup-set> <contract> supabase/tests/database/guide_v9_secrets.sql
begin;
select plan(47);

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
grant execute on function pg_temp.as_user(uuid) to public;
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
create function pg_temp.id(p text) returns uuid language sql immutable as $$ select ('e1370000-0000-4000-8000-0000000000' || p)::uuid $$;
grant execute on function pg_temp.id(text) to public;
create function pg_temp.today() returns date language sql stable as $$ select (now() at time zone 'Asia/Manila')::date $$;
grant execute on function pg_temp.today() to public;
create function pg_temp.hdr(p_ip text) returns void language sql as $$ select set_config('request.headers', json_build_object('cf-connecting-ip', p_ip)::text, true) $$;
grant execute on function pg_temp.hdr(text) to public;
-- a guest token in the shape guide_token_thread_v1 accepts
create function pg_temp.tok() returns text language sql stable as $$ select v ->> 'token' from _t where k = 'mint' $$;
grant execute on function pg_temp.tok() to public;
create function pg_temp.stok() returns text language sql stable as $$ select v ->> 'token' from _t where k = 'staff' $$;
grant execute on function pg_temp.stok() to public;
-- the same four keys every time
create function pg_temp.secrets(p text) returns jsonb language plpgsql as $f$
begin return public.guide_secrets_v1(p); end $f$;
grant execute on function pg_temp.secrets(text) to public;

-- =============================================================================================================================================
-- Fixtures. Test values for the settings (the rehearsal copy holds real ones: they are overwritten inside this transaction and rolled back).
-- The admin PIN is "zzpin137" (verify_admin_pin lowercases and trims its input before the bcrypt compare).
-- =============================================================================================================================================
insert into public.properties(id, name, is_active) values (pg_temp.id('b1'), 'Zz S137 House', true);
insert into public.calendar_events(property_id, uid, source, checkin_date, checkout_date, guest_name, status, raw_summary) values
  (pg_temp.id('b1'), 'zz137-now', 'airbnb', pg_temp.today(), pg_temp.today() + 2, 'Zz Tester', 'confirmed', 'Reserved');
insert into public.app_settings(key, value) values
  ('wifi_ssid', '"Zz137-Net"'), ('wifi_password', '"zz137-wifi-pass"'), ('onground_name', '"Zz Caretaker"'), ('onground_phone', '"+630000137"'),
  ('house_times', '{"checkin": "14:00", "checkout": "11:00"}'), ('min_nights', '2'), ('max_nights', '30'),
  ('review_airbnb_url', '"https://example.test/a"'), ('review_facebook_url', '"https://example.test/f"'), ('review_google_url', '"https://example.test/g"'),
  ('property_lat', '6.1545'), ('property_lng', '125.1852'), ('concierge_mode', '"auto"'), ('zz137_extra', '"not public"'),
  ('admin_pin_hash', to_jsonb(extensions.crypt('zzpin137', extensions.gen_salt('bf', 4))))
on conflict (key) do update set value = excluded.value;
insert into _t values ('rows0', jsonb_build_object('att', (select count(*) from public.admin_auth_attempts), 'gs', (select count(*) from public.guide_sessions)));

-- a guest token the REAL way (guide v8 guide_session_v1, the same call the guide makes)
select pg_temp.as_anon();
insert into _t values ('mint', pg_temp.try(format('select public.guide_session_v1(%L::date, %L, %L, %L::uuid)', pg_temp.today(), 'T', 'zz137-b', pg_temp.id('b1'))));
reset role;

-- =============================================================================================================================================
-- 1. Shape: table, RLS, grants, functions
-- =============================================================================================================================================
select ok((select c.relrowsecurity from pg_class c where c.oid = to_regclass('public.guide_staff_sessions')), 'table: guide_staff_sessions exists with RLS on');
select ok(not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'guide_staff_sessions'), 'table: no policy is defined (only the definer functions touch it)');
select ok(not exists (select 1 from unnest(array['anon', 'authenticated', 'service_role']) r, unnest(array['select', 'insert', 'update', 'delete', 'truncate', 'references', 'trigger']) p
                       where has_table_privilege(r, 'public.guide_staff_sessions', p)),
  'table: no privilege of any kind for anon, authenticated or service_role (PUBLIC is revoked too: anon would inherit it)');
select ok((select bool_and(has_function_privilege('anon', f, 'execute') and has_function_privilege('authenticated', f, 'execute')) from unnest(array['public.guide_staff_session_v1(text,text)', 'public.guide_secrets_v1(text)', 'public.get_public_settings()']::regprocedure[]) f),
  'grants: anon and authenticated may execute all three new functions');
select ok((select not bool_or(has_function_privilege('service_role', f, 'execute')) from unnest(array['public.guide_staff_session_v1(text,text)', 'public.guide_secrets_v1(text)', 'public.get_public_settings()']::regprocedure[]) f),
  'grants: service_role may execute none of them (revoked by name, not left to the default privilege)');
select ok(not exists (select 1 from unnest(array['public.guide_staff_session_v1(text,text)', 'public.guide_secrets_v1(text)', 'public.get_public_settings()']::regprocedure[]) f
                        join pg_proc p on p.oid = f cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0),
  'grants: PUBLIC has no execute on any of them');
select ok((select count(*) = 3 and bool_and(p.prosecdef and p.proconfig @> array['search_path=""']) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('guide_staff_session_v1', 'guide_secrets_v1', 'get_public_settings')),
  'functions: all three are SECURITY DEFINER with search_path "" (asserted with the literal quotes)');
select ok((select p.proconfig @> array['lock_timeout=2s'] and p.provolatile = 'v' from pg_proc p where p.oid = 'public.guide_staff_session_v1(text,text)'::regprocedure)
      and (select p.provolatile = 's' from pg_proc p where p.oid = 'public.guide_secrets_v1(text)'::regprocedure)
      and (select p.provolatile = 's' from pg_proc p where p.oid = 'public.get_public_settings()'::regprocedure),
  'functions: the mint carries lock_timeout 2s and is volatile; the secrets read and the settings read are STABLE (no write path)');

-- =============================================================================================================================================
-- 2. guide_secrets_v1: refusals
-- =============================================================================================================================================
select pg_temp.as_anon();
select ok(public.guide_secrets_v1(null) = '{"ok": false}'::jsonb, 'secrets: a null token answers {"ok":false}');
select ok(public.guide_secrets_v1('') = '{"ok": false}'::jsonb and public.guide_secrets_v1('short-token') = '{"ok": false}'::jsonb and public.guide_secrets_v1(repeat('x', 129)) = '{"ok": false}'::jsonb,
  'secrets: empty, too short (11) and too long (129) tokens answer {"ok":false}');
select ok(public.guide_secrets_v1(repeat('0', 64)) = '{"ok": false}'::jsonb and public.guide_secrets_v1('''; drop table public.app_settings; --0123456789abcdef') = '{"ok": false}'::jsonb
      and public.guide_secrets_v1(repeat('Zz', 32)) = '{"ok": false}'::jsonb,
  'secrets: a well-formed but unknown token, an injection-shaped string and a non-hex string answer {"ok":false}');
select ok(public.guide_secrets_v1(pg_temp.tok() || 'x') = '{"ok": false}'::jsonb and public.guide_secrets_v1(substr(pg_temp.tok(), 2)) = '{"ok": false}'::jsonb
      and public.guide_secrets_v1(upper(pg_temp.tok())) = '{"ok": false}'::jsonb,
  'secrets: a live guest token with a character added, one removed, or its case changed answers {"ok":false}');
reset role;

-- =============================================================================================================================================
-- 3. guide_secrets_v1: a live guest token (minted by guide_session_v1)
-- =============================================================================================================================================
select ok((select v ->> 'ok' = 'true' and length(v ->> 'token') = 64 from _t where k = 'mint'), 'guest: the fixture token was minted by the real guide_session_v1 (ok, 64 hex characters)');
select pg_temp.as_anon();
insert into _t values ('g1', pg_temp.try(format('select public.guide_secrets_v1(%L)', pg_temp.tok())));
reset role;
select is((select v from _t where k = 'g1'),
  '{"ok": true, "kind": "guest", "wifi_ssid": "Zz137-Net", "wifi_password": "zz137-wifi-pass", "onground_name": "Zz Caretaker", "onground_phone": "+630000137"}'::jsonb,
  'guest: a live guest token gets exactly ok, kind guest and the four stay values (hand-written expected object)');
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('g2', pg_temp.try(format('select public.guide_secrets_v1(%L)', pg_temp.tok())));
reset role;
select ok((select v = (select v from _t where k = 'g1') from _t where k = 'g2'), 'guest: authenticated callers get the same answer as anon');
-- unknown is null, never an empty string or a made-up value
delete from public.app_settings where key = 'onground_name';
select pg_temp.as_anon();
insert into _t values ('g3', pg_temp.try(format('select public.guide_secrets_v1(%L)', pg_temp.tok())));
reset role;
select ok((select v ->> 'ok' = 'true' and jsonb_typeof(v -> 'onground_name') = 'null' and v ->> 'wifi_password' = 'zz137-wifi-pass' and (select count(*) from jsonb_object_keys(v)) = 6 from _t where k = 'g3'),
  'guest: a missing setting is JSON null (key still present), the other values are unchanged');
insert into public.app_settings(key, value) values ('onground_name', '"Zz Caretaker"') on conflict (key) do update set value = excluded.value;
-- expiry
update public.guide_sessions set expires_at = now() - interval '1 second' where token_hash = encode(extensions.digest(pg_temp.tok(), 'sha256'), 'hex');
select pg_temp.as_anon();
select ok(public.guide_secrets_v1(pg_temp.tok()) = '{"ok": false}'::jsonb, 'guest: the same token one second after its expires_at answers {"ok":false}');
reset role;
update public.guide_sessions set expires_at = now() + interval '1 hour' where token_hash = encode(extensions.digest(pg_temp.tok(), 'sha256'), 'hex');
-- read path writes nothing
select ok((select (v ->> 'att')::int = (select count(*) from public.admin_auth_attempts) and (v ->> 'gs')::int + 1 = (select count(*) from public.guide_sessions)
                   and (select count(*) from public.guide_staff_sessions) = 0 from _t where k = 'rows0'),
  'guest: guide_secrets_v1 wrote no row (attempts unchanged, only the one minted session, no staff session)');

-- =============================================================================================================================================
-- 4. guide_staff_session_v1: wrong codes
-- =============================================================================================================================================
select pg_temp.hdr('203.0.113.10');
select pg_temp.as_anon();
insert into _t values ('w1', pg_temp.try($q$select public.guide_staff_session_v1('wrong-code', 'zz137-c1')$q$));
insert into _t values ('w2', pg_temp.try($q$select public.guide_staff_session_v1('', 'zz137-c1')$q$));
insert into _t values ('w3', pg_temp.try($q$select public.guide_staff_session_v1(null, 'zz137-c1')$q$));
reset role;
select ok((select v = '{"ok": false}'::jsonb from _t where k = 'w1') and (select v = '{"ok": false}'::jsonb from _t where k = 'w2') and (select v = '{"ok": false}'::jsonb from _t where k = 'w3'),
  'staff: a wrong, an empty and a null code return verify_admin_pin''s answer unchanged ({"ok":false}), no token, no reason');
select ok((select count(*) = 0 from public.guide_staff_sessions), 'staff: wrong codes created no staff session row');
select ok((select count(*) = 3 from public.admin_auth_attempts where ip_hash = encode(extensions.digest('ip:203.0.113.10|cascade-guide', 'sha256'), 'hex') and not succeeded),
  'staff: the three failures are recorded by verify_admin_pin under the hash of the header address (ip:203.0.113.10), not of the client string');
-- rotating p_client does not reset the throttle: the key is the header address
select pg_temp.as_anon();
select public.guide_staff_session_v1('wrong-' || g, 'zz137-rot-' || g) from generate_series(1, 5) g;
insert into _t values ('t8', pg_temp.try($q$select public.guide_staff_session_v1('zzpin137', 'zz137-brand-new-client')$q$));
reset role;
select is((select v from _t where k = 't8'), '{"ok": false, "throttled": true}'::jsonb,
  'staff: after 8 wrong codes from one address (3 + 5, each with a different p_client) even the right code is throttled, unchanged, no token');
select ok((select count(*) = 0 from public.guide_staff_sessions), 'staff: a throttled attempt created no session');
select pg_temp.hdr('203.0.113.11');
select pg_temp.as_anon();
insert into _t values ('other_ip', pg_temp.try($q$select public.guide_staff_session_v1('zzpin137', 'zz137-c1')$q$));
reset role;
select ok((select v ->> 'ok' = 'true' and length(v ->> 'token') = 64 from _t where k = 'other_ip'), 'staff: another address is not throttled by the first one (right code, token of 64 hex characters)');
delete from public.guide_staff_sessions;

-- =============================================================================================================================================
-- 5. guide_staff_session_v1: right code
-- =============================================================================================================================================
select pg_temp.hdr('203.0.113.12');
select pg_temp.as_anon();
insert into _t values ('staff', pg_temp.try($q$select public.guide_staff_session_v1('  ZZPIN137 ', 'zz137-c2')$q$));
reset role;
select ok((select v ->> 'ok' = 'true' and v ->> 'token' ~ '^[a-f0-9]{64}$' and v ? 'users' and v ? 'expires_at' and not (v ? 'reason') from _t where k = 'staff'),
  'staff: the right code (case and spaces as verify_admin_pin allows) returns verify_admin_pin''s ok and users plus token and expires_at, no reason');
select ok((select count(*) = 1 and bool_and(token_hash = encode(extensions.digest((select v ->> 'token' from _t where k = 'staff'), 'sha256'), 'hex')) and bool_and(token_hash <> (select v ->> 'token' from _t where k = 'staff'))
                    from public.guide_staff_sessions),
  'staff: exactly one row, holding the sha256 of the token and never the token itself');
select ok((select s.expires_at between now() + interval '11 hours 59 minutes' and now() + interval '12 hours 1 minute'
                   and (v ->> 'expires_at')::timestamptz = s.expires_at from public.guide_staff_sessions s, _t where k = 'staff'),
  'staff: the token lives 12 hours (stored expires_at equals the one returned)');
select pg_temp.as_anon();
insert into _t values ('s1', pg_temp.try(format('select public.guide_secrets_v1(%L)', pg_temp.stok())));
reset role;
select is((select v from _t where k = 's1'),
  '{"ok": true, "kind": "staff", "wifi_ssid": "Zz137-Net", "wifi_password": "zz137-wifi-pass", "onground_name": "Zz Caretaker", "onground_phone": "+630000137"}'::jsonb,
  'staff: the staff token gets kind staff and the same four stay values');
select ok((select v ->> 'users' is distinct from 'null' from _t where k = 'staff') and (select v -> 'users' = coalesce((select value from public.app_settings where key = 'users'), '[]'::jsonb) from _t where k = 'staff'),
  'staff: the users value is carried over unchanged from verify_admin_pin (no change of its contract)');
update public.guide_staff_sessions set expires_at = now() - interval '1 second';
select pg_temp.as_anon();
select ok(public.guide_secrets_v1(pg_temp.stok()) = '{"ok": false}'::jsonb, 'staff: the same token one second after its expires_at answers {"ok":false}');
reset role;
select ok(public.guide_secrets_v1(pg_temp.stok()) = '{"ok": false}'::jsonb and (select count(*) from public.guide_sessions where token_hash = encode(extensions.digest(pg_temp.stok(), 'sha256'), 'hex')) = 0,
  'staff: an expired staff token stays refused and was never a guest session');
-- a staff token is not a guest token and the other way round: each kind is looked up only in its own table
select ok((select count(*) = 0 from public.guide_staff_sessions where token_hash = encode(extensions.digest(pg_temp.tok(), 'sha256'), 'hex')), 'staff: a guest token is not in the staff table (kinds do not cross)');

-- =============================================================================================================================================
-- 6. the bound: 50 live rows, expired rows deleted on each mint, busy above
-- =============================================================================================================================================
delete from public.guide_staff_sessions;
insert into public.guide_staff_sessions(token_hash, expires_at)
  select encode(extensions.digest('zz137-expired-' || g, 'sha256'), 'hex'), now() - interval '1 minute' * g from generate_series(1, 30) g;
insert into public.guide_staff_sessions(token_hash, expires_at)
  select encode(extensions.digest('zz137-live-' || g, 'sha256'), 'hex'), now() + interval '1 hour' from generate_series(1, 49) g;
select pg_temp.hdr('203.0.113.13');
select pg_temp.as_anon();
insert into _t values ('m50', pg_temp.try($q$select public.guide_staff_session_v1('zzpin137', 'zz137-c3')$q$));
reset role;
select ok((select v ->> 'ok' = 'true' and length(v ->> 'token') = 64 from _t where k = 'm50'), 'bound: with 49 live and 30 expired rows a mint succeeds (the 50th live row)');
select ok((select count(*) = 50 and count(*) filter (where expires_at <= now()) = 0 from public.guide_staff_sessions), 'bound: the 30 expired rows were deleted by the mint: 50 rows, all live');
select pg_temp.hdr('203.0.113.14');
select pg_temp.as_anon();
insert into _t values ('busy', pg_temp.try($q$select public.guide_staff_session_v1('zzpin137', 'zz137-c4')$q$));
reset role;
select ok((select v ->> 'ok' = 'true' and v ->> 'reason' = 'busy' and not (v ? 'token') and not (v ? 'expires_at') from _t where k = 'busy'),
  'bound: with 50 live rows a right code gets reason busy and no token (verify_admin_pin''s ok and users kept)');
select ok((select count(*) = 50 from public.guide_staff_sessions), 'bound: the busy answer added no row (still exactly 50)');
select pg_temp.hdr('203.0.113.15');
select pg_temp.as_anon();
insert into _t values ('busy_wrong', pg_temp.try($q$select public.guide_staff_session_v1('wrong', 'zz137-c5')$q$));
reset role;
select ok((select v = '{"ok": false}'::jsonb from _t where k = 'busy_wrong') and (select count(*) = 50 from public.guide_staff_sessions), 'bound: a wrong code at the cap is still plain {"ok":false} and adds nothing');
update public.guide_staff_sessions set expires_at = now() - interval '1 second' where token_hash = encode(extensions.digest('zz137-live-1', 'sha256'), 'hex');
select pg_temp.hdr('203.0.113.16');
select pg_temp.as_anon();
insert into _t values ('free1', pg_temp.try($q$select public.guide_staff_session_v1('zzpin137', 'zz137-c6')$q$));
reset role;
select ok((select v ->> 'ok' = 'true' and length(v ->> 'token') = 64 and not (v ? 'reason') from _t where k = 'free1') and (select count(*) = 50 from public.guide_staff_sessions),
  'bound: when one session expires the next mint succeeds again and the table is back at exactly 50');
-- the busy-then-success table never exceeds 50 even through repeated mints
select pg_temp.hdr('203.0.113.17');
select pg_temp.as_anon();
select public.guide_staff_session_v1('zzpin137', 'zz137-loop-' || g) from generate_series(1, 5) g;
reset role;
select ok((select count(*) = 50 from public.guide_staff_sessions), 'bound: five more mints at the cap leave the table at exactly 50');
delete from public.guide_staff_sessions;

-- =============================================================================================================================================
-- 7. nobody reads the tables directly
-- =============================================================================================================================================
insert into public.guide_staff_sessions(token_hash, expires_at) values (encode(extensions.digest('zz137-direct', 'sha256'), 'hex'), now() + interval '1 hour');
select pg_temp.as_anon();
insert into _t values ('rd_anon', pg_temp.try('select to_jsonb(count(*)) from public.guide_staff_sessions'));
insert into _t values ('rd_anon_gs', pg_temp.try('select to_jsonb(count(*)) from public.guide_sessions'));
insert into _t values ('wr_anon', pg_temp.try($q$with i as (insert into public.guide_staff_sessions(token_hash, expires_at) values (repeat('a', 64), now() + interval '1 day') returning 1) select to_jsonb(count(*)) from i$q$));
reset role;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('rd_auth', pg_temp.try('select to_jsonb(count(*)) from public.guide_staff_sessions'));
reset role;
select pg_temp.as_service();
insert into _t values ('rd_svc', pg_temp.try('select to_jsonb(count(*)) from public.guide_staff_sessions'));
reset role;
select ok((select v ->> 'err' = '42501' from _t where k = 'rd_anon') and (select v ->> 'err' = '42501' from _t where k = 'rd_anon_gs') and (select v ->> 'err' = '42501' from _t where k = 'wr_anon'),
  'tables: anon gets permission denied (42501) reading guide_staff_sessions and guide_sessions and writing guide_staff_sessions');
select ok((select v ->> 'err' = '42501' from _t where k = 'rd_auth') and (select v ->> 'err' = '42501' from _t where k = 'rd_svc'), 'tables: authenticated and service_role get permission denied (42501) reading guide_staff_sessions');
delete from public.guide_staff_sessions;

-- =============================================================================================================================================
-- 8. get_public_settings
-- =============================================================================================================================================
select pg_temp.as_anon();
insert into _t values ('ps_anon', pg_temp.try('select public.get_public_settings()'));
reset role;
select pg_temp.as_user(pg_temp.id('01'));
insert into _t values ('ps_auth', pg_temp.try('select public.get_public_settings()'));
reset role;
select is((select array_agg(k order by k) from jsonb_object_keys((select v from _t where k = 'ps_anon')) k),
  array['concierge_mode', 'house_times', 'max_nights', 'min_nights', 'property_lat', 'property_lng', 'review_airbnb_url', 'review_facebook_url', 'review_google_url', 'wifi_ssid'],
  'settings: exactly the ten whitelisted keys come back (hand-written list), nothing else');
select ok(not ((select v from _t where k = 'ps_anon') ?| array['wifi_password', 'admin_pin_hash', 'onground_name', 'onground_phone', 'users', 'zz137_extra']),
  'settings: wifi_password, admin_pin_hash, onground_name, onground_phone, users and a non-listed test key are absent');
select ok((select v ->> 'wifi_ssid' = 'Zz137-Net' and v -> 'house_times' = '{"checkin": "14:00", "checkout": "11:00"}'::jsonb and v -> 'min_nights' = '2'::jsonb and v -> 'max_nights' = '30'::jsonb
                   and v -> 'property_lat' = '6.1545'::jsonb and v ->> 'concierge_mode' = 'auto' and v ->> 'review_google_url' = 'https://example.test/g' from _t where k = 'ps_anon'),
  'settings: values keep their stored types (object, numbers, strings) and the test values');
select ok((select v = (select v from _t where k = 'ps_anon') from _t where k = 'ps_auth'), 'settings: authenticated callers get the same answer as anon');
-- a missing key is absent, not null or zero
delete from public.app_settings where key = 'min_nights';
select pg_temp.as_anon();
insert into _t values ('ps_miss', pg_temp.try('select public.get_public_settings()'));
reset role;
select ok((select not (v ? 'min_nights') and (select count(*) from jsonb_object_keys(v)) = 9 from _t where k = 'ps_miss'), 'settings: a missing whitelisted key is left out (nine keys), never null or 0');

-- =============================================================================================================================================
-- 9. the weather-proxy warm-up job (where pg_cron exists)
-- =============================================================================================================================================
select ok(to_regclass('cron.job') is null or (xpath('/row/c/text()', query_to_xml($q$select count(*) as c from cron.job where jobname = 'weather-proxy-warm' and schedule = '*/10 * * * *'
                       and command like '%/functions/v1/weather-proxy%' and command like '%net.http_get%'$q$, false, true, '')))[1]::text::int = 1,
  'cron: weather-proxy-warm is scheduled every 10 minutes and calls net.http_get on the weather-proxy URL, once (skipped where pg_cron is absent)');

select * from finish();
rollback;
