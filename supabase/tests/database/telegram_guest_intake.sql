-- Session 67b: release telegram_guest_intake_20261002. Telegram /guest intake: a service-role-only RPC set that writes the guest
-- profile and companions on behalf of a Telegram user who maps to an active staff profile. Synthetic fixtures only (public repo);
-- they go with the closing rollback. Property P is private to this suite, so restored production rows never interfere.
--   admin A  (tg 906700001) admin with property access          -> allowed
--   admin B  (tg 906700002) admin WITHOUT property access        -> refused
--   cleaner C (tg 906700003) role without manage_operations      -> refused
--   admin D  (tg 906700004) disabled                            -> refused
--   owner O  (tg 906700005) owner, no property row (owners need none) -> allowed
--   guests: g1 Airbnb stay now, g2 direct stay in 5 days, g3 stay in 30 days (outside the window), g4 no stay
begin;
select plan(67);

select has_function('public', 'telegram_staff_actor_v1', array['bigint', 'uuid'], 'actor helper exists');
select has_function('public', 'telegram_guest_candidates_v1', array['bigint', 'uuid', 'date', 'date', 'text'], 'candidates RPC exists');
select has_function('public', 'telegram_save_guest_details_v1', array['uuid', 'jsonb', 'bigint', 'text'], 'details RPC exists');
select has_function('public', 'telegram_save_guest_companion_v1', array['uuid', 'text', 'text', 'text', 'text', 'text', 'bigint', 'text'], 'companion RPC exists');
select ok(has_function_privilege('service_role', 'public.telegram_guest_candidates_v1(bigint,uuid,date,date,text)', 'execute')
      and has_function_privilege('service_role', 'public.telegram_save_guest_details_v1(uuid,jsonb,bigint,text)', 'execute')
      and has_function_privilege('service_role', 'public.telegram_save_guest_companion_v1(uuid,text,text,text,text,text,bigint,text)', 'execute'),
  'service_role can execute the three RPCs');
select ok(not has_function_privilege('anon', 'public.telegram_save_guest_details_v1(uuid,jsonb,bigint,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_save_guest_details_v1(uuid,jsonb,bigint,text)', 'execute')
      and not has_function_privilege('anon', 'public.telegram_save_guest_companion_v1(uuid,text,text,text,text,text,bigint,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_save_guest_companion_v1(uuid,text,text,text,text,text,bigint,text)', 'execute')
      and not has_function_privilege('anon', 'public.telegram_guest_candidates_v1(bigint,uuid,date,date,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_guest_candidates_v1(bigint,uuid,date,date,text)', 'execute'),
  'anon and authenticated cannot execute any of them');
select ok(not has_function_privilege('service_role', 'public.telegram_staff_actor_v1(bigint,uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_staff_actor_v1(bigint,uuid)', 'execute'),
  'the actor helper is not callable by service_role or authenticated');
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""'])
             from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('telegram_staff_actor_v1', 'telegram_guest_candidates_v1', 'telegram_save_guest_details_v1', 'telegram_save_guest_companion_v1')),
  'all four are security definer with an empty search_path');

insert into public.properties(id, name, is_active) values ('e2000000-0000-4000-8000-000000000067', 'Synthetic Guest Intake 67b', true);
insert into auth.users(id) values
  ('e2000000-0000-4000-8000-0000000000a1'), ('e2000000-0000-4000-8000-0000000000a2'), ('e2000000-0000-4000-8000-0000000000a3'),
  ('e2000000-0000-4000-8000-0000000000a4'), ('e2000000-0000-4000-8000-0000000000a5');
insert into public.staff_access_profiles(user_id, role, telegram_user_id, disabled_at) values
  ('e2000000-0000-4000-8000-0000000000a1', 'admin',   906700001, null),
  ('e2000000-0000-4000-8000-0000000000a2', 'admin',   906700002, null),
  ('e2000000-0000-4000-8000-0000000000a3', 'cleaner', 906700003, null),
  ('e2000000-0000-4000-8000-0000000000a4', 'admin',   906700004, now()),
  ('e2000000-0000-4000-8000-0000000000a5', 'owner',   906700005, null);
