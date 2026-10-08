-- Session 79 (lane B): release s79_guest_id_20261009, part 1. concierge_save_guest_id_v1 (Messenger ID photo filing) and the
-- removal of the two PASTE_ placeholder settings. Synthetic fixtures only (uuids e7900000-...); every lookup is scoped to them,
-- because a restored production backup carries real rows. Everything rolls back.
begin;
select plan(40);

select has_function('public', 'concierge_save_guest_id_v1', array['uuid', 'uuid', 'text', 'text', 'text', 'boolean'], 'the RPC exists');
select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.concierge_save_guest_id_v1(uuid,uuid,text,text,text,boolean)'::regprocedure),
  'security definer with an empty search_path');
select ok(has_function_privilege('service_role', 'public.concierge_save_guest_id_v1(uuid,uuid,text,text,text,boolean)', 'execute')
      and not has_function_privilege('anon', 'public.concierge_save_guest_id_v1(uuid,uuid,text,text,text,boolean)', 'execute')
      and not has_function_privilege('authenticated', 'public.concierge_save_guest_id_v1(uuid,uuid,text,text,text,boolean)', 'execute'),
  'service_role only');

insert into public.properties(id, name, is_active) values ('e7900000-0000-4000-8000-0000000000a1', 'Synthetic S79 Guest Id', true);
insert into public.guests(id, property_id, name) values
  ('e7900000-0000-4000-8000-0000000000d1', 'e7900000-0000-4000-8000-0000000000a1', 'Zz S79 Booker'),
  ('e7900000-0000-4000-8000-0000000000d2', 'e7900000-0000-4000-8000-0000000000a1', 'Zz S79 Second'),
  ('e7900000-0000-4000-8000-0000000000d3', 'e7900000-0000-4000-8000-0000000000a1', 'Zz S79 Crowd');
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, checkin_date, checkout_date, status) values
  ('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000a1', 'e7900000-0000-4000-8000-0000000000d1', 'Zz S79 Booker', 'zz1@example.com', '2030-03-01', '2030-03-04', 'confirmed'),
  ('e7900000-0000-4000-8000-0000000000b2', 'e7900000-0000-4000-8000-0000000000a1', 'e7900000-0000-4000-8000-0000000000d2', 'Zz S79 Second', 'zz2@example.com', '2030-03-01', '2030-03-04', 'confirmed'),
  ('e7900000-0000-4000-8000-0000000000b3', 'e7900000-0000-4000-8000-0000000000a1', 'e7900000-0000-4000-8000-0000000000d3', 'Zz S79 Crowd', 'zz3@example.com', '2030-03-01', '2030-03-04', 'confirmed'),
  ('e7900000-0000-4000-8000-0000000000b4', 'e7900000-0000-4000-8000-0000000000a1', 'e7900000-0000-4000-8000-0000000000d1', 'Zz S79 Booker', 'zz1@example.com', '2030-04-01', '2030-04-04', 'pending'),
  ('e7900000-0000-4000-8000-0000000000b5', 'e7900000-0000-4000-8000-0000000000a1', null, 'Zz S79 Noguest', 'zz5@example.com', '2030-05-01', '2030-05-04', 'confirmed');

-- companion ids and their photo objects
insert into storage.objects(bucket_id, name) values
  ('guest-id-photos', 'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg'),
  ('guest-id-photos', 'e7900000-0000-4000-8000-0000000000c2/e7900000-0000-4000-8000-0000000000f2.png'),
  ('guest-id-photos', 'e7900000-0000-4000-8000-0000000000c3/e7900000-0000-4000-8000-0000000000f3.jpg'),
  ('guest-id-photos', 'e7900000-0000-4000-8000-0000000000c9/e7900000-0000-4000-8000-0000000000f9.jpg');

