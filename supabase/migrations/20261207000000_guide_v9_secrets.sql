-- 20261207000000_guide_v9_secrets.sql
-- Guest guide v9: stay secrets (Wi-Fi password, on-ground contact) are handed out only against a live token, plus a public-safe settings
-- whitelist and a warm-up for the weather function. NOT APPLIED. Ships through the stay-site release flow (release contract
-- supabase/releases/20261207_guide_v9_secrets.release.json, rehearsal with pgTAP on a restored copy, the orchestrator runs the apply).
-- Rollback: supabase/rollbacks/20261207_guide_v9_secrets.sql. Checks: supabase/sql/2026-12-07-guide-v9-verify.sql.
--
-- Design rules
--  * Built ON the guest session system of guide v8 (20261206000000): a guest token is the one guide_session_v1 mints (guide_sessions, sha256 only).
--    No second guest token or throttle table is created. The token check is the existing helper guide_token_thread_v1.
--  * Additive: the guide v8 functions are CALLED, never replaced. app_settings is read, never written. verify_admin_pin is replaced by the SECOND migration of this
--    release (20261207000100_verify_admin_pin_bound.sql), which keys its throttle on the request address and bounds admin_auth_attempts; this file only calls it.
--  * guide_secrets_v1(token): no table write. It is declared VOLATILE on purpose: PostgREST serves a STABLE function on GET, which would let a token travel in a URL;
--    a VOLATILE one is POST only. {"ok":false} for a missing, malformed, unknown or expired token (one answer, no reason, so a caller cannot tell a wrong token from an
--    expired one). A live guest token or a live staff token gets the four stay values.
--  * guide_staff_session_v1(code, client): the staff PIN of the existing admin login (verify_admin_pin, 8 failures / 15 min per request address) becomes a
--    12 hour token, so the guide can show the same secrets to staff without a booking. Only the sha256 of the token is stored.
--    - The caller's p_client is passed straight through to verify_admin_pin; the address key, the empty-code rule, the trim and the global cap live there (second migration).
--    - A staff token dies when the staff code changes: each row stores md5(admin_pin_hash setting) as pin_fp at mint (a fingerprint, never the hash), and guide_secrets_v1
--      accepts a staff token only while its pin_fp equals the current one. The mint also deletes rows with a stale pin_fp, so they do not occupy the cap.
--    - STORAGE BOUND: public.guide_staff_sessions never holds more than 50 rows. Rows are added only by a successful mint, which first deletes every
--      expired or stale row and refuses (reason 'busy', no token) when 50 live rows remain; the count and the insert run under one advisory lock, so the cap is
--      exact. 50 rows of 64 + 32 + 8 + 8 bytes plus the key index are a few kilobytes. 50 live staff sessions is far above the real use (a handful of staff
--      phones, 12 hours each) and low enough that a stolen PIN cannot fill the table.
--    - admin_auth_attempts (written by verify_admin_pin on each mint attempt) is bounded by the second migration: at most 401 rows per 15 minutes, 38,496 a day, about 10 MB.
--  * get_public_settings(): a fixed whitelist of ten app_settings keys that carry nothing secret. No secret and no admin key is ever returned.
--  * weather-proxy warm-up: a pg_cron job every 10 minutes asks the function for the Cascade forecast, so a guest does not wait for a cold start.
--    Arithmetic is in docs/s137/GUIDE-V9-SECRETS.md (the function caches 15 minutes: a 10 minute call refreshes every second call, 72 refreshes a day; at most 96 with guest traffic).
-- ML-21: every function restates its grants in full below. Supabase default privileges grant EXECUTE to anon, so each is revoked from
-- public, anon, authenticated and service_role by name before the intended roles are granted.

-- 0. guards -------------------------------------------------------------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.guide_token_thread_v1(text)') is null then
    raise exception 'guide v9: public.guide_token_thread_v1(text) missing (guide v8 not applied)' using errcode = '55000'; end if;
  if to_regclass('public.guide_sessions') is null then
    raise exception 'guide v9: public.guide_sessions missing (guide v8 not applied)' using errcode = '55000'; end if;
  if to_regprocedure('public.verify_admin_pin(text,text)') is null then
    raise exception 'guide v9: public.verify_admin_pin(text,text) missing' using errcode = '55000'; end if;
  if to_regclass('public.app_settings') is null then
    raise exception 'guide v9: public.app_settings missing' using errcode = '55000'; end if;
  if to_regclass('public.guide_staff_sessions') is not null then
    raise exception 'guide v9: already applied (public.guide_staff_sessions exists)' using errcode = '55000'; end if;
end $$;

-- 1. table --------------------------------------------------------------------------------------------------------------------------------
create table public.guide_staff_sessions (
  token_hash  text primary key check (token_hash ~ '^[a-f0-9]{64}$'),
  expires_at  timestamptz not null,
  pin_fp      text not null check (pin_fp ~ '^[a-f0-9]{32}$'),   -- md5 of the admin_pin_hash setting at mint: a changed staff code kills the token
  created_at  timestamptz not null default now()
);
alter table public.guide_staff_sessions enable row level security;
revoke all on public.guide_staff_sessions from public, anon, authenticated, service_role;
-- no policies and no grants: only the SECURITY DEFINER functions below touch this table.

