-- s96 post-apply live read (read only): the cron job and heartbeat the rehearsal could not test (no pg_cron there),
-- the topics table (empty until the waves writers ship), the card key and the grants.
begin read only;
\pset pager off
select jobname, schedule, active, command from cron.job where jobname = 'guest-retention-nightly';
select job_name, expected_interval_seconds, ops_risk, last_succeeded_at from public.job_heartbeats where job_name = 'guest-retention-nightly';
select count(*) as topic_rows, count(*) filter (where last_seen < now() - interval '365 days') as older_than_365_days from public.guest_topics;
select has_function_privilege('anon', 'public.record_guest_topic_v1(uuid,uuid,text,text)', 'execute') as anon_can_record,
       has_function_privilege('authenticated', 'public.record_guest_topic_v1(uuid,uuid,text,text)', 'execute') as authenticated_can_record,
       has_function_privilege('service_role', 'public.record_guest_topic_v1(uuid,uuid,text,text)', 'execute') as service_role_can_record,
       has_function_privilege('anon', 'public.guest_retention_nightly_v1()', 'execute') as anon_can_run_sweep,
       has_function_privilege('service_role', 'public.guest_retention_nightly_v1()', 'execute') as service_role_can_run_sweep,
       has_function_privilege('anon', 'public.purge_guest_topics_v1()', 'execute') as anon_can_purge,
       has_function_privilege('authenticated', 'public.purge_guest_topics_v1()', 'execute') as authenticated_can_purge,
       has_function_privilege('service_role', 'public.purge_guest_topics_v1()', 'execute') as service_role_can_purge,
       has_function_privilege('anon', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') as anon_can_read_card,
       has_function_privilege('authenticated', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') as authenticated_can_read_card,
       has_table_privilege('service_role', 'public.guest_topics', 'select') as service_role_can_read_table;
select (public.staff_guest_card_v1(g.property_id, g.id, (now() at time zone 'Asia/Manila')::date) ? 'notable') as card_has_notable,
       public.staff_guest_card_v1(g.property_id, g.id, (now() at time zone 'Asia/Manila')::date) -> 'notable' as notable
  from public.guests g order by g.id limit 1;
-- the ID photos are untouched by this release: companions with a photo, as a count only
select count(*) filter (where id_photo_path is not null) as companions_with_photo from public.guest_companions;
commit;