-- reasons as data -----------------------------------------------------------------------------------------------------
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000ee', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg', true), '{"ok":false,"reason":"no_booking"}'::jsonb, 'unknown booking: no_booking');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b5', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg', true), '{"ok":false,"reason":"no_booking"}'::jsonb, 'booking without a guest: no_booking');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b4', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg', true), '{"ok":false,"reason":"not_confirmed"}'::jsonb, 'pending booking: not_confirmed');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna', 'passport',
  'e7900000-0000-4000-8000-0000000000c9/e7900000-0000-4000-8000-0000000000f9.jpg', true), '{"ok":false,"reason":"bad_path"}'::jsonb, 'a path under another companion id: bad_path');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.gif', true), '{"ok":false,"reason":"bad_path"}'::jsonb, 'a .gif path: bad_path');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna', 'passport',
  null, true), '{"ok":false,"reason":"bad_path"}'::jsonb, 'no path: bad_path');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000e7.jpg', true), '{"ok":false,"reason":"photo_missing"}'::jsonb, 'a well-formed path with no storage object: photo_missing');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna', 'visa',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg', true), '{"ok":false,"reason":"bad_id_type"}'::jsonb, 'unknown id type: bad_id_type');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c1', 'A', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg', true), '{"ok":false,"reason":"bad_name"}'::jsonb, 'one-letter name: bad_name');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c1', 'Zz 12345 Anna', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg', true), '{"ok":false,"reason":"bad_name"}'::jsonb, 'a name holding a long digit run: bad_name');
select is((select count(*)::int from public.guest_companions where property_id = 'e7900000-0000-4000-8000-0000000000a1'), 0, 'no refusal wrote a companion');
select is((select count(*)::int from public.guest_profile_details where property_id = 'e7900000-0000-4000-8000-0000000000a1'), 0, 'no refusal created a profile row');

-- a good save ----------------------------------------------------------------------------------------------------------
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c1', '  Zz   Anna Cruz ', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg', true),
  '{"ok":true,"companion_id":"e7900000-0000-4000-8000-0000000000c1","id_on_file":true}'::jsonb, 'a good save returns ok, the companion id and id_on_file true');
select is((select name || '|' || id_type || '|' || notes || '|' || id_photo_path from public.guest_companions where id = 'e7900000-0000-4000-8000-0000000000c1'),
  'Zz Anna Cruz|passport|Sent in Messenger|e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg',
  'companion row: tidied name, id type, note Sent in Messenger, photo path');
select is((select guest_id from public.guest_companions where id = 'e7900000-0000-4000-8000-0000000000c1'), 'e7900000-0000-4000-8000-0000000000d1'::uuid, 'companion is on the booking guest');
select is((select property_id from public.guest_companions where id = 'e7900000-0000-4000-8000-0000000000c1'), 'e7900000-0000-4000-8000-0000000000a1'::uuid, 'companion carries the booking property');
select is((select created_by is null and updated_by is null and id_number is null and contact_number is null from public.guest_companions where id = 'e7900000-0000-4000-8000-0000000000c1'),
  true, 'no actor, no ID number, no contact written');
select is((select count(*)::int || '|' || min(reason) || '|' || bool_and(changed_by is null)::text || '|' || bool_and(before_state is null)::text
             from public.guest_companion_history where companion_id = 'e7900000-0000-4000-8000-0000000000c1'),
  '1|messenger-auto|true|true', 'one companion history row: reason messenger-auto, changed_by null, no before');
select is((select id_on_file from public.guest_profile_details where guest_id = 'e7900000-0000-4000-8000-0000000000d1'), true, 'guest id_on_file is true');
select is((select count(*)::int || '|' || min(reason) || '|' || bool_and(changed_by is null)::text
             from public.guest_profile_history where guest_id = 'e7900000-0000-4000-8000-0000000000d1'),
  '1|messenger-auto|true', 'one profile history row: messenger-auto, changed_by null');
select is((select (before_state->>'id_on_file') || '>' || (after_state->>'id_on_file') from public.guest_profile_history where guest_id = 'e7900000-0000-4000-8000-0000000000d1'),
  'false>true', 'the profile history shows id_on_file going false to true');

-- idempotent on the companion id ---------------------------------------------------------------------------------------
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna Cruz', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg', true),
  '{"ok":true,"companion_id":"e7900000-0000-4000-8000-0000000000c1","id_on_file":true}'::jsonb, 'a second call with the same companion id returns ok');