insert into public.staff_property_access(user_id, property_id) values
  ('e2000000-0000-4000-8000-0000000000a1', 'e2000000-0000-4000-8000-000000000067'),
  ('e2000000-0000-4000-8000-0000000000a3', 'e2000000-0000-4000-8000-000000000067'),
  ('e2000000-0000-4000-8000-0000000000a4', 'e2000000-0000-4000-8000-000000000067');

insert into public.guests(id, property_id, name) values
  ('e2000000-0000-4000-8000-0000000000b1', 'e2000000-0000-4000-8000-000000000067', 'Synthetic Guest One'),
  ('e2000000-0000-4000-8000-0000000000b2', 'e2000000-0000-4000-8000-000000000067', 'Synthetic Guest Two'),
  ('e2000000-0000-4000-8000-0000000000b3', 'e2000000-0000-4000-8000-000000000067', 'Synthetic Guest Three'),
  ('e2000000-0000-4000-8000-0000000000b4', 'e2000000-0000-4000-8000-000000000067', 'Synthetic Quiet Guest');
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('e2000000-0000-4000-8000-0000000000c1', 'e2000000-0000-4000-8000-000000000067', 'HMSYNTH67B1', 'confirmed', 'e2000000-0000-4000-8000-0000000000b1', 'Synthetic Guest One', current_date - 1, current_date + 2);
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, status, source, submitted_at, total_amount, deposit_amount) values
  ('c0de67b2-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000067', 'e2000000-0000-4000-8000-0000000000b2', 'Synthetic Guest Two', 'two@example.com', '09170000672', current_date + 5, current_date + 7, 'confirmed', 'direct', now(), 3560, 1780),
  ('c0de67b3-0000-4000-8000-000000000003', 'e2000000-0000-4000-8000-000000000067', 'e2000000-0000-4000-8000-0000000000b3', 'Synthetic Guest Three', 'three@example.com', '09170000673', current_date + 30, current_date + 32, 'confirmed', 'direct', now(), 3560, 1780);
insert into public.calendar_events(id, property_id, uid, source, status, checkin_date, checkout_date, guest_name, linked_reservation_id) values
  ('e2000000-0000-4000-8000-0000000000d1', 'e2000000-0000-4000-8000-000000000067', 'synth-67b-1@airbnb.com', 'airbnb', 'confirmed', current_date - 1, current_date + 2, 'Synthetic Guest One', 'e2000000-0000-4000-8000-0000000000c1'),
  ('e2000000-0000-4000-8000-0000000000d2', 'e2000000-0000-4000-8000-000000000067', 'direct:c0de67b2-0000-4000-8000-000000000002', 'direct', 'confirmed', current_date + 5, current_date + 7, 'Synthetic Guest Two', null),
  ('e2000000-0000-4000-8000-0000000000d3', 'e2000000-0000-4000-8000-000000000067', 'direct:c0de67b3-0000-4000-8000-000000000003', 'direct', 'confirmed', current_date + 30, current_date + 32, 'Synthetic Guest Three', null);

-- 9-14 who counts as a linked actor
select is(public.telegram_staff_actor_v1(906700001, 'e2000000-0000-4000-8000-000000000067'), 'e2000000-0000-4000-8000-0000000000a1'::uuid, 'actor: admin with property access is linked');
select is(public.telegram_staff_actor_v1(906700005, 'e2000000-0000-4000-8000-000000000067'), 'e2000000-0000-4000-8000-0000000000a5'::uuid, 'actor: an owner needs no property row');
select is(public.telegram_staff_actor_v1(906700002, 'e2000000-0000-4000-8000-000000000067'), null, 'actor: admin without the property is refused');
select is(public.telegram_staff_actor_v1(906700003, 'e2000000-0000-4000-8000-000000000067'), null, 'actor: a cleaner (no manage_operations) is refused');
select is(public.telegram_staff_actor_v1(906700004, 'e2000000-0000-4000-8000-000000000067'), null, 'actor: a disabled admin is refused');
select is(public.telegram_staff_actor_v1(906799999, 'e2000000-0000-4000-8000-000000000067'), null, 'actor: an unknown Telegram id is refused');

