-- Compensating rollback for release airbnb_message_events_20261006 (session 72).
-- The 'message' log rows hold only counts and a match flag; they are removed so the old three-type check can be restored.
-- Take a backup first if you want to keep them. Deploy the previous airbnb-email-sync first, or it will fail on new message events.
begin;
delete from public.airbnb_email_events where email_type = 'message';
alter table public.airbnb_email_events drop constraint if exists airbnb_email_events_email_type_check;
alter table public.airbnb_email_events
  add constraint airbnb_email_events_email_type_check check (email_type in ('payout', 'booking', 'cancellation'));
comment on column public.airbnb_email_events.email_type is null;
commit;
