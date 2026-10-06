-- Compensating rollback for release cleaning_photo_expiry_20261006 (session 72).
-- Stops the weekly job and removes its heartbeat row. Photos already removed from Supabase Storage are NOT restored by this: they
-- are in Drive (the function only ever removes a copy Drive holds), and no table was changed.
begin;
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'expire-cleaning-photos-weekly';
  end if;
end $$;
delete from public.job_heartbeats where job_name = 'expire-cleaning-photos-weekly';
commit;
