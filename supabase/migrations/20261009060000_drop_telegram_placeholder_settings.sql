-- 20261009060000_drop_telegram_placeholder_settings.sql
-- Session 79 (lane B, SQL): app_settings rows telegram_bot_token and telegram_marifel_chat_id still hold the PASTE_ placeholders
-- from the first Telegram setup. Their only reader, log_returning_guest_alert, already treats NULL like PASTE and sends nothing, so
-- removing the rows changes no behaviour and stops a secret-shaped key sitting in a settings table. Deleted only where the value is
-- still a placeholder (value::text like '%PASTE%'): a real value, if one was ever written, is left alone.
-- Rollback: supabase/rollbacks/20261009_s79_guest_id.sql re-inserts the two placeholders.

begin;

delete from public.app_settings
 where key in ('telegram_bot_token', 'telegram_marifel_chat_id')
   and value::text like '%PASTE%';

commit;
