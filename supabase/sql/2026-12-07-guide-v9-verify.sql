-- verify_20261207_guide_v9_secrets.sql: read-only forward checks after the release (run with the read-only runner).
-- Every row must say ok = true (10 rows). Same queries as forward_verification in supabase/releases/20261207_guide_v9_secrets.release.json. Prints no setting value.
begin transaction read only;
select 'staff_sessions_table_rls_on' as check, (select coalesce((select c.relrowsecurity from pg_class c where c.oid = to_regclass('public.guide_staff_sessions')), false)) as ok
union all
select 'staff_sessions_no_client_privileges' as check, (select to_regclass('public.guide_staff_sessions') is not null and not exists (select 1 from unnest(array['anon','authenticated','service_role']) r, unnest(array['select','insert','update','delete','truncate','references','trigger']) p where has_table_privilege(r, 'public.guide_staff_sessions', p))) as ok
union all
select 'three_functions_definer_search_path_pinned' as check, (select count(*) = 3 and bool_and(p.prosecdef and p.proconfig @> array['search_path=""']) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('guide_staff_session_v1','guide_secrets_v1','get_public_settings')) as ok
union all
select 'anon_and_authenticated_execute_service_role_not' as check, (select bool_and(has_function_privilege('anon', f, 'execute') and has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('service_role', f, 'execute')) from unnest(array['public.guide_staff_session_v1(text,text)','public.guide_secrets_v1(text)','public.get_public_settings()']::regprocedure[]) f) as ok
union all
select 'public_has_no_execute' as check, (select not exists (select 1 from unnest(array['public.guide_staff_session_v1(text,text)','public.guide_secrets_v1(text)','public.get_public_settings()']::regprocedure[]) f join pg_proc p on p.oid = f cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)) as ok
union all
select 'mint_lock_timeout_and_read_functions_stable' as check, (select (select p.proconfig @> array['lock_timeout=2s'] and p.provolatile = 'v' from pg_proc p where p.oid = 'public.guide_staff_session_v1(text,text)'::regprocedure) and (select p.provolatile = 's' from pg_proc p where p.oid = 'public.guide_secrets_v1(text)'::regprocedure) and (select p.provolatile = 's' from pg_proc p where p.oid = 'public.get_public_settings()'::regprocedure)) as ok
union all
select 'bad_token_refused' as check, (select public.guide_secrets_v1(repeat('0', 64)) = '{"ok": false}'::jsonb and public.guide_secrets_v1(null) = '{"ok": false}'::jsonb) as ok
union all
select 'public_settings_whitelist_only' as check, (select (select count(*) from jsonb_object_keys(public.get_public_settings()) k where k <> all (array['wifi_ssid','house_times','min_nights','max_nights','review_airbnb_url','review_facebook_url','review_google_url','property_lat','property_lng','concierge_mode'])) = 0 and not jsonb_exists(public.get_public_settings(), 'wifi_password') and not jsonb_exists(public.get_public_settings(), 'admin_pin_hash') and not jsonb_exists(public.get_public_settings(), 'onground_phone')) as ok
union all
select 'staff_sessions_within_bound' as check, (select (select count(*) from public.guide_staff_sessions) <= 50) as ok
union all
select 'weather_warm_job_scheduled' as check, (select case when to_regclass('cron.job') is null then true else (xpath('/row/c/text()', query_to_xml('select count(*) as c from cron.job where jobname = ''weather-proxy-warm'' and schedule = ''*/10 * * * *'' and command like ''%/functions/v1/weather-proxy%'' and command like ''%net.http_get%''', false, true, '')))[1]::text::int = 1 end) as ok;
rollback;
