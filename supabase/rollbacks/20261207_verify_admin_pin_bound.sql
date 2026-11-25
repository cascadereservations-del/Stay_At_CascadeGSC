-- rollback_20261207_verify_admin_pin_bound.sql: restores the verify_admin_pin body that was live before 20261207000100_verify_admin_pin_bound.sql (md5 of prosrc
-- ca4ade3f91d42574c9176d2331e10f41, 1373 bytes, copied byte for byte from supabase/migrations/20260817044526_verify_admin_pin_rpc.sql and equal to the live definition read
-- 2026-11-25) and drops the index admin_auth_attempts_attempted_at_idx. Same signature, SECURITY DEFINER, search_path = public, extensions; grants restated by name
-- (anon, authenticated, service_role execute; PUBLIC none), equal to the live ACL. run-sql-on-host.sh does NOT wrap a file: this script carries its own begin/commit.
-- Order: run this BEFORE supabase/rollbacks/20261207_guide_v9_secrets.sql (the v9 functions call verify_admin_pin). Rows already in admin_auth_attempts stay (nothing is deleted).
-- Guard: the live body must be the bound body of this release (md5 b4a0aa337ba7cffac62feb7bcd633f8b) or already the previous one (md5 ca4ade3f...); 55000 on anything else.
begin;
do $g$
declare v text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.verify_admin_pin(text,text)');
  if v is null then raise exception 'verify_admin_pin rollback: public.verify_admin_pin(text,text) is missing' using errcode = '55000'; end if;
  if v is distinct from 'b4a0aa337ba7cffac62feb7bcd633f8b' and v is distinct from 'ca4ade3f91d42574c9176d2331e10f41' then
    raise exception 'verify_admin_pin rollback: the live body is neither the bound body nor the previous one (md5 %)', v using errcode = '55000';
  end if;
end $g$;

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
begin
  -- Identify the caller for throttling. Never store a raw IP: hash it with the
  -- row id space so the table cannot be used to track visitors.
  v_ip := encode(extensions.digest(coalesce(p_client, 'unknown') || '|cascade-guide', 'sha256'), 'hex');

  select count(*) into v_recent
  from admin_auth_attempts
  where ip_hash = v_ip
    and succeeded = false
    and attempted_at > now() - interval '15 minutes';

  if v_recent >= 8 then
    return jsonb_build_object('ok', false, 'throttled', true);
  end if;

  select value #>> '{}' into v_hash from app_settings where key = 'admin_pin_hash';
  if v_hash is null or p_code is null or length(p_code) = 0 then
    insert into admin_auth_attempts (ip_hash, succeeded) values (v_ip, false);
    return jsonb_build_object('ok', false);
  end if;

  -- bcrypt: hashing the candidate with the stored hash as salt reproduces it.
  v_ok := extensions.crypt(lower(trim(p_code)), v_hash) = v_hash;

  insert into admin_auth_attempts (ip_hash, succeeded) values (v_ip, v_ok);

  if not v_ok then
    return jsonb_build_object('ok', false);
  end if;

  select value into v_users from app_settings where key = 'users';
  return jsonb_build_object('ok', true, 'users', coalesce(v_users, '[]'::jsonb));
end;
$$;
revoke all on function public.verify_admin_pin(text, text) from public, anon, authenticated, service_role;
grant execute on function public.verify_admin_pin(text, text) to anon, authenticated, service_role;

drop index if exists public.admin_auth_attempts_attempted_at_idx;
commit;
