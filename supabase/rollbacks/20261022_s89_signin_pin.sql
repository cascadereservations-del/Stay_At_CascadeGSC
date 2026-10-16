-- Compensating rollback for release s89_signin_pin_20261022 (session 89).
-- Restores the s88 staff_signin_list_v2 body byte-for-byte and removes the signin_kind key from every user.
-- The PIN itself (the password in Auth) is untouched; roll the Staff app back first if it should stop treating that user as a PIN user.
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

update auth.users set raw_app_meta_data = raw_app_meta_data - 'signin_kind' where raw_app_meta_data ? 'signin_kind';

commit;
