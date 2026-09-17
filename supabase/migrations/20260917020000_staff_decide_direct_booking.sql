-- Dashboard Confirm / Decline for direct bookings (session 29, D-171 / K17). The admin app calls
-- decide_direct_booking as `authenticated`, but that function is granted to service_role only and has no
-- staff check of its own (the gate was designed to sit in front of it: approve-booking v7, the Telegram
-- tap). This definer is that gate for a signed-in staff session: it checks approve_payment for the
-- booking's property with the caller's own JWT, then runs the same decide_direct_booking. The Finance
-- review requirement is unchanged (decide_direct_booking still refuses without a matching final review).
begin;

create or replace function public.staff_decide_direct_booking_v1(
  p_booking_id uuid, p_action text, p_idempotency_key text, p_finance_review_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_property uuid;
begin
  select property_id into v_property from public.booking_inquiries where id = p_booking_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'booking not found';
  end if;
  if not coalesce(public.current_staff_authorized('approve_payment', v_property), false) then
    raise exception using errcode = '42501', message = 'approve_payment is required to decide a direct booking';
  end if;
  return public.decide_direct_booking(p_booking_id, p_action, p_idempotency_key, p_finance_review_id);
end $$;
comment on function public.staff_decide_direct_booking_v1(uuid, text, text, uuid) is
  'Staff-session gate in front of decide_direct_booking (session 29, D-171): approve_payment on the booking''s property, then the same decision transaction.';
revoke all on function public.staff_decide_direct_booking_v1(uuid, text, text, uuid) from public, anon;
grant execute on function public.staff_decide_direct_booking_v1(uuid, text, text, uuid) to authenticated;

-- The inner decision stays behind its gates. Production already has exactly this (verified 2026-09-17:
-- service_role only), so these two lines change nothing there; they make the invariant explicit and hold
-- in a --no-acl restore, where the original revoke is missing.
revoke all on function public.decide_direct_booking(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.decide_direct_booking(uuid, text, text, uuid) to service_role;

commit;
