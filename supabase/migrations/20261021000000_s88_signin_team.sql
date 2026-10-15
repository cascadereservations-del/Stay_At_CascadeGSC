-- 20261021000000_s88_signin_team.sql
-- Session 88, lane signin-team: release s88_signin_team_20261021. The Cascade Staff sign-in screen groups names into Staff and Admin.
-- staff_signin_list_v2() is staff_signin_list_v1() (same filters, same label, handle and kind, same order) plus team:
--   'admin' for the roles owner, admin and finance, 'staff' for every other role. Nothing else is exposed (no role, no user id).
-- Anon-callable on purpose (the sign-in screen is pre-auth), like v1. v1 stays unchanged so the old screen keeps working.
-- Expand only: one new function, no table, column or data change.
-- Rollback: supabase/rollbacks/20261021_s88_signin_team.sql

begin;

create or replace function public.staff_signin_list_v2()
returns table (label text, handle text, kind text, team text)
language sql stable security definer set search_path to '' as $$
  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''),
                  nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(u.email, '@', 1), '.', ' '))) as label,
         lower(u.email) as handle,
         case when lower(u.email) like '%@staff.cascade.invalid' then 'pin' else 'password' end as kind,
         case when p.role in ('owner', 'admin', 'finance') then 'admin' else 'staff' end as team
    from public.staff_access_profiles p
    join auth.users u on u.id = p.user_id
   where p.disabled_at is null
     and u.deleted_at is null
     and (u.banned_until is null or u.banned_until <= now())
     and u.email is not null and u.email <> ''
   order by 1, 2;
$$;

revoke all on function public.staff_signin_list_v2() from public;
grant execute on function public.staff_signin_list_v2() to anon, authenticated;

comment on function public.staff_signin_list_v2() is
  'S88: names for the Cascade Staff sign-in screen, grouped. (label, handle, kind pin|password, team staff|admin). Active staff only. No roles, no ids.';

commit;
