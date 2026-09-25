-- 20260925040000_supersede_pending_hold.sql
-- Session 49 (Opus 5): release supersede_pending_hold_20260925 - SPEC-30 (D-233, refined by D-239).
--
-- A guest who changes dates on the booking site used to leave their first request holding the calendar for 24 h,
-- and was refused by their own hold when the new dates overlapped it. submit-booking now calls this function first.
--
-- It releases the guest's OWN pending, receipt-less direct requests from the last 24 hours, doing exactly what
-- expire_booking_holds_v1 does (same four writes, same order: voiding the income row lets fn_direct_booking_cascade
-- cancel the request and its calendar row; the lifecycle guard releases the hold on the move to cancelled), with
-- status cancelled and a system note. Two refinements over the spec sketch (D-239):
--   * it releases NOTHING unless the new dates are free once those requests are gone (the same overlap rule as
--     check_availability), so a guest who moves to dates somebody else holds keeps the earlier hold and gets the
--     usual 409 - releasing first would have cost them both;
--   * "the guest's own" means the same phone AND the same e-mail (or both without an e-mail), not either: with
--     either, anyone who knew a guest's e-mail could cancel that guest's unpaid hold by submitting under it.
-- A request with a receipt is never touched; the hourly expiry owns anything older than 24 hours.

begin;

create or replace function public.supersede_pending_direct_requests_v1(
  p_property_id uuid,
  p_email       text,
  p_phone       text,
  p_checkin     date,
  p_checkout    date
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_email text := lower(nullif(btrim(coalesce(p_email, '')), ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_ids   uuid[];
  v_id    uuid;
  v_done  uuid[] := '{}';
begin
  if v_phone is null or p_checkin is null or p_checkout is null or p_checkin >= p_checkout then
    return jsonb_build_object('superseded', '[]'::jsonb, 'reason', 'not_applicable');
  end if;

  select coalesce(array_agg(b.id order by b.submitted_at), '{}') into v_ids
    from public.booking_inquiries b
   where b.property_id = p_property_id
     and b.source = 'direct' and b.status = 'pending'
     and b.receipt_image_path is null
     and b.submitted_at > now() - interval '24 hours'
     and btrim(coalesce(b.guest_phone, '')) = v_phone
     and lower(nullif(btrim(coalesce(b.guest_email, '')), '')) is not distinct from v_email;

  if cardinality(v_ids) = 0 then
    return jsonb_build_object('superseded', '[]'::jsonb, 'reason', 'none');
  end if;

  -- check_availability's own overlap rule, with the guest's own requests left out.
  if exists (
    select 1 from public.calendar_events c
     where c.property_id = p_property_id
       and c.status not in ('cancelled')
       and c.checkin_date < p_checkout and c.checkout_date > p_checkin
       and c.uid <> all (select 'direct:' || x::text from unnest(v_ids) x)
  ) then
    return jsonb_build_object('superseded', '[]'::jsonb, 'reason', 'new_dates_taken');
  end if;

  foreach v_id in array v_ids loop
    update public.transactions set status = 'void' where booking_id = v_id and status = 'pending_review';
    update public.calendar_events set status = 'cancelled' where uid = 'direct:' || v_id::text and status = 'blocked';
    update public.booking_inquiries
       set status = 'cancelled',
           notes = concat_ws(E'\n', nullif(notes, ''), '[system] replaced by the guest''s later request')
     where id = v_id and status in ('pending', 'cancelled');
    update public.booking_holds set status = 'released', updated_at = now() where booking_id = v_id and status = 'active';
    v_done := v_done || v_id;
  end loop;

  return jsonb_build_object('superseded', to_jsonb(v_done), 'reason', 'released');
end;
$function$;

revoke all on function public.supersede_pending_direct_requests_v1(uuid, text, text, date, date) from public, anon, authenticated;
grant execute on function public.supersede_pending_direct_requests_v1(uuid, text, text, date, date) to service_role;

comment on function public.supersede_pending_direct_requests_v1(uuid, text, text, date, date) is
  'SPEC-30 (D-233, D-239): releases the same guest''s (phone AND e-mail) pending receipt-less direct requests from the last 24 h, as expire_booking_holds_v1 does, only when the new dates are then free. service_role only (submit-booking).';

commit;
