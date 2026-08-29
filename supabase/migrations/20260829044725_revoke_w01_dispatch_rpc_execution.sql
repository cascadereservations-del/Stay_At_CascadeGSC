-- Production hotfix for installations where the W01 trigger migration was
-- already applied before its trigger-only permission boundary was added.
revoke all on function public.dispatch_w01_booking_requested()
  from public, anon, authenticated, service_role;

comment on function public.dispatch_w01_booking_requested() is
  'Trigger-only W01 dispatcher. Not executable through PostgREST roles.';
