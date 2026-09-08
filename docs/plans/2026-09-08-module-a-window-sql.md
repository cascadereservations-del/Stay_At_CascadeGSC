# Module A window SQL (run in the Supabase SQL editor, database-owner session)

No UUIDs or e-mails are written here; every identity is resolved by a subquery at run time. Run each block only at its step in `2026-09-08-module-a-lean-recut.md` §5, after the four migrations are live.

## S3a — owner bootstrap (the existing `owner` dashboard login)

```sql
select public.bootstrap_cascade_owner(
  (select id from auth.users where raw_app_meta_data->>'role' = 'owner'),
  array['6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid],
  'Initial named Cascade owner (Module A window)'
);
```

## S3b — admin profile (the existing `admin` dashboard login)

```sql
with u as (select id from auth.users where raw_app_meta_data->>'role' = 'admin')
, prof as (
  insert into public.staff_access_profiles(user_id, role, sessions_revoked_after)
  select id, 'admin', now() from u returning user_id
)
, scope as (
  insert into public.staff_property_access(user_id, property_id)
  select user_id, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid from prof returning user_id
)
, meta as (
  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb) || jsonb_build_object(
    'role','admin','property_ids', jsonb_build_array('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'),
    'cascade_disabled', false, 'cascade_sessions_revoked_after', now()::text
  ), updated_at = now() where id = (select user_id from scope) returning id
)
insert into public.staff_access_audit(actor_user_id, target_user_id, action, after_state, reason)
select null, id, 'created', jsonb_build_object('role','admin','property_ids', array['6ae230f4-c189-4547-84b1-cb6e0b2cc9bd']), 'Existing admin dashboard login (Module A window)' from meta;
```

## S3c — Honey (create the Auth user first: Authentication → Users → Add user → e-mail + password, Auto Confirm on)

Replace `HONEY_EMAIL_HERE` in the editor only; do not save this file with it filled in.

```sql
with u as (select id from auth.users where lower(email) = lower('HONEY_EMAIL_HERE'))
, prof as (
  insert into public.staff_access_profiles(user_id, role)
  select id, 'cleaner' from u returning user_id
)
, scope as (
  insert into public.staff_property_access(user_id, property_id)
  select user_id, '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid from prof returning user_id
)
, meta as (
  update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb) || jsonb_build_object(
    'role','cleaner','property_ids', jsonb_build_array('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'),
    'cascade_disabled', false
  ), updated_at = now() where id = (select user_id from scope) returning id
)
insert into public.staff_access_audit(actor_user_id, target_user_id, action, after_state, reason)
select null, id, 'created', jsonb_build_object('role','cleaner','property_ids', array['6ae230f4-c189-4547-84b1-cb6e0b2cc9bd']), 'Named cleaner Honey (Module A window)' from meta;
```

Honey's profile deliberately has no `sessions_revoked_after`, so her first sign-in works immediately. The owner and admin rows get `now()`, so their dashboard sessions must be re-signed-in once after this (a fresh JWT `iat`).

## Check (expect 3 rows: owner, admin, cleaner)

```sql
select p.role, p.disabled_at, count(s.property_id) as properties
from public.staff_access_profiles p left join public.staff_property_access s on s.user_id = p.user_id
group by p.user_id, p.role, p.disabled_at order by p.role;
```

## Later — disable or re-scope Honey without the app (until owner TOTP is used for `manage_staff`)

```sql
update public.staff_access_profiles set disabled_at = now(), sessions_revoked_after = now(), updated_at = now()
where user_id = (select id from auth.users where lower(email) = lower('HONEY_EMAIL_HERE'));
```
Then end her sessions in Authentication → Users → … → Sign out user.
