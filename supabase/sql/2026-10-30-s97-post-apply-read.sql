-- s97 post-apply live read (read only): the cron job and heartbeat the rehearsal could not test (no pg_cron there), the backlog of photos still waiting for a face box,
-- the rotation reader columns and the grants. Counts only: no path, name or box value is printed.
begin read only;
\pset pager off
select jobname, schedule, active, command from cron.job where jobname = 'id-face-locate-10m';
select job_name, expected_interval_seconds, ops_risk, last_started_at, last_succeeded_at, consecutive_failures from public.job_heartbeats where job_name = 'id-face-locate';
select count(*) filter (where id_photo_path is not null) as companions_with_photo,
       count(*) filter (where id_photo_path is not null and id_face_box is null) as photo_and_null_face_box,
       count(*) filter (where id_face_box ->> 'src' = 'vision') as face_found,
       count(*) filter (where id_face_box ->> 'src' = 'none') as no_face_found
  from public.guest_companions;
select pg_get_function_result('public.staff_photo_rotation_v1(text[])'::regprocedure) as rotation_reader_columns;
select has_function_privilege('anon', 'public.id_face_todo_v1(integer)', 'execute') as anon_can_todo,
       has_function_privilege('authenticated', 'public.id_face_todo_v1(integer)', 'execute') as authenticated_can_todo,
       has_function_privilege('service_role', 'public.id_face_todo_v1(integer)', 'execute') as service_role_can_todo,
       has_function_privilege('anon', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute') as anon_can_set,
       has_function_privilege('authenticated', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute') as authenticated_can_set,
       has_function_privilege('service_role', 'public.set_id_face_box_v1(uuid,text,jsonb)', 'execute') as service_role_can_set,
       has_function_privilege('anon', 'public.staff_photo_rotation_v1(text[])', 'execute') as anon_can_read_rotation,
       has_function_privilege('authenticated', 'public.staff_photo_rotation_v1(text[])', 'execute') as authenticated_can_read_rotation;
select (public.staff_guest_card_v1(g.property_id, g.id, (now() at time zone 'Asia/Manila')::date) ? 'id_face_box') as card_has_id_face_box from public.guests g order by g.id limit 1;
commit;
