-- Compensating rollback for release cron_secret_three_jobs_20261007 (session 74 G8).
-- The jobs keep sending the header after a rollback of the FUNCTIONS (an old function ignores it), so the normal rollback is to
-- redeploy the previous function versions and leave the cron wiring as it is. Nothing here is needed unless the cron jobs
-- themselves must go back to their pre-G8 commands; that restores a state where the functions (old versions only) take any POST.
begin;
do $$
begin
  if to_regclass('cron.job') is null then return; end if;
  perform cron.unschedule(jobid) from cron.job where jobname in ('finance-watch-daily', 'release-expired-holds-hourly', 'verify-meter-photo-daily');
  perform cron.schedule('finance-watch-daily', '30 0 * * *', $c$select net.http_post(
    url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/finance-watch',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj'),
    body := '{}'::jsonb);$c$);
  perform cron.schedule('release-expired-holds-hourly', '20 * * * *', $c$SELECT net.http_post(
    url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/release-expired-holds',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj'),
    body := '{}'::jsonb);$c$);
  perform cron.schedule('verify-meter-photo-daily', '30 23 * * *', $c$select net.http_post(
    url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/verify-meter-photo',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFrZ2Zoc2RwcHNsd3VuYXJjemVxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk2MjI3MDYsImV4cCI6MjA5NTE5ODcwNn0.Rf1XhyuxkkoGd2HG0I02CP0BA4mu8kfQalLtStDaXAI'),
    body := '{"lookback":14,"limit":5,"notify":false}'::jsonb, timeout_milliseconds := 300000);$c$);
end $$;
commit;
