-- staff-users Edge Function runs as service_role and must be able to write the
-- staff tables. 20260828000400 granted service_role select only (insert on audit).
grant select, insert, update, delete on table public.staff_access_profiles to service_role;
grant select, insert, update, delete on table public.staff_property_access to service_role;
grant select, insert on table public.staff_access_audit to service_role;
