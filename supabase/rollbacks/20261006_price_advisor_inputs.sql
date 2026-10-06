-- Compensating rollback for release price_advisor_inputs_20261006 (session 72).
-- The release adds one read-only function and changes no data, so rolling back is dropping it. Roll the admin dashboard back too
-- (the Price advisor page calls it and shows a plain error without it).
begin;
drop function if exists public.price_advisor_inputs_v1(uuid, date, date);
commit;
