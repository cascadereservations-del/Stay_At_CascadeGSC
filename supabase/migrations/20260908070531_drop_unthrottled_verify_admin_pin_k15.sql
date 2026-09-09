-- K15 — remove the unthrottled verify_admin_pin(pin text) overload.
--
-- It was SECURITY DEFINER, executable by anon, and compared the raw PIN with
-- no rate limit, so the admin gate was brute-forceable from any browser. The
-- throttled overload verify_admin_pin(p_code text, p_client text) has always
-- existed alongside it: 8 failed attempts per 15 minutes per hashed client,
-- every attempt logged to admin_auth_attempts.
--
-- Both callers now use the throttled overload:
--   * guest guide index.html   — since v7.9.5 (2026-08-17, K14)
--   * CH_Inventory index.html  — since 8eacecc (2026-09-08), live on Pages
--
-- Revoke before drop so the privilege change is explicit in the ledger.
revoke execute on function public.verify_admin_pin(text) from anon, authenticated, service_role;
drop function if exists public.verify_admin_pin(text);
