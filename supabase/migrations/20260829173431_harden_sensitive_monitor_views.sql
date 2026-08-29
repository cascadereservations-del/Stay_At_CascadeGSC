-- These operational views expose guest, booking, and financial reconciliation
-- details. They are backend-only observability surfaces, not public API views.
-- security_invoker prevents the view owner from bypassing underlying table RLS.

alter view public.v_direct_bookings set (security_invoker = true);
alter view public.v_direct_state_desync set (security_invoker = true);
alter view public.v_status_desync_wide set (security_invoker = true);

revoke all on table public.v_direct_bookings from public, anon, authenticated;
revoke all on table public.v_direct_state_desync from public, anon, authenticated;
revoke all on table public.v_status_desync_wide from public, anon, authenticated;

grant select on table public.v_direct_bookings to service_role;
grant select on table public.v_direct_state_desync to service_role;
grant select on table public.v_status_desync_wide to service_role;

comment on view public.v_direct_bookings is
  'Backend-only direct-booking operations view; service_role access only.';
comment on view public.v_direct_state_desync is
  'Backend-only direct-booking reconciliation view; service_role access only.';
comment on view public.v_status_desync_wide is
  'Backend-only booking status reconciliation view; service_role access only.';
