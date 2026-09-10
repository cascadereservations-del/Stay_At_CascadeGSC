-- A free-text operational note per staff login.
--
-- Lloyd asked for the current PIN to be shown when editing a staff member. That
-- is not possible: Supabase stores it bcrypt-hashed and there is nothing to read
-- back. Offered the recoverable alternatives, he chose a note that deliberately
-- holds no PINs -- context like "uses her daughter's phone" or "prefers Tagalog"
-- -- so the credential stays out of storage entirely.
--
-- Why a column rather than user_metadata, which staff-users already writes:
-- both user_metadata and app_metadata travel in the user's own JWT, so the staff
-- member could read any note written about them. These notes are the operator's,
-- not the subject's. staff_access_profiles is admin-read only and the edge
-- function reaches it with the service role, so a note here stays with the
-- people managing the roster.
--
-- Deliberately NOT constrained to exclude digits. A rule that tried to keep PINs
-- out would be trivially evaded and would block legitimate notes ("arrives 7am",
-- "unit 3"). The guarantee here is organisational, and it is recorded in D-059.

alter table public.staff_access_profiles
  add column if not exists note text;

comment on column public.staff_access_profiles.note is
  'Operator-only free-text note about this staff login (shift habits, phone sharing, language). Never store a PIN or password here - the credential is bcrypt-hashed in auth.users by design, and this column is not protected to credential standard. See D-059.';

do $$
declare
  v_count integer;
begin
  select count(*) into v_count
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'staff_access_profiles'
    and column_name = 'note'
    and data_type = 'text';
  if v_count <> 1 then
    raise exception 'note column was not created as text (found % matching columns)', v_count;
  end if;

  -- The column must be nullable: every existing row predates it.
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'staff_access_profiles'
      and column_name = 'note' and is_nullable = 'NO'
  ) then
    raise exception 'note column must be nullable';
  end if;

  raise notice 'staff_access_profiles.note added';
end $$;
