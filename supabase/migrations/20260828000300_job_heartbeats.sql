create table public.job_heartbeats (
  job_name text primary key check (job_name ~ '^[a-z0-9][a-z0-9-]{2,79}$'),
  expected_interval_seconds integer not null check (expected_interval_seconds >= 60),
  last_started_at timestamptz,
  last_succeeded_at timestamptz,
  last_error_code text check (last_error_code is null or last_error_code ~ '^[A-Z0-9_]{1,64}$'),
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  ops_risk boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.job_heartbeats enable row level security;
-- The recovered baseline grants service_role through ALTER DEFAULT PRIVILEGES.
-- Revoke it explicitly so the role cannot bypass the security-definer recorder.
revoke all on public.job_heartbeats from public, anon, authenticated, service_role;
grant select on public.job_heartbeats to service_role;

insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk)
values
  ('turnover-verifier-daily', 86400, true),
  ('job-heartbeat-monitor-every-15m', 900, false)
on conflict (job_name) do update
set expected_interval_seconds = excluded.expected_interval_seconds,
    ops_risk = excluded.ops_risk,
    updated_at = now();

create or replace function public.record_job_heartbeat(
  p_job_name text,
  p_phase text,
  p_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_phase not in ('started', 'succeeded', 'failed') then
    raise exception using errcode = '22023', message = 'invalid heartbeat phase';
  end if;

  if not exists (
    select 1 from public.job_heartbeats where job_name = p_job_name
  ) then
    raise exception using errcode = '22023', message = 'unknown scheduled job';
  end if;

  update public.job_heartbeats
  set last_started_at = case when p_phase = 'started' then now() else last_started_at end,
      last_succeeded_at = case when p_phase = 'succeeded' then now() else last_succeeded_at end,
      last_error_code = case
        when p_phase = 'failed' then coalesce(p_error_code, 'UNSPECIFIED_FAILURE')
        when p_phase = 'succeeded' then null
        else last_error_code
      end,
      consecutive_failures = case
        when p_phase = 'failed' then consecutive_failures + 1
        when p_phase = 'succeeded' then 0
        else consecutive_failures
      end,
      updated_at = now()
  where job_name = p_job_name;
end;
$$;

revoke all on function public.record_job_heartbeat(text, text, text) from public, anon, authenticated;
grant execute on function public.record_job_heartbeat(text, text, text) to service_role;

alter table public.automation_outbox
  drop constraint if exists automation_outbox_event_type_check,
  add constraint automation_outbox_event_type_check check (event_type in (
    'booking.requested', 'booking.receipt_uploaded', 'booking.confirmed', 'booking.cancelled',
    'guest.returning_detected', 'guest.identity_conflict', 'calendar.projection_requested',
    'calendar.conflict', 'system.job_stale'
  )),
  drop constraint if exists automation_outbox_aggregate_type_check,
  add constraint automation_outbox_aggregate_type_check check (aggregate_type in (
    'booking_inquiry', 'reservation', 'guest', 'calendar_event', 'scheduled_job'
  ));

create or replace function public.configure_cascade_scheduler()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'cascade_supabase_url') then
    raise exception using errcode = '22023', message = 'missing vault secret: cascade_supabase_url';
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'cascade_cron_shared_secret') then
    raise exception using errcode = '22023', message = 'missing vault secret: cascade_cron_shared_secret';
  end if;

  if exists (select 1 from cron.job where jobname = 'turnover-verifier-daily') then
    perform cron.unschedule('turnover-verifier-daily');
  end if;
  if exists (select 1 from cron.job where jobname = 'job-heartbeat-monitor-every-15m') then
    perform cron.unschedule('job-heartbeat-monitor-every-15m');
  end if;

  perform cron.schedule(
    'turnover-verifier-daily',
    '0 0 * * *',
    $cron$
      select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_supabase_url') || '/functions/v1/turnover-verifier',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'X-Cascade-Cron-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
      );
    $cron$
  );

  perform cron.schedule(
    'job-heartbeat-monitor-every-15m',
    '*/15 * * * *',
    $cron$
      select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_supabase_url') || '/functions/v1/job-heartbeat-monitor',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'X-Cascade-Cron-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
      );
    $cron$
  );
end;
$function$;

revoke all on function public.configure_cascade_scheduler() from public, anon, authenticated, service_role;

comment on function public.configure_cascade_scheduler() is
  'Owner-only activation step. Replaces only the two named Cascade schedules after required vault secrets exist.';
