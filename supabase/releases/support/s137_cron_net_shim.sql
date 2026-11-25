-- Rehearsal only (guide v9, s137): the restored copy has no pg_cron and no pg_net, so the migration skips the weather-proxy-warm job there. This shim creates the minimum
-- the migration and the forward check touch (cron.job with the columns of pg_cron 1.6, cron.schedule, cron.unschedule, an empty net schema) so the cron branch and the
-- "scheduled, active, once" check actually run. It never touches production. Appended to s136_pre_grants.sql by scripts/recovery/p6/guide-v9-rehearsal.sh (mode cron).
create schema if not exists cron;
create table cron.job (jobid bigserial primary key, schedule text not null, command text not null, nodename text default 'localhost', nodeport int default 5432,
  database text default 'rehearsal', username text default 'postgres', active boolean not null default true, jobname text);
create function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as
  $$ insert into cron.job(jobname, schedule, command) values (job_name, schedule, command) returning jobid $$;
create function cron.unschedule(job_id bigint) returns boolean language sql as
  $$ with d as (delete from cron.job where jobid = job_id returning 1) select exists (select 1 from d) $$;
create schema if not exists net;
