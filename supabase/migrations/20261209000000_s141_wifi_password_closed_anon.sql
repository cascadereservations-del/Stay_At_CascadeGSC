-- 20261209000000_s141_wifi_password_closed_anon.sql
-- s141: the anon role can no longer select the wifi_password row of public.app_settings. NOT APPLIED.
-- Rollback: supabase/rollbacks/20261209_s141_wifi_password_closed_anon.sql. Release: supabase/releases/s141_wifi_password_closed_anon_20261209.release.json. Test: supabase/tests/database/s141_wifi_password_closed_anon.sql.
--
-- Why: row level security is the only gate on app_settings (anon and authenticated both hold table privileges). The permissive "anon select public" policy is a deny-list by key pattern
-- and wifi_password matches none of its patterns, so the public key could read the guest Wi-Fi password straight from the table. Since guide v9 (20261207000000) the password is handed out by
-- guide_secrets_v1(token) against a live guest token, and no live front-end reads it as anon any more.
--
-- What changes: one RESTRICTIVE select policy for anon, key <> 'wifi_password'. A restrictive policy is ANDed with every permissive one, so no permissive policy can reopen the row.
-- What stays open: every other key anon could read before (wifi_ssid included); the bill_schedule restrictive policies of 20261128000000; authenticated staff reads (app_settings_staff_read);
-- admin writes; service_role (bypasses RLS); the SECURITY DEFINER functions guide_secrets_v1 and get_public_settings (they run as the table owner). No table, column, grant or function changes.
--
-- Guard (55000): stops with a clear message unless public.app_settings exists and has row level security enabled (without RLS a policy does nothing, so the row would still be open).
-- Idempotent: drop policy if exists, then create. The runner wraps the file (no begin/commit here).
do $g$
begin
  if to_regclass('public.app_settings') is null then
    raise exception 's141 wifi_password: public.app_settings is missing' using errcode = '55000';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.app_settings'::regclass) then
    raise exception 's141 wifi_password: row level security is not enabled on public.app_settings, so a policy would not close the row: enable RLS first' using errcode = '55000';
  end if;
end $g$;

drop policy if exists app_settings_wifi_password_closed_anon on public.app_settings;
create policy app_settings_wifi_password_closed_anon on public.app_settings as restrictive for select to anon using (key <> 'wifi_password');
