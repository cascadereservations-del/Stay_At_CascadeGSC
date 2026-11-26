-- rollback_20261209_s141_wifi_password_closed_anon.sql: removes the one restrictive policy 20261209000000_s141_wifi_password_closed_anon.sql added. Idempotent (a second run changes nothing).
-- After it, anon can read the wifi_password row again (the permissive "anon select public" policy does not exclude it): run it only if the lock breaks something that cannot wait.
-- run-sql-on-host.sh does NOT wrap a file: this script carries its own begin/commit.
begin;
drop policy if exists app_settings_wifi_password_closed_anon on public.app_settings;
commit;
