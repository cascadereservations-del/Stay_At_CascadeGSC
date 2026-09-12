-- Return the Messenger concierge to suggest mode (drafts to Telegram, ack to guest).
begin;
update public.app_settings set value = '"suggest"'::jsonb where key = 'concierge_mode';
commit;