-- 15-24 candidates
select is(public.telegram_guest_candidates_v1(906700003, 'e2000000-0000-4000-8000-000000000067', current_date, current_date + 7, null),
  '{"ok": false, "reason": "unmapped_telegram_user"}'::jsonb, 'candidates: an unlinked user gets a refusal, not a list');
select is(jsonb_array_length(public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', current_date, current_date + 7, null) -> 'guests'), 2,
  'candidates: the stays in the next 7 days give two guests (the 30-day stay is out)');
select is((public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', current_date, current_date + 7, null) -> 'guests' -> 0 ->> 'name'), 'Synthetic Guest One',
  'candidates: ordered by check-in, the in-house guest first');
select is((public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', current_date, current_date + 7, null) -> 'guests' -> 1 ->> 'checkin'), (current_date + 5)::text,
  'candidates: the direct booking maps to its guest and carries its check-in date');
select is((public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', current_date, current_date + 7, null) -> 'guests' -> 0 ->> 'id_on_file'), 'false',
  'candidates: id_on_file starts false');
select is(jsonb_array_length(public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', current_date, current_date + 40, null) -> 'guests'), 3,
  'candidates: a wider window gives all three stay guests');
select is((public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', null, null, 'quiet') -> 'guests' -> 0 ->> 'name'), 'Synthetic Quiet Guest',
  'candidates: a name search finds a guest with no stay (case-insensitive)');
select is(public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', null, null, 'q'),
  '{"ok": false, "reason": "search_too_short"}'::jsonb, 'candidates: a one-letter search is refused');
select is(jsonb_array_length(public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', null, null, '%%') -> 'guests'), 0,
  'candidates: LIKE wildcards in the search are literal, not "match everything"');
select is(jsonb_array_length(public.telegram_guest_candidates_v1(906700005, 'e2000000-0000-4000-8000-000000000066', current_date, current_date + 7, null) -> 'guests'), 0,
  'candidates: another property returns none of this property''s guests');

-- 25-37 details
select is(public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"contact_number":"09170000001"}'::jsonb, 906700003, 'cleaner tries'),
  '{"ok": false, "reason": "unmapped_telegram_user"}'::jsonb, 'details: an unlinked user is refused');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'e2000000-0000-4000-8000-0000000000b1'), 0, 'details: a refusal writes no history');
select is((select count(*)::int from public.guest_profile_details where guest_id = 'e2000000-0000-4000-8000-0000000000b1'), 0, 'details: a refusal creates no profile row');
select throws_ok($$select public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"birthday":"1990-01-01"}'::jsonb, 906700001, 'sneaky field')$$,
  '22023', 'field not allowed from Telegram: birthday', 'details: only the whitelist is writable (no birthday)');
select throws_ok($$select public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"id_number":"X1234567"}'::jsonb, 906700001, 'sneaky number')$$,
  '22023', 'field not allowed from Telegram: id_number', 'details: an ID number can never be written from Telegram');
select throws_ok($$select public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{}'::jsonb, 906700001, 'nothing in it')$$,
  '22023', 'patch must be a non-empty object', 'details: an empty patch is refused');
select throws_ok($$select public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"contact_number":"not a number"}'::jsonb, 906700001, 'bad phone')$$,
  '22023', 'contact number looks invalid', 'details: a malformed number is refused');
select throws_ok($$select public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"id_type":"selfie"}'::jsonb, 906700001, 'bad type')$$,
  '22023', 'id type not recognised', 'details: an unknown ID type is refused');
select throws_ok($$select public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"id_on_file":true}'::jsonb, 906700001, 'no')$$,
  '22023', 'profile change reason required', 'details: a reason under 3 characters is refused');
select throws_ok($$select public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000ff', '{"id_on_file":true}'::jsonb, 906700001, 'unknown guest')$$,
  'P0002', 'guest not found', 'details: an unknown guest is refused');
select is((public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1',
    '{"contact_number":"0917 000-0001","id_on_file":true,"id_type":"passport"}'::jsonb, 906700001, 'Telegram /guest by A')) - 'updatedAt',
  '{"ok": true, "unchanged": false, "guestId": "e2000000-0000-4000-8000-0000000000b1", "version": 2}'::jsonb, 'details: the first save lands at version 2');
