-- 20261022000000_s89_signin_pin.sql
-- Session 89, release s89_signin_pin_20261022. The sign-in screen shows the PIN pad for anyone whose Auth app_metadata says signin_kind = 'pin',
-- not only for @staff.cascade.invalid addresses (an admin with a real e-mail can now hold a 4-digit PIN set from the admin Staff page).
-- staff_signin_list_v2() keeps its signature, grants, filters, label, handle, team and order; only the kind expression changes.
-- Backfill: the one admin whose display_name is 'Lloyd' gets signin_kind = 'pin' (guarded lookup, exactly one row or the migration aborts).
-- Rollback: supabase/rollbacks/20261022_s89_signin_pin.sql

begin;

create or replace function public.staff_signin_list_v2()
returns table (label text, handle text, kind text, team text)
language sql stable security definer set search_path to '' as $$
  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''),
                  nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(u.email, '@', 1), '.', ' '))) as label,
         lower(u.email) as handle,
         case when u.raw_app_meta_data ->> 'signin_kind' = 'pin' or lower(u.email) like '%@staff.cascade.invalid' then 'pin' else 'password' end as kind,
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
  'S88/S89: names for the Cascade Staff sign-in screen, grouped. (label, handle, kind pin|password, team staff|admin). kind is pin when app_metadata.signin_kind = pin or the e-mail is a staff-domain login. Active staff only. No roles, no ids.';

do $$
declare n int;
begin
  select count(*) into n
    from auth.users u join public.staff_access_profiles p on p.user_id = u.id
   where u.raw_app_meta_data ->> 'display_name' = 'Lloyd' and p.role = 'admin';
  if n <> 1 then
    raise exception 's89_signin_pin: expected exactly one admin named Lloyd, found %', n;
  end if;
  update auth.users u
     set raw_app_meta_data = coalesce(u.raw_app_meta_data, '{}'::jsonb) || '{"signin_kind":"pin"}'::jsonb
    from public.staff_access_profiles p
   where p.user_id = u.id and u.raw_app_meta_data ->> 'display_name' = 'Lloyd' and p.role = 'admin';
end $$;

commit;
