-- Switch the Messenger concierge to auto so replies land in Messenger for review.
-- Safe while the Meta app is In Development: Meta delivers webhooks only for app
-- admins and testers, so no real guest can reach the bot yet (D-063 rollout note).
begin;
update public.app_settings set value = '"auto"'::jsonb where key = 'concierge_mode';
commit;
