-- rollback_20261207_guide_v9_secrets.sql: removes everything 20261207000000_guide_v9_secrets.sql created (the weather-proxy-warm cron job, three functions,
-- the guide_staff_sessions table). run-sql-on-host.sh does NOT wrap a file: this script carries its own begin/commit.
-- Guide v8 (sessions, messages, analytics) and verify_admin_pin are not touched. Staff tokens issued by guide_staff_session_v1 die with the table:
-- a staff phone just signs in again. Revert the guide v9 frontend first (it calls these functions); until then the guide falls back to its old behaviour.
-- ORDER: run supabase/rollbacks/20261207_verify_admin_pin_bound.sql BEFORE this file (it restores verify_admin_pin and drops the attempts index); this file does not touch verify_admin_pin.
begin;
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'weather-proxy-warm';
  end if;
end $$;
drop function if exists public.get_public_settings();
drop function if exists public.guide_secrets_v1(text);
drop function if exists public.guide_staff_session_v1(text, text);
drop table if exists public.guide_staff_sessions;
commit;
