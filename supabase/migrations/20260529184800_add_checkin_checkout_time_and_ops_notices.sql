
-- 1. Add nullable time columns to calendar_events
ALTER TABLE public.calendar_events
  ADD COLUMN IF NOT EXISTS checkin_time  time,
  ADD COLUMN IF NOT EXISTS checkout_time time;

COMMENT ON COLUMN public.calendar_events.checkin_time  IS 'Optional check-in time for turnover-window rain forecast';
COMMENT ON COLUMN public.calendar_events.checkout_time IS 'Optional check-out time for turnover-window rain forecast';

-- 2. ops_notices table
CREATE TABLE IF NOT EXISTS public.ops_notices (
  id               uuid    PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  property_id      uuid    NOT NULL REFERENCES public.properties(id),
  notice_type      text    NOT NULL CHECK (notice_type IN ('brownout','holiday','event','reminder')),
  title            text    NOT NULL,
  description      text,
  effective_date   date    NOT NULL,
  effective_time   time,
  duration_hours   numeric(4,1),
  feeder           text,
  posted_by_chat_id bigint,
  posted_by_name   text,
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now()
);

ALTER TABLE public.ops_notices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ops_notices_anon_insert"
  ON public.ops_notices FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "ops_notices_anon_select"
  ON public.ops_notices FOR SELECT TO anon USING (is_active = true);

CREATE POLICY "ops_notices_auth_all"
  ON public.ops_notices FOR ALL TO authenticated USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS ops_notices_date_active_idx
  ON public.ops_notices (property_id, effective_date, is_active);

CREATE TRIGGER set_ops_notices_updated_at
  BEFORE UPDATE ON public.ops_notices
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
;
