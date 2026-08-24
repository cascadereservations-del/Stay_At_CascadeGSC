
CREATE TABLE public.guests (
  id           uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  property_id  uuid        NOT NULL DEFAULT '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' REFERENCES public.properties(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  name         text        NOT NULL,
  phone        text,
  email        text,
  source       text        NOT NULL DEFAULT 'direct' CHECK (source IN ('direct','airbnb','manual')),
  notes        text,
  is_active    boolean     NOT NULL DEFAULT true
);

CREATE TRIGGER set_guests_updated_at
  BEFORE UPDATE ON public.guests
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Deduplicate by phone per property (nulls not matched — multiple null phones allowed)
CREATE UNIQUE INDEX idx_guests_phone_unique ON public.guests (property_id, phone) WHERE phone IS NOT NULL;
CREATE INDEX idx_guests_email ON public.guests (property_id, email) WHERE email IS NOT NULL;

ALTER TABLE public.guests ENABLE ROW LEVEL SECURITY;

CREATE POLICY guests_owner_admin_all ON public.guests
  FOR ALL TO authenticated
  USING      ( (auth.jwt() -> 'user_metadata' ->> 'role') IN ('owner','admin') )
  WITH CHECK ( (auth.jwt() -> 'user_metadata' ->> 'role') IN ('owner','admin') );

COMMENT ON TABLE public.guests IS 'CRM foundation — one row per unique guest (deduped by phone). Direct bookings create/link a guest row via submit-booking Edge Function.';
;