-- 2. staff: PIN -> 12 hour token ----------------------------------------------------------------------------------------------------------
create function public.guide_staff_session_v1(p_code text, p_client text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' set lock_timeout = '2s' as $$
declare
  v_res jsonb; v_token text; v_live int; v_exp timestamptz; v_fp text;
begin
  -- verify_admin_pin keeps its own wrong-code throttle (per request address) and writes its own attempt row; p_client goes through untouched and its answer is
  -- returned unchanged (token added on success). This call is outside the block below on purpose: a lock timeout there must not undo the attempt row.
  v_res := public.verify_admin_pin(p_code => p_code, p_client => p_client);
  if v_res is null or v_res -> 'ok' is distinct from 'true'::jsonb then
    return coalesce(v_res, jsonb_build_object('ok', false));
  end if;

  begin
    perform pg_advisory_xact_lock(hashtext('guide_staff_session'));
    v_fp := md5(coalesce((select a.value #>> '{}' from public.app_settings a where a.key = 'admin_pin_hash'), ''));
    delete from public.guide_staff_sessions where expires_at <= now() or pin_fp <> v_fp;
    select count(*) into v_live from public.guide_staff_sessions;      -- every row left is live and carries the current staff-code fingerprint
    if v_live >= 50 then
      return v_res || jsonb_build_object('reason', 'busy');
    end if;
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_exp := now() + interval '12 hours';
    insert into public.guide_staff_sessions(token_hash, expires_at, pin_fp)
    values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_exp, v_fp);
    return v_res || jsonb_build_object('token', v_token, 'expires_at', v_exp);
  exception when lock_not_available then
    return v_res || jsonb_build_object('reason', 'busy');
  end;
end;
$$;
revoke all on function public.guide_staff_session_v1(text, text) from public, anon, authenticated, service_role;
grant execute on function public.guide_staff_session_v1(text, text) to anon, authenticated;

-- 3. the secrets, against a live guest or staff token -------------------------------------------------------------------------------------
create function public.guide_secrets_v1(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_kind text;
begin
  if p_token is null or char_length(p_token) not between 32 and 128 then
    return jsonb_build_object('ok', false);
  end if;
  if public.guide_token_thread_v1(p_token) is not null then
    v_kind := 'guest';
  else
    select 'staff' into v_kind from public.guide_staff_sessions s
     where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') and s.expires_at > now()
       and s.pin_fp = md5(coalesce((select a.value #>> '{}' from public.app_settings a where a.key = 'admin_pin_hash'), ''));
  end if;
  if v_kind is null then
    return jsonb_build_object('ok', false);
  end if;
  return jsonb_build_object('ok', true, 'kind', v_kind,
    'wifi_ssid',      (select a.value #>> '{}' from public.app_settings a where a.key = 'wifi_ssid'),
    'wifi_password',  (select a.value #>> '{}' from public.app_settings a where a.key = 'wifi_password'),
    'onground_name',  (select a.value #>> '{}' from public.app_settings a where a.key = 'onground_name'),
    'onground_phone', (select a.value #>> '{}' from public.app_settings a where a.key = 'onground_phone'));
end;
$$;
revoke all on function public.guide_secrets_v1(text) from public, anon, authenticated, service_role;
grant execute on function public.guide_secrets_v1(text) to anon, authenticated;

-- 4. public-safe settings -----------------------------------------------------------------------------------------------------------------
create function public.get_public_settings() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(s.key, s.value), '{}'::jsonb) from public.app_settings s
   where s.key = any (array['wifi_ssid', 'house_times', 'min_nights', 'max_nights', 'review_airbnb_url', 'review_facebook_url',
                            'review_google_url', 'property_lat', 'property_lng', 'concierge_mode']);
$$;
revoke all on function public.get_public_settings() from public, anon, authenticated, service_role;
grant execute on function public.get_public_settings() to anon, authenticated;

-- 5. weather-proxy warm-up ----------------------------------------------------------------------------------------------------------------
-- Every 10 minutes (UTC, no timezone effect). Where pg_cron or pg_net is absent (a rehearsal copy) nothing is scheduled. Idempotent: unscheduled by name first.
-- No header is sent: the guide calls the function the same way. timeout 30 s lets a cold start finish and write the cache.
do $cron$
begin
  if to_regclass('cron.job') is null or to_regnamespace('net') is null then
    raise notice 'pg_cron or pg_net absent (rehearsal copy) - weather-proxy-warm not scheduled';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'weather-proxy-warm';
  perform cron.schedule('weather-proxy-warm', '*/10 * * * *',
    $cmd$select net.http_get(url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/weather-proxy', timeout_milliseconds := 30000)$cmd$);
end $cron$;