select is((select count(*)::int from public.guest_companions where guest_id = 'e7900000-0000-4000-8000-0000000000d1'), 1, 'and writes no second companion');
select is((select count(*)::int from public.guest_companion_history where companion_id = 'e7900000-0000-4000-8000-0000000000c1'), 1, 'and no second companion history row');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'e7900000-0000-4000-8000-0000000000d1'), 1, 'and no second profile history row');
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b2', 'e7900000-0000-4000-8000-0000000000c1', 'Zz Anna Cruz', 'passport',
  'e7900000-0000-4000-8000-0000000000c1/e7900000-0000-4000-8000-0000000000f1.jpg', true),
  '{"ok":false,"reason":"bad_path"}'::jsonb, 'the same companion id on another guest''s booking is refused');

-- a second person on the same guest while id_on_file is already true: no new profile history
select is((public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b1', 'e7900000-0000-4000-8000-0000000000c2', 'Zz Ben Cruz', null,
  'e7900000-0000-4000-8000-0000000000c2/e7900000-0000-4000-8000-0000000000f2.png', true))->>'ok', 'true', 'a second person with no id type saves');
select is((select count(*)::int from public.guest_companions where guest_id = 'e7900000-0000-4000-8000-0000000000d1'), 2, 'the guest now has two companions');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'e7900000-0000-4000-8000-0000000000d1'), 1, 'id_on_file already true: no second profile history row');

-- p_mark_id_on_file false leaves the flag alone ---------------------------------------------------------------------------
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b2', 'e7900000-0000-4000-8000-0000000000c3', 'Zz Cara Reyes', 'national_id',
  'e7900000-0000-4000-8000-0000000000c3/e7900000-0000-4000-8000-0000000000f3.jpg', false),
  '{"ok":true,"companion_id":"e7900000-0000-4000-8000-0000000000c3","id_on_file":false}'::jsonb, 'mark false: ok, id_on_file false');
select is((select id_on_file from public.guest_profile_details where guest_id = 'e7900000-0000-4000-8000-0000000000d2'), false, 'the second guest''s id_on_file stays false');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'e7900000-0000-4000-8000-0000000000d2'), 0, 'and no profile history row is written for it');

-- 12 people is the ceiling ---------------------------------------------------------------------------------------------------
insert into public.guest_companions(guest_id, property_id, name)
select 'e7900000-0000-4000-8000-0000000000d3', 'e7900000-0000-4000-8000-0000000000a1', 'Zz Crowd ' || i from generate_series(1, 12) i;
select is(public.concierge_save_guest_id_v1('e7900000-0000-4000-8000-0000000000b3', 'e7900000-0000-4000-8000-0000000000c9', 'Zz One More', 'passport',
  'e7900000-0000-4000-8000-0000000000c9/e7900000-0000-4000-8000-0000000000f9.jpg', true),
  '{"ok":false,"reason":"too_many"}'::jsonb, 'a 13th person: too_many');

-- the two PASTE_ placeholder settings are gone (the migration ran before this suite), and the delete is value-guarded ----------
select is((select count(*)::int from public.app_settings where key in ('telegram_bot_token', 'telegram_marifel_chat_id') and value::text like '%PASTE%'), 0,
  'no PASTE_ placeholder is left under the two Telegram keys');
insert into public.app_settings(key, value) values ('telegram_bot_token', '"PASTE_BOT_TOKEN_HERE"'::jsonb), ('telegram_marifel_chat_id', '"123456789"'::jsonb)
  on conflict (key) do update set value = excluded.value;
delete from public.app_settings where key in ('telegram_bot_token', 'telegram_marifel_chat_id') and value::text like '%PASTE%';
select is((select count(*)::int from public.app_settings where key = 'telegram_bot_token'), 0, 'the migration''s delete removes a placeholder');
select is((select value #>> '{}' from public.app_settings where key = 'telegram_marifel_chat_id'), '123456789', 'and leaves a real value alone');
select is((select count(*)::int from public.app_settings where key = 'airbnb_prep_nights'), 1, 'the airbnb_prep_nights setting exists');

select * from finish();
rollback;
