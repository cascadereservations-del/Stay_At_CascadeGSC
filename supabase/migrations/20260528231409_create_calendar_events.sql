
-- ══════════════════════════════════════════════════════════════
--  calendar_events — shared calendar module
-- ══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.calendar_events (
  id              uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  property_id     uuid NOT NULL REFERENCES public.properties(id),
  uid             text NOT NULL,
  source          text NOT NULL DEFAULT 'airbnb'
                    CHECK (source IN ('airbnb', 'direct', 'manual')),
  checkin_date    date NOT NULL,
  checkout_date   date NOT NULL,
  nights          int  GENERATED ALWAYS AS ((checkout_date - checkin_date)) STORED,
  guest_name      text,
  guest_phone     text,
  status          text NOT NULL DEFAULT 'confirmed'
                    CHECK (status IN ('confirmed', 'blocked', 'cancelled')),
  raw_summary     text,
  raw_description text,
  synced_at       timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT calendar_events_uid_property_unique UNIQUE (uid, property_id)
);

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_calendar_events_updated_at ON public.calendar_events;
CREATE TRIGGER set_calendar_events_updated_at
  BEFORE UPDATE ON public.calendar_events
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_calendar_events_property_dates
  ON public.calendar_events (property_id, checkin_date, checkout_date);

CREATE INDEX IF NOT EXISTS idx_calendar_events_checkout
  ON public.calendar_events (property_id, checkout_date)
  WHERE status != 'cancelled';

CREATE INDEX IF NOT EXISTS idx_calendar_events_checkin
  ON public.calendar_events (property_id, checkin_date)
  WHERE status != 'cancelled';

ALTER TABLE public.calendar_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_read_calendar_events"
  ON public.calendar_events FOR SELECT TO anon USING (true);

CREATE POLICY "auth_full_calendar_events"
  ON public.calendar_events FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- ── RPC: get_booking_for_date ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_booking_for_date(
  p_date        date,
  p_property_id uuid DEFAULT NULL
)
RETURNS TABLE (
  event_id      uuid,
  checkin_date  date,
  checkout_date date,
  nights        int,
  guest_name    text,
  source        text,
  status        text,
  match_type    text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- Post-checkout clean: guest checked out today (priority match)
  RETURN QUERY
  SELECT
    ce.id,
    ce.checkin_date,
    ce.checkout_date,
    ce.nights,
    ce.guest_name,
    ce.source,
    ce.status,
    'checkout'::text
  FROM public.calendar_events ce
  WHERE ce.checkout_date = p_date
    AND ce.status != 'cancelled'
    AND (p_property_id IS NULL OR ce.property_id = p_property_id)
  ORDER BY ce.synced_at DESC
  LIMIT 1;

  -- If no checkout match, try checkin (pre-arrival clean)
  IF NOT FOUND THEN
    RETURN QUERY
    SELECT
      ce.id,
      ce.checkin_date,
      ce.checkout_date,
      ce.nights,
      ce.guest_name,
      ce.source,
      ce.status,
      'checkin'::text
    FROM public.calendar_events ce
    WHERE ce.checkin_date = p_date
      AND ce.status != 'cancelled'
      AND (p_property_id IS NULL OR ce.property_id = p_property_id)
    ORDER BY ce.synced_at DESC
    LIMIT 1;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_booking_for_date(date, uuid) TO anon;

-- ── calendar_sync_log ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.calendar_sync_log (
  id           uuid PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  property_id  uuid NOT NULL REFERENCES public.properties(id),
  source       text NOT NULL DEFAULT 'airbnb',
  synced_at    timestamptz NOT NULL DEFAULT now(),
  event_count  int,
  status       text DEFAULT 'ok',
  error_msg    text
);

ALTER TABLE public.calendar_sync_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "anon_read_sync_log"
  ON public.calendar_sync_log FOR SELECT TO anon USING (true);

CREATE POLICY "auth_full_sync_log"
  ON public.calendar_sync_log FOR ALL TO authenticated
  USING (true) WITH CHECK (true);
;