select is((select contact_number || '/' || id_type || '/' || id_on_file::text from public.guest_profile_details where guest_id = 'e2000000-0000-4000-8000-0000000000b1'),
  '09170000001/passport/true', 'details: the number is stored without spaces or dashes, type and flag set');
select is((select h.changed_by::text || '|' || h.reason from public.guest_profile_history h where h.guest_id = 'e2000000-0000-4000-8000-0000000000b1'),
  'e2000000-0000-4000-8000-0000000000a1|telegram: Telegram /guest by A', 'details: one history row, changed_by is the staff user, reason is prefixed');
select is((select contact_provenance -> 'last_change' ->> 'via' from public.guest_profile_details where guest_id = 'e2000000-0000-4000-8000-0000000000b1'), 'telegram',
  'details: the provenance marks the change as via telegram');

-- 38-43 details: idempotence and append
select is((public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"id_on_file":true,"id_type":"passport"}'::jsonb, 906700001, 'repeat tap')) ->> 'unchanged', 'true',
  'details: the same save again is unchanged');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'e2000000-0000-4000-8000-0000000000b1'), 1, 'details: an unchanged save writes no history');
select is((select version from public.guest_profile_details where guest_id = 'e2000000-0000-4000-8000-0000000000b1'), 2, 'details: an unchanged save keeps the version');
select public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"stay_preferences":"Likes the quiet room"}'::jsonb, 906700001, 'first preference');
select public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"stay_preferences":"Late check-in"}'::jsonb, 906700001, 'second preference');
select is((select stay_preferences from public.guest_profile_details where guest_id = 'e2000000-0000-4000-8000-0000000000b1'), E'Likes the quiet room\nLate check-in',
  'details: stay_preferences are appended, not replaced');
select is((public.telegram_save_guest_details_v1('e2000000-0000-4000-8000-0000000000b1', '{"stay_preferences":"Likes the quiet room"}'::jsonb, 906700001, 'resend first')) ->> 'unchanged', 'true',
  'details: a preference already on the record is not appended twice');

-- 44-45 the picker now reflects what was saved
select is((public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', current_date, current_date + 7, null) -> 'guests' -> 0 ->> 'id_on_file'), 'true',
  'candidates: id_on_file turns true after the save');
select is((public.telegram_guest_candidates_v1(906700001, 'e2000000-0000-4000-8000-000000000067', current_date, current_date + 7, null) -> 'guests' -> 0 ->> 'has_contact'), 'true',
  'candidates: has_contact turns true after the save');

-- 46-66 companions
select is(public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'Jane Synthetic', null, null, null, null, 906700002, 'admin B tries'),
  '{"ok": false, "reason": "unmapped_telegram_user"}'::jsonb, 'companion: a user without the property is refused');
select throws_ok($$select public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'Jane 12345678', null, null, null, null, 906700001, 'number in the name')$$,
  '22023', 'companion name invalid', 'companion: a name carrying a long digit run (an ID number) is refused');
select throws_ok($$select public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'J', null, null, null, null, 906700001, 'too short')$$,
  '22023', 'companion name invalid', 'companion: a one-letter name is refused');
select throws_ok($$select public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'Jane Synthetic', 'selfie', null, null, null, 906700001, 'bad type')$$,
  '22023', 'id type not recognised', 'companion: an unknown ID type is refused');
select throws_ok($$select public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'Jane Synthetic', null, 'x/y.jpg', null, null, 906700001, 'photo on create')$$,
  '22023', 'create the companion first, then attach the photo', 'companion: a photo cannot ride on the create call');
