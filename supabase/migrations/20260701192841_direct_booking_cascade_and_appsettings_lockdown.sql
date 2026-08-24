
-- 1) Private secrets store (RLS on, NO policies => anon/authenticated cannot read;
--    only bypass-RLS roles and SECURITY DEFINER functions owned by postgres can).
CREATE TABLE IF NOT EXISTS public.app_secrets (
  key   text PRIMARY KEY,
  value text NOT NULL
);
ALTER TABLE public.app_secrets ENABLE ROW LEVEL SECURITY;

INSERT INTO public.app_secrets(key, value) VALUES
  ('EMAIL_RELAY_URL',   'https://script.google.com/macros/s/AKfycbwwuy3IGREshot9Lbksu5McHIqD2DJtLZKr-tDWESENPj7om8CodV-8nlLpG02HCxHV/exec'),
  ('EMAIL_RELAY_TOKEN', '1M4Q2R5Hm-3nHoLdPrt8pxFWbeGfG-f-kuMML6RU5Hrpom_j')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- 2) Cascade: whenever a direct_booking transaction's status changes, keep the
--    booking_inquiry and calendar hold in sync. Email the guest ONLY when the
--    booking was not already confirmed by approve-booking (prevents double email
--    on the Telegram/email path, which sets booking_inquiries first).
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
                         'receipt_url', coalesce(v_bk.receipt_image_path, '')
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

DROP TRIGGER IF EXISTS trg_direct_booking_cascade ON public.transactions;
CREATE TRIGGER trg_direct_booking_cascade
AFTER UPDATE OF status ON public.transactions
FOR EACH ROW
WHEN (NEW.source = 'direct_booking')
EXECUTE FUNCTION public.fn_direct_booking_cascade();

-- 3) Security: remove anon write access to app_settings (public site's anon key
--    could otherwise INSERT/UPDATE settings like deposit_percent or airbnb_ical_url).
DROP POLICY IF EXISTS "anon insert settings" ON public.app_settings;
DROP POLICY IF EXISTS "anon update settings" ON public.app_settings;
;
