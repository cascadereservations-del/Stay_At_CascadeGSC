
-- Restrict the public anon key to only the non-PII columns the booking site needs.
-- Verified via live API logs: the only anon reader selects checkin_date,checkout_date
-- and filters on status. Edge functions (service role) are unaffected by column grants.
REVOKE SELECT ON public.calendar_events FROM anon;
GRANT  SELECT (checkin_date, checkout_date, status, source, uid) ON public.calendar_events TO anon;
;
