-- Compensating rollback for release inquiry_one_tap_20261008 (session 76, SPEC-44).
-- Restores fn_direct_booking_cascade to its live body (md5(replace(prosrc, chr(13), '')) 934f4b40af823ca3e74b144698c3910e, read from
-- production 2026-10-08, search_path public), drops the income-confirm guard and the new functions.
-- KEPT on purpose: the repair rows (DIRECT: reservations, renamed/linked calendar rows, repair:bypass:<id> booking_decisions) and every
-- candidate, comparison, review and decision the one-tap RPCs wrote. They describe bookings that are confirmed; removing them would
-- re-open the gap the release closed. Admin, staff app and Telegram callers of the dropped RPCs must be rolled back first.
begin;

drop trigger if exists trg_guard_direct_booking_income_confirm on public.transactions;
drop function if exists public.guard_direct_booking_income_confirm();

CREATE OR REPLACE FUNCTION public.fn_direct_booking_cascade()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prev_status text;
  v_url         text;
  v_token       text;
  v_bk          public.booking_inquiries%ROWTYPE;
  v_ref         text;
  v_nights      int;
BEGIN
  IF NEW.booking_id IS NULL THEN RETURN NEW; END IF;

  IF NEW.status = 'confirmed' AND OLD.status IS DISTINCT FROM 'confirmed' THEN
    SELECT status INTO v_prev_status FROM public.booking_inquiries WHERE id = NEW.booking_id;

    UPDATE public.booking_inquiries
       SET status = 'confirmed'
     WHERE id = NEW.booking_id AND status <> 'confirmed';

    UPDATE public.calendar_events
       SET status = 'confirmed'
     WHERE uid = 'direct:' || NEW.booking_id::text AND status <> 'confirmed';

    -- Dashboard/manual path (booking was still pending) -> send the guest email.
    IF v_prev_status IS DISTINCT FROM 'confirmed' THEN
      SELECT value INTO v_url   FROM public.app_secrets WHERE key = 'EMAIL_RELAY_URL';
      SELECT value INTO v_token FROM public.app_secrets WHERE key = 'EMAIL_RELAY_TOKEN';
      IF v_url IS NOT NULL AND v_token IS NOT NULL THEN
        SELECT * INTO v_bk FROM public.booking_inquiries WHERE id = NEW.booking_id;
        IF v_bk.guest_email IS NOT NULL AND v_bk.guest_email <> '' THEN
          v_ref    := upper(left(NEW.booking_id::text, 8));
          v_nights := (v_bk.checkout_date - v_bk.checkin_date);
          PERFORM net.http_post(
            url     := v_url,
            body    := jsonb_build_object(
                         'action',      'confirmEmail',
                         'token',       v_token,
                         'ref',         v_ref,
                         'guest_name',  v_bk.guest_name,
                         'guest_email', v_bk.guest_email,
                         'guest_phone', coalesce(v_bk.guest_phone, ''),
                         'checkin',     v_bk.checkin_date::text,
                         'checkout',    v_bk.checkout_date::text,
                         'nights',      v_nights,
                         'pax',         coalesce(v_bk.pax, 1),
                         'total',       coalesce(v_bk.total_amount, 0),
                         'deposit',     coalesce(v_bk.deposit_amount, 0),
                         'receipt_url', coalesce(v_bk.receipt_image_path, ''),
                         'onground_phone', coalesce((select value #>> '{}' from public.app_settings where key = 'onground_phone'), '0991 853 8269')
                       ),
            headers := jsonb_build_object('Content-Type', 'application/json')
          );
        END IF;
      END IF;
    END IF;

  ELSIF NEW.status = 'void' AND OLD.status IS DISTINCT FROM 'void' THEN
    UPDATE public.booking_inquiries
       SET status = 'cancelled'
     WHERE id = NEW.booking_id AND status <> 'cancelled';
    UPDATE public.calendar_events
       SET status = 'cancelled'
     WHERE uid = 'direct:' || NEW.booking_id::text AND status <> 'cancelled';
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- never block the ledger update because of a cascade/email hiccup
  RAISE WARNING 'fn_direct_booking_cascade error: %', SQLERRM;
  RETURN NEW;
END;
$$;
revoke all on function public.fn_direct_booking_cascade() from public, anon, authenticated, service_role;

drop function if exists public.staff_confirm_direct_booking_v1(uuid, text, text, numeric, text, uuid, text);
drop function if exists public.telegram_confirm_direct_booking_v1(bigint, uuid, text, text, numeric, text, uuid, text);
drop function if exists public.staff_decline_direct_booking_v1(uuid, text, text);
drop function if exists public.staff_inquiry_payments_v1(uuid);
drop function if exists public.concierge_resume_cassy_v1(text);
drop function if exists public._confirm_direct_booking_core(uuid, uuid, text, text, numeric, text, uuid, text);
drop function if exists public._repair_bypass_confirmed_v1();

-- Check: select md5(replace(prosrc, chr(13), '')) = '934f4b40af823ca3e74b144698c3910e' from pg_proc
--         where oid = 'public.fn_direct_booking_cascade()'::regprocedure;   -> t
commit;
