
-- property_id (convention: every operational table)
ALTER TABLE public.booking_inquiries
  ADD COLUMN IF NOT EXISTS property_id uuid
    NOT NULL DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
    REFERENCES public.properties(id);

-- guest_id (CRM link — nullable, set at submission, used for repeat-guest lookup)
ALTER TABLE public.booking_inquiries
  ADD COLUMN IF NOT EXISTS guest_id uuid REFERENCES public.guests(id);

-- updated_at (standard column — was missing)
ALTER TABLE public.booking_inquiries
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE TRIGGER set_booking_inquiries_updated_at
  BEFORE UPDATE ON public.booking_inquiries
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX idx_booking_inquiries_guest ON public.booking_inquiries (guest_id) WHERE guest_id IS NOT NULL;
CREATE INDEX idx_booking_inquiries_dates ON public.booking_inquiries (checkin_date, checkout_date);
CREATE INDEX idx_booking_inquiries_status ON public.booking_inquiries (status);
;
