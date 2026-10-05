-- Session 72, SPEC-42 section 2: airbnb_email_events accepts email_type 'message' (migration 20261006120000), nothing else new.
-- Synthetic property and gmail ids only; inside begin/rollback. The last tests run the rollback body.
begin;
select plan(11);

insert into public.properties(id, name, is_active) values ('e7500000-0000-4000-8000-0000000000a1', 'Synthetic Airbnb Messages', true);

select ok((select pg_get_constraintdef(oid) like '%message%' from pg_constraint where conrelid = 'public.airbnb_email_events'::regclass and conname = 'airbnb_email_events_email_type_check'),
  'the email_type check lists message');
select lives_ok($$insert into public.airbnb_email_events(property_id, gmail_message_id, email_type, email_date, subject, raw_payload)
  values ('e7500000-0000-4000-8000-0000000000a1', 'SYNTH-msg-1', 'message', now(), null,
          '{"guest_first_name":"Sample","confirmation_code":"HMSYNTH001","matched":true,"has_phone":true,"names_count":2}')$$,
  'a message event can be logged');
select lives_ok($$insert into public.airbnb_email_events(property_id, gmail_message_id, email_type, email_date) values
  ('e7500000-0000-4000-8000-0000000000a1', 'SYNTH-b-1', 'booking', now()),
  ('e7500000-0000-4000-8000-0000000000a1', 'SYNTH-p-1', 'payout', now()),
  ('e7500000-0000-4000-8000-0000000000a1', 'SYNTH-c-1', 'cancellation', now())$$,
  'booking, payout and cancellation still log');
select throws_ok($$insert into public.airbnb_email_events(property_id, gmail_message_id, email_type, email_date)
  values ('e7500000-0000-4000-8000-0000000000a1', 'SYNTH-x-1', 'sms', now())$$, '23514', null, 'an unknown type is still refused');
select throws_ok($$insert into public.airbnb_email_events(property_id, gmail_message_id, email_type, email_date)
  values ('e7500000-0000-4000-8000-0000000000a1', 'SYNTH-msg-1', 'message', now())$$, '23505', null, 'the same gmail message id is still logged once');
select is((select raw_payload ->> 'names_count' from public.airbnb_email_events where gmail_message_id = 'SYNTH-msg-1'), '2', 'the counts-only payload is stored as sent');
select lives_ok($$insert into public.telegram_pending(chat_id, kind, payload, expires_at)
  values (-1000000000001, 'guest_save', '{"from_id":null,"from_name":"Airbnb e-mail","file_id":"","plan":{}}', now() + interval '72 hours')$$,
  'a guest_save card with no owner (from_id null) fits the existing pending table');

-- Rollback body.
select lives_ok($$
  delete from public.airbnb_email_events where email_type = 'message';
  alter table public.airbnb_email_events drop constraint if exists airbnb_email_events_email_type_check;
  alter table public.airbnb_email_events
    add constraint airbnb_email_events_email_type_check check (email_type in ('payout', 'booking', 'cancellation'));
$$, 'the rollback body runs cleanly with a message row present');
select is((select count(*)::int from public.airbnb_email_events where email_type = 'message'), 0, 'rollback removed the message rows');
select throws_ok($$insert into public.airbnb_email_events(property_id, gmail_message_id, email_type, email_date)
  values ('e7500000-0000-4000-8000-0000000000a1', 'SYNTH-msg-2', 'message', now())$$, '23514', null, 'after rollback message is refused again');
select is((select count(*)::int from public.airbnb_email_events where gmail_message_id in ('SYNTH-b-1', 'SYNTH-p-1', 'SYNTH-c-1')), 3, 'rollback kept the three old event types');

select * from finish();
rollback;
