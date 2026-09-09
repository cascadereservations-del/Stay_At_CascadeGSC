-- guard_direct_booking_lifecycle_transition is a TRIGGER function. Postgres
-- grants EXECUTE to PUBLIC by default, so PostgREST exposed it at
-- /rest/v1/rpc/guard_direct_booking_lifecycle_transition, callable by anon and
-- authenticated as SECURITY DEFINER. Invoking it outside a trigger context
-- errors on the undefined trigger record rather than doing damage, but a
-- definer-rights trigger body has no business being reachable from the API.
-- This mirrors 20260829174048, which did the same for fn_direct_booking_cascade.
revoke execute on function public.guard_direct_booking_lifecycle_transition()
  from public, anon, authenticated, service_role;
