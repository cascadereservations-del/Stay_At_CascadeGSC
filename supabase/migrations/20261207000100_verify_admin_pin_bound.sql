-- 20261207000100_verify_admin_pin_bound.sql
-- verify_admin_pin: throttle on the caller's request address (IPv6 by /64), 20 wrong tries per address, no row for an empty code, inline trim, global cap. NOT APPLIED. Second migration of the guide v9 release
-- (contract supabase/releases/20261207_guide_v9_secrets.release.json); apply it AFTER 20261207000000_guide_v9_secrets.sql in the same release run.
-- Rollback: supabase/rollbacks/20261207_verify_admin_pin_bound.sql (restores the previous body byte for byte, drops the index). Checks: supabase/sql/2026-12-07-guide-v9-verify.sql.
--
-- Why (Opus audit A1, MAJOR-1 and MAJOR-2, orchestrator ruling R1): the live function keyed its 8-failures-per-15-minutes throttle on a hash of the p_client string the
-- caller sends. anon may call it, so (1) a caller that rotates p_client is never throttled, (2) a caller can send another person's key ('ip:<their address>') and lock
-- that person out, and (3) every call inserted a row into admin_auth_attempts, even an empty code (no bcrypt, so it is cheap), and nothing ever deleted one.
--
-- Changes (everything else is the live body, byte for byte: same signature, same return shapes, same bcrypt compare, same hash/salt scheme, same SECURITY DEFINER,
-- same search_path = public, extensions; the ACL is restated below and equals the live one)
--  a. Throttle key. With a request address (cf-connecting-ip, else the RIGHTMOST x-forwarded-for entry, each trimmed and accepted only when address-shaped, exactly as
--     guide_session_v1 of guide v8 derives it; the LEFTMOST entry is whatever the client sent and is never used) the key is 'ip:' || address and p_client is IGNORED.
--     An IPv6 address is grouped by its /64 (the network a single host or customer routes): the key is 'ip:' || network(address/64), e.g. 'ip:2001:db8:1:2::/64', so one host cannot
--     get a fresh bucket per source address (audit A2 MAJOR-1). IPv4 (and an IPv4-mapped ::ffff: address) stays per address.
--     p_client is used ONLY when the request.headers setting is absent or empty (a direct SQL call, cron). When request.headers is present but yields no usable address
--     (garbled JSON, no address-shaped entry, an address that does not parse) the key is the constant 'noaddr': shared, so it fails closed and rotating p_client escapes nothing (A2 MINOR-1).
--     With neither headers nor p_client the key is 'unknown'.
--     The key is hashed as before: sha256(key || '|cascade-guide'). Old rows stay comparable in shape.
--  a2. Per-address limit: 20 wrong codes per key in 15 minutes (owner decision 2026-11-25, was 8; the live guide is used from one shared property address).
--  b. A null or empty code answers {"ok": false} (or the throttled answer when the key is already throttled, as before) WITHOUT inserting a row.
--  c. Inline trim: a call that inserts first deletes up to 200 rows older than 1 day, oldest first (for update skip locked, as guide v8 does for guide_auth_attempts), through the
--     new index admin_auth_attempts_attempted_at_idx. Both throttle windows are 15 minutes, so a row older than a day is never read.
--  d. Global cap: when the table already holds more than 400 rows from the last 15 minutes, the call answers exactly like the existing throttled answer
--     ({"ok": false, "throttled": true}) and inserts nothing, whatever the code (a right code too: the cap is an availability trade for a storage bound).
--     It is checked cheaply before the bcrypt compare (so a flood costs no bcrypt) and again under one advisory lock right before the insert, so the cap is exact.
--
-- ROUGH EDGES (documented, not bugs): everyone behind one public address (the property Wi-Fi) or one IPv6 /64 shares a bucket; 20 wrong codes from anyone there lock all of them for 15 minutes.
--
-- STORAGE BOUND (admin_auth_attempts, the only table this function writes). An insert happens only while the last 15 minutes hold at most 400 rows, so at most 401 rows are
-- inserted in any 15 minutes (exact, because the recount and the insert run under one advisory lock). One day holds 96 such windows: at most 96 x 401 = 38,496 rows a day.
-- The trim keeps nothing older than a day (it removes up to 200 rows per inserting call, far more than the 401 per 15 minutes that can arrive), so the table holds at most
-- about 38,500 rows. A row is about 270 bytes (heap about 120, three indexes: pkey, ip_hash+time, attempted_at), so the worst case is about 10 MB, far below the 500 MB plan
-- (today: 38 rows, 80 KB). Before this change the table was unbounded. The pgTAP suite asserts the 401 limit with 450 attempts from 450 addresses.
--
-- ML-21: the grants are restated in full (revoke from public, anon, authenticated and service_role by name, then the three roles the live function has). Production default privileges
-- would otherwise differ from a --no-acl rehearsal copy. Live ACL read 2026-11-25: postgres, anon, authenticated and service_role may execute; PUBLIC may not.

