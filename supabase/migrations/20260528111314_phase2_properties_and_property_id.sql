
-- ─── properties table ────────────────────────────────────────────
CREATE TABLE public.properties (
  id          uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  name        text NOT NULL,
  address     text,
  city        text,
  country     text NOT NULL DEFAULT 'PH',
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now()
);

CREATE TRIGGER properties_set_updated_at
  BEFORE UPDATE ON public.properties
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.properties ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_select_active_properties" ON public.properties
  FOR SELECT TO anon USING (is_active = true);

CREATE POLICY "authenticated_all_properties" ON public.properties
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

INSERT INTO public.properties (name, address, city)
VALUES ('Cascade Bria', 'Block 47 Lot 39, General Santos City', 'General Santos City');

-- ─── property_id on cleaning_sessions ────────────────────────────
ALTER TABLE public.cleaning_sessions
  ADD COLUMN property_id uuid REFERENCES public.properties(id);

UPDATE public.cleaning_sessions cs
SET property_id = p.id
FROM public.properties p
WHERE p.name = 'Cascade Bria' AND cs.property_id IS NULL;

CREATE POLICY "authenticated_all_cleaning_sessions" ON public.cleaning_sessions
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ─── property_id on meter_readings ───────────────────────────────
ALTER TABLE public.meter_readings
  ADD COLUMN property_id uuid REFERENCES public.properties(id);

UPDATE public.meter_readings mr
SET property_id = p.id
FROM public.properties p
WHERE p.name = 'Cascade Bria' AND mr.property_id IS NULL;

ALTER TABLE public.meter_readings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated_all_meter_readings" ON public.meter_readings
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
;
