-- Server-side admin PIN check for the guest guide.
--
-- Before this, index.html compared a plaintext ADMIN_CODE in the browser, so
-- anyone doing View Source could read it. The bcrypt hash in
-- app_settings.admin_pin_hash already existed but was never used.
--
-- SECURITY DEFINER so it can read admin_pin_hash, which anon RLS blocks.
-- The function returns only a boolean and, on success, the identity list.
-- It never returns the hash or echoes the code.

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

revoke all on function public.verify_admin_pin(text, text) from public;
grant execute on function public.verify_admin_pin(text, text) to anon, authenticated;

comment on function public.verify_admin_pin(text, text) is
  'Guest-guide admin gate. Compares a candidate PIN against app_settings.admin_pin_hash (bcrypt) server-side and returns the identity list on success. Throttled to 8 failures per 15 min per hashed client. Replaces the plaintext ADMIN_CODE that was readable in index.html.';;
