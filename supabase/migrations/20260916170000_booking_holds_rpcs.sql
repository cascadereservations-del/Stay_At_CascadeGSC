-- Hold-before-pay (session 26, D-162 correction): the hold is a booking_holds row, which the
-- lifecycle guard already honours (active holds block a conflicting confirmation; confirm converts,
-- cancel releases). booking_holds is RLS-on with no service_role grant, so Edge Functions get two
-- SECURITY DEFINER entry points and nothing else changes.
--   open_booking_hold_v1(booking_id, hours)  -> opens (or returns) the active hold for a pending
--                                                direct request; used by submit-booking.
--   expire_booking_holds_v1()                -> for every active hold past expires_at whose request
--                                                is still pending with NO receipt: void the ledger
--                                                row, cancel the calendar hold, mark the request
--                                                expired and the hold expired; returns the rows so
--                                                the caller can notify. A request with a receipt is
--                                                never touched (Finance is reviewing it).
begin;

create or replace function public.open_booking_hold_v1(p_booking_id uuid, p_hours integer default 24)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare b public.booking_inquiries%rowtype; v_exp timestamptz; v_id uuid;
begin
  select * into b from public.booking_inquiries where id = p_booking_id;
  if b.id is null or b.source <> 'direct' or b.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'not_pending_direct');
  end if;
  v_exp := now() + make_interval(hours => greatest(1, least(p_hours, 168)));
  insert into public.booking_holds (property_id, booking_id, checkin_date, checkout_date, expires_at, status, idempotency_key)
  values (b.property_id, b.id, b.checkin_date, b.checkout_date, v_exp, 'active', 'hold:' || b.id::text)
  on conflict (idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then
    select id, expires_at into v_id, v_exp from public.booking_holds where idempotency_key = 'hold:' || b.id::text;
  end if;
  return jsonb_build_object('ok', true, 'hold_id', v_id, 'expires_at', v_exp);
end $$;
revoke all on function public.open_booking_hold_v1(uuid, integer) from public, anon, authenticated;
grant execute on function public.open_booking_hold_v1(uuid, integer) to service_role;

create or replace function public.expire_booking_holds_v1()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r record; v_out jsonb := '[]'::jsonb;
begin
  for r in
    select h.id as hold_id, b.*
      from public.booking_holds h
      join public.booking_inquiries b on b.id = h.booking_id
     where h.status = 'active' and h.expires_at < now()
       and b.source = 'direct' and b.status = 'pending' and b.receipt_image_path is null
     order by h.expires_at
  loop
    -- Order matters: voiding the income row makes fn_direct_booking_cascade flip the request to
    -- cancelled, so the request's own status is written last (expired is terminal in the guard).
    update public.transactions set status = 'void' where booking_id = r.id and status = 'pending_review';
    update public.calendar_events set status = 'cancelled' where uid = 'direct:' || r.id::text and status = 'blocked';
    update public.booking_inquiries set status = 'expired' where id = r.id and status in ('pending', 'cancelled');
    update public.booking_holds set status = 'expired', updated_at = now() where id = r.hold_id;
    v_out := v_out || jsonb_build_object('id', r.id, 'guest_name', r.guest_name, 'guest_email', r.guest_email, 'guest_phone', r.guest_phone,
      'checkin_date', r.checkin_date, 'checkout_date', r.checkout_date, 'deposit_amount', r.deposit_amount, 'total_amount', r.total_amount, 'submitted_at', r.submitted_at);
  end loop;
  return v_out;
end $$;
revoke all on function public.expire_booking_holds_v1() from public, anon, authenticated;
grant execute on function public.expire_booking_holds_v1() to service_role;

commit;
