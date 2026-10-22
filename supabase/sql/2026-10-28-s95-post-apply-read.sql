-- s95 post-apply live read (read only): the cron job and heartbeat the rehearsal could not test (no pg_cron there),
-- tier counts, the arrival-card keys, and that refresh_guest_stats is closed to the app roles.
begin read only;
\pset pager off
select jobname, schedule, active from cron.job where jobname = 'guest-tiers-nightly';
select job_name, expected_interval_seconds from public.job_heartbeats where job_name = 'guest-tiers-nightly';
select coalesce(tier, '(none)') as tier, count(*) as guests, count(tier_manual) as set_by_hand from public.guests group by 1 order by 1;
select has_function_privilege('authenticated', 'public.refresh_guest_stats(uuid)', 'execute') as authenticated_can_refresh,
       has_function_privilege('anon', 'public.refresh_guest_stats(uuid)', 'execute') as anon_can_refresh;
select g.tier, (public.staff_guest_card_v1(g.property_id, g.id, (now() at time zone 'Asia/Manila')::date) ? 'tier_line') as card_has_tier_line,
       left(public.staff_guest_card_v1(g.property_id, g.id, (now() at time zone 'Asia/Manila')::date) ->> 'tier_line', 60) as tier_line_start
  from public.guests g where g.tier = 'regular' order by g.id limit 1;
commit;
