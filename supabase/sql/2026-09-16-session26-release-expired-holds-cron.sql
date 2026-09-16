-- Session 26 (2026-09-16), hold-before-pay (D-160 #1, audit plan 5b step 5).
-- Seeds the heartbeat row and schedules release-expired-holds hourly at :20.
-- Idempotent: unschedules by name first. Lloyd runs it with run-sql-on-host.sh.
begin;
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('release-expired-holds-hourly', 7200, false, now())
on conflict (job_name) do update set expected_interval_seconds = excluded.expected_interval_seconds, ops_risk = excluded.ops_risk;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'release-expired-holds-hourly') then
    perform cron.unschedule('release-expired-holds-hourly');
  end if;
  perform cron.schedule('release-expired-holds-hourly', '20 * * * *', $cmd$SELECT net.http_post(
    url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/release-expired-holds',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj'),
    body    := '{}'::jsonb
  );$cmd$);
end $$;
commit;

-- Forward checks
select jobname, schedule from cron.job where jobname = 'release-expired-holds-hourly';   -- 20 * * * *
select job_name, expected_interval_seconds from public.job_heartbeats where job_name = 'release-expired-holds-hourly'; -- 7200
