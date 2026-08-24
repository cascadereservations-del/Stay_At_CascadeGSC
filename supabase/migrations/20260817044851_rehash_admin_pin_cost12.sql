-- The stored admin_pin_hash was a bcrypt of some earlier, unknown PIN and never
-- matched the ADMIN_CODE the guide actually used, so wiring the RPC to it as-is
-- would have locked out Lloyd, Marifel and Honey.
--
-- Per Lloyd's decision: keep the code staff already type, so nothing has to be
-- re-taught. Re-hash it at cost 12 (the previous hash was cost 6, which is fast
-- to brute-force).
--
-- To rotate later, this is the only statement needed - no code change, no push:
--   update app_settings
--      set value = to_jsonb(extensions.crypt('NEW_CODE_HERE', extensions.gen_salt('bf', 12)))
--    where key = 'admin_pin_hash';

update app_settings
   set value = to_jsonb(extensions.crypt('chadminko', extensions.gen_salt('bf', 12)))
 where key = 'admin_pin_hash';;
