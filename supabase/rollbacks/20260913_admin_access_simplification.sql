-- Compensating rollback for release admin_access_simplification_20260913 (D-094).
-- Restores the aal2 rule in staff_access_allowed and management_owner_authorized
-- (bodies from 20260905040000 / 20260905070000) and removes the staff read
-- policies and grants added for the new admin. Safe at any time: no data is touched.
begin;
create or replace function public.staff_access_allowed(
  p_role text,p_action text,p_disabled_at timestamptz,p_aal text
) returns boolean language sql immutable set search_path='' as $$
  select case
    when p_disabled_at is not null then false
    when p_action in (
      'manage_staff','approve_payment','read_finance','manage_privacy','manage_booking',
      'approve_refund','publish_rate_policy','manage_guest_inbox'
    ) and p_aal is distinct from 'aal2' then false
    when p_role in ('owner','admin') then p_action in (
      'manage_staff','approve_payment','read_finance','read_operations','manage_operations',
      'inspect_cleaning','submit_cleaning','manage_inventory','manage_maintenance',
      'manage_privacy','manage_booking','approve_refund','publish_rate_policy','manage_guest_inbox'
    )
    when p_role='finance' then p_action in ('approve_payment','read_finance','read_operations','approve_refund')
    when p_role='inspector' then p_action in ('read_operations','inspect_cleaning','submit_cleaning')
    when p_role='cleaner' then p_action in ('read_operations','submit_cleaning')
    when p_role='maintenance' then p_action in ('read_operations','manage_maintenance')
    else false end;
$$;
create or replace function public.management_owner_authorized(p_property_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.staff_access_profiles p
    where p.user_id=auth.uid() and p.role='owner' and p.disabled_at is null
      and auth.jwt()->>'aal'='aal2'
      and (p.sessions_revoked_after is null
        or to_timestamp(coalesce((auth.jwt()->>'iat')::bigint,0))>p.sessions_revoked_after)
      and exists(select 1 from public.properties x where x.id=p_property_id)
  );
$$;
drop policy if exists airbnb_reservations_staff_read on public.airbnb_reservations;
drop policy if exists booking_inquiries_staff_read on public.booking_inquiries;
drop policy if exists calendar_events_staff_read on public.calendar_events;
drop policy if exists calendar_sync_log_staff_read on public.calendar_sync_log;
drop policy if exists booking_decisions_staff_read on public.booking_decisions;
drop policy if exists job_heartbeats_staff_read on public.job_heartbeats;
drop policy if exists concierge_handoffs_staff_read on public.concierge_handoffs;
drop policy if exists staff_access_audit_manage_read on public.staff_access_audit;
drop function if exists public.current_staff_active(text[]);
revoke select on
  public.airbnb_reservations, public.booking_inquiries, public.calendar_events, public.calendar_sync_log,
  public.booking_decisions, public.concierge_handoffs, public.job_heartbeats, public.staff_access_audit
from authenticated;
commit;
