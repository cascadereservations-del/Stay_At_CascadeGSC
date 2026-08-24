-- Preserve the existing RLS owner/admin policies. This migration removes
-- direct Data API grants that are unnecessary because Edge Functions are the
-- public API boundary for booking and availability operations.

REVOKE ALL ON TABLE public.airbnb_reservations FROM anon, authenticated;
REVOKE ALL ON TABLE public.calendar_events FROM anon, authenticated;
REVOKE ALL ON TABLE public.calendar_sync_log FROM anon, authenticated;
REVOKE ALL ON TABLE public.booking_inquiries FROM anon, authenticated;

-- The server-side Edge Functions use the service role. Keep service-role
-- table access explicit for the existing operational flows.
GRANT ALL ON TABLE public.airbnb_reservations TO service_role;
GRANT ALL ON TABLE public.calendar_events TO service_role;
GRANT ALL ON TABLE public.calendar_sync_log TO service_role;
GRANT ALL ON TABLE public.booking_inquiries TO service_role;

-- Remove public name-based history lookup and browser-triggered Telegram side
-- effects. A later token-based guest-access flow replaces these RPCs.
REVOKE ALL ON FUNCTION public.get_guest_history(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.log_returning_guest_alert(text, date, date, integer, integer, integer, date, date, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_guest_history(text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.log_returning_guest_alert(text, date, date, integer, integer, integer, date, date, uuid) TO service_role;
