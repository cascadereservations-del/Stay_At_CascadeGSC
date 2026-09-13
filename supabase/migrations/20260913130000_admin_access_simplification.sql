-- Admin access simplification (D-094, Lloyd 2026-09-13).
--
-- Three people use these tools. The two-factor (aal2) requirement on finance
-- and staff actions was over-engineering for an internal admin: it produced a
-- second sign-in step nobody wanted, and every finance screen showed "two-factor
-- required" to the owner on a password session. The rule is removed server-side
-- here; the client stops asking for the authenticator code in the same release.
--
-- The second problem: the new admin reads eight tables that had RLS policies but
-- no table-level GRANT to authenticated (the legacy admin never read them
-- directly), and four of them had no read policy for named staff at all. Every
-- read below is scoped by the staff profile (current_staff_authorized), so a
-- named cleaner sees only the property she is assigned to and never finance.
--
-- Additive: two function bodies replaced (signatures unchanged), grants and
-- policies added. Nothing dropped.

-- 1. Authorisation no longer depends on the assurance level. p_aal stays in the
--    signature so every caller (current_staff_authorized, RLS policies, tests)
--    keeps compiling; it is simply ignored.
create or replace function public.staff_access_allowed(
  p_role text,p_action text,p_disabled_at timestamptz,p_aal text
) returns boolean language sql immutable set search_path='' as $$
  select case
    when p_disabled_at is not null then false
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
comment on function public.staff_access_allowed(text,text,timestamptz,text) is
  'Role/action matrix for named staff. p_aal is ignored since D-094 (2026-09-13): a password session is sufficient for every action.';

create or replace function public.management_owner_authorized(p_property_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.staff_access_profiles p
    where p.user_id=auth.uid() and p.role='owner' and p.disabled_at is null
      and (p.sessions_revoked_after is null
        or to_timestamp(coalesce((auth.jwt()->>'iat')::bigint,0))>p.sessions_revoked_after)
      and exists(select 1 from public.properties x where x.id=p_property_id)
  );
$$;

-- 2. Table grants the admin's read adapters need. RLS stays on; the policies
--    below and the existing owner/admin policies decide what a row-level read
--    returns.
grant select on
  public.airbnb_reservations, public.booking_inquiries, public.calendar_events, public.calendar_sync_log,
  public.booking_decisions, public.concierge_handoffs, public.job_heartbeats, public.staff_access_audit
to authenticated;

alter table public.airbnb_reservations enable row level security;
alter table public.booking_inquiries enable row level security;
alter table public.calendar_events enable row level security;
alter table public.calendar_sync_log enable row level security;
alter table public.booking_decisions enable row level security;
alter table public.concierge_handoffs enable row level security;
alter table public.job_heartbeats enable row level security;
alter table public.staff_access_audit enable row level security;

-- 3. Named-staff read policies (property scoped where the table has a property).
drop policy if exists airbnb_reservations_staff_read on public.airbnb_reservations;
create policy airbnb_reservations_staff_read on public.airbnb_reservations for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

drop policy if exists booking_inquiries_staff_read on public.booking_inquiries;
create policy booking_inquiries_staff_read on public.booking_inquiries for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

drop policy if exists calendar_events_staff_read on public.calendar_events;
create policy calendar_events_staff_read on public.calendar_events for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

drop policy if exists calendar_sync_log_staff_read on public.calendar_sync_log;
create policy calendar_sync_log_staff_read on public.calendar_sync_log for select to authenticated
  using (public.current_staff_authorized('read_operations', property_id));

drop policy if exists booking_decisions_staff_read on public.booking_decisions;
create policy booking_decisions_staff_read on public.booking_decisions for select to authenticated
  using (exists (select 1 from public.booking_inquiries i where i.id = booking_id and public.current_staff_authorized('read_operations', i.property_id)));

-- No property column on these two: any active named staff member may read.
-- The check runs as a SECURITY DEFINER helper because the caller has no grant
-- on staff_access_profiles (found by pgTAP on the rehearsal copy).
create or replace function public.current_staff_active(p_roles text[] default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.staff_access_profiles p
    where p.user_id = auth.uid() and p.disabled_at is null
      and (p_roles is null or p.role = any (p_roles))
      and (p.sessions_revoked_after is null
        or to_timestamp(coalesce((auth.jwt()->>'iat')::bigint, 0)) > p.sessions_revoked_after)
  );
$$;
revoke all on function public.current_staff_active(text[]) from public, anon, service_role;
grant execute on function public.current_staff_active(text[]) to authenticated;

drop policy if exists job_heartbeats_staff_read on public.job_heartbeats;
create policy job_heartbeats_staff_read on public.job_heartbeats for select to authenticated
  using (public.current_staff_active());

drop policy if exists concierge_handoffs_staff_read on public.concierge_handoffs;
create policy concierge_handoffs_staff_read on public.concierge_handoffs for select to authenticated
  using (public.current_staff_active(array['owner','admin']));

drop policy if exists staff_access_audit_manage_read on public.staff_access_audit;
create policy staff_access_audit_manage_read on public.staff_access_audit for select to authenticated
  using (public.current_staff_authorized('manage_staff'));
