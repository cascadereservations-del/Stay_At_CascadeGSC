-- verify_20261206_guide_v8.sql: read-only forward checks after the release (run with the read-only runner).
-- Every row must say ok = true.
begin transaction read only;
select 'tables' as check, count(*) = 5 as ok from pg_tables where schemaname = 'public'
  and tablename in ('guide_threads','guide_sessions','guide_messages','guide_auth_attempts','guide_events')
union all
select 'rls on all five', bool_and(c.relrowsecurity) from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relname in ('guide_threads','guide_sessions','guide_messages','guide_auth_attempts','guide_events')
union all
select 'anon has no table grants', not exists (select 1 from information_schema.role_table_grants
 where grantee in ('anon','authenticated') and table_schema = 'public' and table_name like 'guide\_%')
union all
select 'anon may call the four guest functions', bool_and(has_function_privilege('anon', f, 'execute')) from unnest(array[
  'public.guide_session_v1(date,text,text,uuid)','public.guide_thread_v1(text,timestamptz)',
  'public.guide_send_v1(text,text,text)','public.guide_track_v1(text,jsonb,text,text)']::regprocedure[]) f
union all
select 'anon may not call staff functions', not bool_or(has_function_privilege('anon', f, 'execute')) from unnest(array[
  'public.staff_guide_threads_v1(uuid)','public.staff_guide_thread_v1(uuid)','public.staff_guide_reply_v1(uuid,text,text)',
  'public.staff_guide_resolve_v1(uuid,boolean)','public.staff_guide_usage_v1(integer,uuid)','public.staff_guide_guests_v1(integer,uuid)',
  'public.guide_token_thread_v1(text)','public.guide_sweep_v1()']::regprocedure[]) f
union all
select 'all definer functions pin search_path', bool_and(p.proconfig @> array['search_path=""']) from pg_proc p
 join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and (p.proname like 'guide\_%' or p.proname like 'staff\_guide\_%')
union all
select 'authenticated may call the guests report, service_role and anon may not', has_function_privilege('authenticated', 'public.staff_guide_guests_v1(integer,uuid)', 'execute')
  and not has_function_privilege('anon', 'public.staff_guide_guests_v1(integer,uuid)', 'execute')
  and not has_function_privilege('service_role', 'public.staff_guide_guests_v1(integer,uuid)', 'execute')
union all
select 'push trigger present', exists (select 1 from pg_trigger where tgname = 'guide_messages_push' and not tgisinternal)
union all
select 'authenticated has no execute on the token helper, the sweep or the push trigger function', not bool_or(has_function_privilege('authenticated', f, 'execute')) from unnest(array[
  'public.guide_token_thread_v1(text)','public.guide_sweep_v1()','public.guide_messages_push_trg()']::regprocedure[]) f
union all
select 'service_role may execute the sweep', has_function_privilege('service_role', 'public.guide_sweep_v1()', 'execute')
union all
select 'service_role has full access to the five tables', bool_and(has_table_privilege('service_role', 'public.' || t, p)) from
  unnest(array['guide_threads','guide_sessions','guide_messages','guide_auth_attempts','guide_events']) t, unnest(array['select','insert','update','delete']) p
union all
select 'identity sequences closed to anon and authenticated', not bool_or(has_sequence_privilege(r, 'public.' || q, p)) from
  unnest(array['anon','authenticated']) r, unnest(array['guide_auth_attempts_id_seq','guide_events_id_seq']) q, unnest(array['usage','select','update']) p
union all
select 'bad token is refused', (public.guide_thread_v1(repeat('0', 64)))->>'reason' = 'session';
rollback;
