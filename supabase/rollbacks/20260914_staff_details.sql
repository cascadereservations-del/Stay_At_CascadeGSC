-- Compensating rollback for 20260914230000_staff_details.sql.
-- Refuses while any staff_details row holds real data, so a rollback never silently discards
-- a staff member's contact, ID, or fee-structure record.
begin;

do $$
begin
  if exists (
    select 1 from public.staff_details
    where contact_number is not null or alternate_contact is not null or address is not null
       or id_type is not null or id_number is not null or id_drive_url is not null
       or emergency_contact_name is not null or emergency_contact_number is not null
       or start_date is not null or fee_turnover is not null or fee_transport is not null or fee_deep_clean is not null
  ) then
    raise exception 'staff_details holds real data; clear or migrate it out before rolling back';
  end if;
end $$;

drop function if exists public.list_staff_details_v1();
drop function if exists public.save_staff_details_v1(uuid, jsonb, integer, text);
drop table if exists public.staff_details_history;
drop table if exists public.staff_details;

commit;