select set_config('cascade.companion_id',
  (public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', '  Jane   Synthetic ', 'passport', null, '0917 111 2222', 'Seen at the gate', 906700001, 'Telegram /guest create'))::text, true);
select is((current_setting('cascade.companion_id')::jsonb ->> 'created'), 'true', 'companion: first save creates');
select set_config('cascade.companion_id', (current_setting('cascade.companion_id')::jsonb ->> 'id'), true);
select is((select name || '|' || contact_number || '|' || id_type || '|' || version::text from public.guest_companions where id = current_setting('cascade.companion_id')::uuid),
  'Jane Synthetic|09171112222|passport|1', 'companion: whitespace tidied, number normalised, version 1');
select is((select count(*)::int from public.guest_companion_history where companion_id = current_setting('cascade.companion_id')::uuid and before_state is null), 1,
  'companion: the create left one history row with no before-state');
select is((public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'jane synthetic', 'passport', null, null, null, 906700001, 'same again')) ->> 'unchanged', 'true',
  'companion: the same name in other case is the same person and the same data is unchanged');
select is((select count(*)::int from public.guest_companions where guest_id = 'e2000000-0000-4000-8000-0000000000b1'), 1, 'companion: matching by name never creates a duplicate');
select throws_ok(format($$select public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'Jane Synthetic', null, %L, null, null, 906700001, 'wrong folder')$$,
    'e2000000-0000-4000-8000-0000000000ee/2c1c2c1c-0000-4000-8000-000000000001.jpg'),
  '22023', 'photo path is not this companion''s', 'companion: a photo path under another folder is refused');
select throws_ok(format($$select public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'Jane Synthetic', null, %L, null, null, 906700001, 'name in path')$$,
    current_setting('cascade.companion_id') || '/jane-synthetic-passport.jpg'),
  '22023', 'photo path is not this companion''s', 'companion: a path that is not <uuid>.<ext> (a name in the path) is refused');
select throws_ok(format($$select public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'Jane Synthetic', null, %L, null, null, 906700001, 'no object')$$,
    current_setting('cascade.companion_id') || '/2c1c2c1c-0000-4000-8000-000000000001.jpg'),
  'P0002', 'photo object not found in guest-id-photos', 'companion: a path with no uploaded object is refused');
insert into storage.objects(bucket_id, name) values ('guest-id-photos', current_setting('cascade.companion_id') || '/2c1c2c1c-0000-4000-8000-000000000001.jpg');
select is((public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b1', 'Jane Synthetic', 'drivers_license',
    current_setting('cascade.companion_id') || '/2c1c2c1c-0000-4000-8000-000000000001.jpg', null, 'Photo added', 906700001, 'Telegram /guest photo')) ->> 'unchanged', 'false',
  'companion: with the object uploaded the photo path saves');
select is((select id_photo_path || '|' || id_type || '|' || version::text from public.guest_companions where id = current_setting('cascade.companion_id')::uuid),
  current_setting('cascade.companion_id') || '/2c1c2c1c-0000-4000-8000-000000000001.jpg|drivers_license|2', 'companion: path, corrected type and version 2');
select is((select notes from public.guest_companions where id = current_setting('cascade.companion_id')::uuid), E'Seen at the gate\nPhoto added', 'companion: notes are appended');
select is((select count(*)::int from public.guest_companion_history where companion_id = current_setting('cascade.companion_id')::uuid), 2, 'companion: create and photo left two history rows');
select is((select h.before_state ->> 'id_photo_path' is null and h.after_state ->> 'id_photo_path' is not null
             from public.guest_companion_history h where h.companion_id = current_setting('cascade.companion_id')::uuid order by h.changed_at desc, h.id limit 1), true,
  'companion: the history row records the photo path moving from null to set');
select is((select changed_by from public.guest_companion_history where companion_id = current_setting('cascade.companion_id')::uuid and before_state is null), 'e2000000-0000-4000-8000-0000000000a1'::uuid,
  'companion: history changed_by is the staff user');
select is((public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b2', 'Owen Synthetic', null, null, null, null, 906700005, 'owner without property row')) ->> 'created', 'true',
  'companion: an owner without a property row can save');
select ok((select count(*) from (select public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b3', 'Extra ' || chr(64 + i), null, null, null, null, 906700001, 'fill to twelve')
            from generate_series(1, 12) i) s) = 12, 'companion: twelve companions fit on one guest');
select throws_ok($$select public.telegram_save_guest_companion_v1('e2000000-0000-4000-8000-0000000000b3', 'Extra Z', null, null, null, null, 906700001, 'one too many')$$,
  '22023', 'too many companions on this guest', 'companion: the thirteenth is refused');

select * from finish();
rollback;