-- 0. guard: refuse to replace a body this release was not cut from ---------------------------------------------------------------------------
do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.verify_admin_pin(text,text)');
  if v is null then
    raise exception 'verify_admin_pin bound: public.verify_admin_pin(text,text) is missing' using errcode = '55000';
  end if;
  if v is distinct from 'ca4ade3f91d42574c9176d2331e10f41' then
    raise exception 'verify_admin_pin bound: the live body is not the one this release was cut from (md5 %): re-cut it from the live body', v using errcode = '55000';
  end if;
  if to_regclass('public.admin_auth_attempts') is null then
    raise exception 'verify_admin_pin bound: public.admin_auth_attempts is missing' using errcode = '55000';
  end if;
  if to_regclass('public.admin_auth_attempts_attempted_at_idx') is not null then
    raise exception 'verify_admin_pin bound: already applied (admin_auth_attempts_attempted_at_idx exists)' using errcode = '55000';
  end if;
end $g$;

-- 1. index for the trim and the window count ---------------------------------------------------------------------------------------------------
create index admin_auth_attempts_attempted_at_idx on public.admin_auth_attempts (attempted_at);

-- 2. the function ---------------------------------------------------------------------------------------------------------------------------------
create or replace function public.verify_admin_pin(p_code text, p_client text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash      text;
  v_ok        boolean := false;
  v_ip        text;
  v_recent    int;
  v_users     jsonb;
  v_hdr       json;
  v_xff       text[];
  v_cand      text;
  v_addr      text;
  v_key       text;
  v_raw       text;
begin
  -- Request address as the edge reports it: cf-connecting-ip, then the RIGHTMOST x-forwarded-for entry; each trimmed, used only when address-shaped.
  -- request.headers is set by PostgREST; bad JSON, a non-object value or a missing setting must never raise: the key just falls back ('noaddr' when the setting exists, p_client when it does not).
  v_raw := nullif(current_setting('request.headers', true), '');
  begin
    v_hdr := v_raw::json;
    v_xff := string_to_array(coalesce(v_hdr->>'x-forwarded-for', ''), ',');
    foreach v_cand in array array[btrim(v_hdr->>'cf-connecting-ip'), btrim(v_xff[cardinality(v_xff)])] loop
      if v_cand ~ '^[0-9A-Fa-f:.]{2,45}$' then v_addr := v_cand; exit; end if;
    end loop;
    -- IPv6: one bucket per /64 (an IPv4-mapped ::ffff: address stays as it is); a value that does not parse as an address raises into the handler below.
    if v_addr like '%:%' and v_addr !~* '^::ffff:' then
      v_addr := network(set_masklen(v_addr::inet, 64))::text;
    end if;
  exception when others then
    v_addr := null;
  end;
  -- Identify the caller for throttling. Never store a raw IP: hash it so the table cannot be used to track visitors.
  -- Headers present but no usable address: the shared constant 'noaddr' (fail closed). p_client only when there is no headers setting at all.
  v_key := case when v_addr is not null then 'ip:' || v_addr when v_raw is not null then 'noaddr' else coalesce(p_client, 'unknown') end;
  v_ip := encode(extensions.digest(v_key || '|cascade-guide', 'sha256'), 'hex');

  select count(*) into v_recent
  from public.admin_auth_attempts
  where ip_hash = v_ip
    and succeeded = false
    and attempted_at > now() - interval '15 minutes';

  if v_recent >= 20 then
    return jsonb_build_object('ok', false, 'throttled', true);
  end if;

  -- An empty code writes nothing (it is the cheap way to fill the table).
  if p_code is null or length(p_code) = 0 then
    return jsonb_build_object('ok', false);
  end if;

  -- Global cap, cheap check first (no bcrypt for a flood): more than 400 rows in the last 15 minutes = throttled, nothing inserted.
  if (select count(*) from public.admin_auth_attempts where attempted_at > now() - interval '15 minutes') > 400 then
    return jsonb_build_object('ok', false, 'throttled', true);
  end if;

  select value #>> '{}' into v_hash from public.app_settings where key = 'admin_pin_hash';
  if v_hash is not null then
    -- bcrypt: hashing the candidate with the stored hash as salt reproduces it.
    v_ok := extensions.crypt(lower(trim(p_code)), v_hash) = v_hash;
  end if;

  -- Recount and insert under one lock so the cap is exact; then trim (up to 200 rows older than a day, oldest first).
  perform pg_advisory_xact_lock(hashtext('verify_admin_pin_attempts'));
  if (select count(*) from public.admin_auth_attempts where attempted_at > now() - interval '15 minutes') > 400 then
    return jsonb_build_object('ok', false, 'throttled', true);
  end if;
  delete from public.admin_auth_attempts
   where id in (select id from public.admin_auth_attempts where attempted_at < now() - interval '1 day' order by attempted_at limit 200 for update skip locked);
  insert into public.admin_auth_attempts (ip_hash, succeeded) values (v_ip, v_ok);

  if not v_ok then
    return jsonb_build_object('ok', false);
  end if;

  select value into v_users from public.app_settings where key = 'users';
  return jsonb_build_object('ok', true, 'users', coalesce(v_users, '[]'::jsonb));
end;
$$;
revoke all on function public.verify_admin_pin(text, text) from public, anon, authenticated, service_role;
grant execute on function public.verify_admin_pin(text, text) to anon, authenticated, service_role;
