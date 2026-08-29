-- This routine is executed only by trg_direct_booking_cascade. PostgreSQL
-- triggers do not require callers to hold EXECUTE on the trigger function.
revoke all on function public.fn_direct_booking_cascade()
  from public, anon, authenticated, service_role;

comment on function public.fn_direct_booking_cascade() is
  'Trigger-only direct-booking cascade. Not executable through PostgREST roles.';
