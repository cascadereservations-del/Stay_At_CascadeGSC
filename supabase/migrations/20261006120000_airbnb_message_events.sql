-- Session 72, SPEC-42 section 2 (D-290 item 5): Airbnb guest-message e-mails become events in airbnb_email_events.
-- The Apps Script sends email_type 'message'; airbnb-email-sync reads a phone number and companion names from the guest's text and
-- posts ONE review card to OPS (the existing /guest save buttons). The log row stores only counts and a match flag, never the text.
-- This release only widens the email_type CHECK from payout/booking/cancellation to add 'message'. Expand only: no column, no data change;
-- every existing row already satisfies the wider check. Old writers keep working (they send the three old types).
-- Rollback: supabase/rollbacks/20261006_airbnb_message_events.sql

begin;

alter table public.airbnb_email_events drop constraint if exists airbnb_email_events_email_type_check;
alter table public.airbnb_email_events
  add constraint airbnb_email_events_email_type_check check (email_type in ('payout', 'booking', 'cancellation', 'message'));

comment on column public.airbnb_email_events.email_type is
  'booking, payout, cancellation, or message (a guest chat e-mail; raw_payload then holds only guest_first_name, confirmation_code, matched, has_phone, names_count - never the text).';

commit;
