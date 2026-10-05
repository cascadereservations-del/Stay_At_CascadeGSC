-- Session 71, lane sign-in: release staff_signin_list_20261005. D-303.2: the Cascade Staff sign-in screen picks a name from a dropdown
-- instead of typing it, so it needs the list of active staff BEFORE anyone is signed in. One anon-callable security definer RPC.
--   staff_signin_list_v1()  returns (label, handle, kind) for every staff account that can sign in today, ordered by label:
--     label   the display name the admin dashboard shows on Settings > Staff: auth.users app_metadata.display_name (staff-users
--             'list' reads exactly that), then user_metadata.display_name (staff-users sets that one on rename), then the e-mail's
--             local part with dots turned to spaces and initcap (the same fallback staff-users and the app use).
--     handle  the Auth e-mail the screen signs in with: slug@staff.cascade.invalid for a PIN account, the owner's or admin's own
--             mailbox for a password account. This is the one thing a PIN or password screen cannot work without.
--     kind    'pin' when the e-mail ends '@staff.cascade.invalid' (the checklist's accounts: password '8888' + 4-digit PIN),
--             else 'password'.
--   Active = a staff_access_profiles row with disabled_at null, whose Auth user exists, is not deleted and is not banned
--   (staff-users disable sets disabled_at AND an Auth ban; either one excludes the account).
--   No role, no user id, no phone: nothing beyond the three columns. The list is public by design (D-303.2); the PIN or password is
--   what protects the account, and Supabase Auth rate-limits sign-in attempts.
-- Expand only: one new function, no table, column or data change.

begin;

create or replace function public.staff_signin_list_v1()
returns table (label text, handle text, kind text)
language sql stable security definer set search_path to '' as $$
  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''),
                  nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(u.email, '@', 1), '.', ' '))) as label,
         lower(u.email) as handle,
         case when lower(u.email) like '%@staff.cascade.invalid' then 'pin' else 'password' end as kind
    from public.staff_access_profiles p
    join auth.users u on u.id = p.user_id
   where p.disabled_at is null
     and u.deleted_at is null
     and (u.banned_until is null or u.banned_until <= now())
     and u.email is not null and u.email <> ''
   order by 1, 2;
$$;

revoke all on function public.staff_signin_list_v1() from public;
grant execute on function public.staff_signin_list_v1() to anon, authenticated;

comment on function public.staff_signin_list_v1() is
  'D-303.2: names for the Cascade Staff sign-in dropdown. Active, non-disabled staff only; (label, handle, kind pin|password). No roles, no ids.';

commit;
