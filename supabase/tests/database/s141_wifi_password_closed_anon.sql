-- s141: 20261209000000 closes the wifi_password row of public.app_settings to the anon role (restrictive select policy), with its rollback. Everything rolls back.
-- Fixtures: a wifi_password row and a wifi_ssid row are inserted ONLY when absent, with the obvious fakes 'zz-pass' and 'zz-net'. On a production copy the real rows stay untouched
-- and are only counted or tested for presence, never selected as a value and never printed. bill_schedule is likewise inserted (fake) only when absent.
-- The migration and rollback statements are held verbatim in the temp table s141_sql (the release JSON pins the file hash, so a file edited without this copy changing is caught at the restamp).
-- NOT RUN in the build session (no database there): run it on a rehearsal restore before release.
begin;
select plan(22);

insert into public.app_settings(key, value)
select 'wifi_password', to_jsonb('zz-pass'::text) where not exists (select 1 from public.app_settings where key = 'wifi_password');
insert into public.app_settings(key, value)
select 'wifi_ssid', to_jsonb('zz-net'::text) where not exists (select 1 from public.app_settings where key = 'wifi_ssid');
insert into public.app_settings(key, value)
select 'bill_schedule', '{"zz":1}'::jsonb where not exists (select 1 from public.app_settings where key = 'bill_schedule');
insert into auth.users(id) values ('e1410000-0000-4000-8000-000000000141') on conflict (id) do nothing;
insert into public.staff_access_profiles(user_id, role) values ('e1410000-0000-4000-8000-000000000141', 'admin') on conflict do nothing;

create temp table s141_sql (name text primary key, body text not null) on commit drop;
insert into s141_sql values
('mig', $t$
do $g$
begin
  if to_regclass('public.app_settings') is null then
    raise exception 's141 wifi_password: public.app_settings is missing' using errcode = '55000';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.app_settings'::regclass) then
    raise exception 's141 wifi_password: row level security is not enabled on public.app_settings, so a policy would not close the row: enable RLS first' using errcode = '55000';
  end if;
end $g$;
drop policy if exists app_settings_wifi_password_closed_anon on public.app_settings;
create policy app_settings_wifi_password_closed_anon on public.app_settings as restrictive for select to anon using (key <> 'wifi_password');
$t$),
('rb', $t$
drop policy if exists app_settings_wifi_password_closed_anon on public.app_settings;
$t$);

-- the migration is applied (as the runner would): run it, and run it a second time (idempotent) ------------------------------------------------------------------------------------
select lives_ok((select body from s141_sql where name = 'mig'), 'migration statements run');
select lives_ok((select body from s141_sql where name = 'mig'), 'migration is idempotent: a second run also passes');

-- policy shape --------------------------------------------------------------------------------------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'app_settings' and policyname = 'app_settings_wifi_password_closed_anon'), 1, 'exactly one such policy');
select ok((select permissive = 'RESTRICTIVE' and cmd = 'SELECT' and roles = array['anon']::name[] and qual like '%wifi_password%'
             from pg_policies where schemaname = 'public' and tablename = 'app_settings' and policyname = 'app_settings_wifi_password_closed_anon'),
  'the policy is RESTRICTIVE, for SELECT, to anon only, and names wifi_password');
select ok((select relrowsecurity from pg_class where oid = 'public.app_settings'::regclass), 'RLS is on for app_settings');
select ok((select count(*) = 2 from pg_policies where schemaname = 'public' and tablename = 'app_settings' and policyname in ('app_settings_bill_schedule_closed_anon', 'app_settings_bill_schedule_closed_staff')),
  'the s127 restrictive bill_schedule policies are still there');
select ok(exists (select 1 from public.app_settings where key = 'wifi_password'), 'a wifi_password row exists (presence only, the value is never selected)');

-- anon ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
set local role anon;
select is((select count(*)::int from public.app_settings where key = 'wifi_password'), 0, 'anon selects 0 rows for key wifi_password');
select is((select count(*)::int from public.app_settings where key ilike '%wifi_pass%'), 0, 'anon selects 0 rows for a wifi_pass pattern either');
select is((select count(*)::int from public.app_settings where key = 'wifi_ssid'), 1, 'anon still selects wifi_ssid');
select is((select count(*)::int from public.app_settings where key = 'bill_schedule'), 0, 'anon still cannot select bill_schedule');
select ok((public.get_public_settings() ? 'wifi_ssid') and not (public.get_public_settings() ? 'wifi_password'),
  'get_public_settings() as anon still returns wifi_ssid and no wifi_password');
reset role;

-- authenticated staff -------------------------------------------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub','e1410000-0000-4000-8000-000000000141','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select is((select count(*)::int from public.app_settings where key = 'wifi_password'), 1, 'authenticated staff can still select the wifi_password row');
select is((select count(*)::int from public.app_settings where key = 'wifi_ssid'), 1, 'authenticated staff can still select wifi_ssid');
reset role;

-- the owner role and service_role (definer functions such as guide_secrets_v1 run as the owner) -------------------------------------------------------------------------------------
select ok(has_table_privilege('service_role', 'public.app_settings', 'select'), 'service_role keeps its table privilege (and bypasses RLS)');
select is((select count(*)::int from public.app_settings where key = 'wifi_password'), 1, 'the table owner still sees the wifi_password row (definer functions read it)');

-- rollback, twice (idempotent); the row is open to anon again; re-apply closes it again -------------------------------------------------------------------------------------------------
select lives_ok((select body from s141_sql where name = 'rb'), 'rollback statement runs');
select lives_ok((select body from s141_sql where name = 'rb'), 'rollback is idempotent: a second run also passes');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'app_settings' and policyname = 'app_settings_wifi_password_closed_anon'), 0, 'after the rollback the policy is gone');
set local role anon;
select is((select count(*)::int from public.app_settings where key = 'wifi_password'), 1, 'after the rollback anon reads the row again (state before this release)');
reset role;
select lives_ok((select body from s141_sql where name = 'mig'), 're-applying the migration works after a rollback');
set local role anon;
select is((select count(*)::int from public.app_settings where key = 'wifi_password'), 0, 'and anon is shut out again');
reset role;

select * from finish();
rollback;
