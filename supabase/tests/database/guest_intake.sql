-- Session 74, SPEC-42 s4b: guest self-service intake RPCs. Synthetic property, guests, bookings and tokens only, inside begin/rollback.
-- Tokens are looked up by hash, so each case stores a made-up 64-hex hash. Fake storage objects are plain storage.objects rows.
begin;
select plan(55);

-- 1-5 the surface
select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""']) from pg_proc p where p.pronamespace = 'public'::regnamespace
            and p.proname in ('intake_resolve_v1', 'intake_uploads_today_v1', 'intake_guest_context_v1', 'intake_save_guest_details_v1', 'intake_save_guest_companion_v1')),
  'all five are security definer with an empty search_path');
select ok(has_function_privilege('service_role', 'public.intake_guest_context_v1(text)', 'execute')
      and has_function_privilege('service_role', 'public.intake_save_guest_details_v1(text,jsonb)', 'execute')
      and has_function_privilege('service_role', 'public.intake_save_guest_companion_v1(text,text,text,text,text)', 'execute'),
  'service_role can execute the three public RPCs');
select ok(not has_function_privilege('anon', 'public.intake_guest_context_v1(text)', 'execute')
      and not has_function_privilege('authenticated', 'public.intake_guest_context_v1(text)', 'execute')
      and not has_function_privilege('anon', 'public.intake_save_guest_details_v1(text,jsonb)', 'execute')
      and not has_function_privilege('authenticated', 'public.intake_save_guest_details_v1(text,jsonb)', 'execute')
      and not has_function_privilege('anon', 'public.intake_save_guest_companion_v1(text,text,text,text,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.intake_save_guest_companion_v1(text,text,text,text,text)', 'execute'),
  'anon and authenticated cannot execute any of them');
select ok(not has_function_privilege('service_role', 'public.intake_resolve_v1(text)', 'execute')
      and not has_function_privilege('authenticated', 'public.intake_resolve_v1(text)', 'execute')
      and not has_function_privilege('service_role', 'public.intake_uploads_today_v1(uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.intake_uploads_today_v1(uuid,text)', 'execute'),
  'the two internal helpers are not callable by service_role or authenticated');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace = 'public'::regnamespace and p.proname like 'intake\_%' and a.grantee = 0),
  'PUBLIC has no execute grant on any of them');

-- 6-7 SPEC-40 / D-292: this release leaves the ID photo bucket and its policies exactly as they were
select ok((select not public and file_size_limit = 10485760 and allowed_mime_types = array['image/jpeg','image/png','image/webp'] from storage.buckets where id = 'guest-id-photos'),
  'the guest-id-photos bucket stays private, 10 MB, JPEG/PNG/WebP only');
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'guest id photos %' and 'anon' <> all(roles)), 3,
  'the three staff-only guest id photo policies are still there and none names anon');

-- Fixtures: A confirmed (booker g1), B pending, C cancelled, D confirmed but already checked out, E confirmed with no guest record.
-- The first 8 characters of each booking id differ, because the guest-facing ref is those 8 characters.
insert into public.properties(id, name, is_active) values ('e9100000-0000-4000-8000-0000000000a1', 'Synthetic Intake Property', true);
insert into public.guests(id, property_id, name) values
  ('e9300000-0000-4000-8000-0000000000a1', 'e9100000-0000-4000-8000-0000000000a1', 'Zz Intake Guest'),
  ('e9300000-0000-4000-8000-0000000000b2', 'e9100000-0000-4000-8000-0000000000a1', 'Zz Pending Guest');
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, total_amount, deposit_amount, source, status) values
  ('e9200001-0000-4000-8000-0000000000a1', 'e9100000-0000-4000-8000-0000000000a1', 'e9300000-0000-4000-8000-0000000000a1', 'Zz Intake Guest', 'zz-a@example.invalid', '0000000001', current_date + 10, current_date + 12, 3, 4000, 2000, 'direct', 'confirmed'),
  ('e9200002-0000-4000-8000-0000000000b2', 'e9100000-0000-4000-8000-0000000000a1', 'e9300000-0000-4000-8000-0000000000b2', 'Zz Pending Guest', 'zz-b@example.invalid', '0000000002', current_date + 20, current_date + 22, 2, 5000, 2500, 'direct', 'pending'),
  ('e9200003-0000-4000-8000-0000000000c3', 'e9100000-0000-4000-8000-0000000000a1', 'e9300000-0000-4000-8000-0000000000b2', 'Zz Cancelled Guest', 'zz-c@example.invalid', '0000000003', current_date + 30, current_date + 31, 1, 2000, 1000, 'direct', 'cancelled'),
  ('e9200004-0000-4000-8000-0000000000d4', 'e9100000-0000-4000-8000-0000000000a1', 'e9300000-0000-4000-8000-0000000000b2', 'Zz Past Guest', 'zz-d@example.invalid', '0000000004', current_date - 5, current_date - 3, 1, 2000, 1000, 'direct', 'confirmed'),
  ('e9200005-0000-4000-8000-0000000000e5', 'e9100000-0000-4000-8000-0000000000a1', null, 'Zz Nobody Guest', 'zz-e@example.invalid', '0000000005', current_date + 40, current_date + 41, 1, 2000, 1000, 'direct', 'confirmed');
insert into public.guest_access_tokens(property_id, booking_type, booking_id, token_hash, expires_at, revoked_at) values
  ('e9100000-0000-4000-8000-0000000000a1', 'direct', 'e9200001-0000-4000-8000-0000000000a1', repeat('a1', 32), now() + interval '30 days', null),
  ('e9100000-0000-4000-8000-0000000000a1', 'direct', 'e9200002-0000-4000-8000-0000000000b2', repeat('b2', 32), now() + interval '30 days', null),
  ('e9100000-0000-4000-8000-0000000000a1', 'direct', 'e9200003-0000-4000-8000-0000000000c3', repeat('c3', 32), now() + interval '30 days', null),
  ('e9100000-0000-4000-8000-0000000000a1', 'direct', 'e9200004-0000-4000-8000-0000000000d4', repeat('d4', 32), now() + interval '30 days', null),
  ('e9100000-0000-4000-8000-0000000000a1', 'direct', 'e9200005-0000-4000-8000-0000000000e5', repeat('e5', 32), now() + interval '30 days', null),
  ('e9100000-0000-4000-8000-0000000000a1', 'direct', 'e9200001-0000-4000-8000-0000000000a1', repeat('f6', 32), now() + interval '30 days', now()),
  ('e9100000-0000-4000-8000-0000000000a1', 'airbnb', 'e9200001-0000-4000-8000-0000000000a1', repeat('08', 32), now() + interval '30 days', null);
insert into public.guest_access_tokens(property_id, booking_type, booking_id, token_hash, expires_at, created_at) values
  ('e9100000-0000-4000-8000-0000000000a1', 'direct', 'e9200001-0000-4000-8000-0000000000a1', repeat('07', 32), now() - interval '1 day', now() - interval '10 days');

set local role service_role;

-- 8-18 the context read
select is(public.intake_guest_context_v1(repeat('a1', 32)) ->> 'ref', 'E9200001', 'a valid token returns its own booking ref');
select is((select array_agg(k order by k) from jsonb_object_keys(public.intake_guest_context_v1(repeat('a1', 32))) k),
  array['can_save','checkin_date','checkout_date','guest_name','max_uploads_per_day','pax','people','ref','uploads_today']::text[],
  'the context carries exactly the allowed keys: no phone, e-mail, address, door code, ID number or storage path');
select is(public.intake_guest_context_v1(repeat('00', 32)), null::jsonb, 'an unknown token returns null');
select is(public.intake_guest_context_v1('not-a-hash'), null::jsonb, 'a malformed hash returns null');
select is(public.intake_guest_context_v1(null), null::jsonb, 'a null token returns null');
select is(public.intake_guest_context_v1(repeat('07', 32)), null::jsonb, 'an expired token returns null');
select is(public.intake_guest_context_v1(repeat('f6', 32)), null::jsonb, 'a revoked token returns null');
select is(public.intake_guest_context_v1(repeat('08', 32)), null::jsonb, 'an Airbnb-type token returns null');
select is(public.intake_guest_context_v1(repeat('b2', 32)), null::jsonb, 'a pending booking returns null');
select is(public.intake_guest_context_v1(repeat('c3', 32)), null::jsonb, 'a cancelled booking returns null');
select is(public.intake_guest_context_v1(repeat('d4', 32)), null::jsonb, 'a booking already checked out returns null');
select is((public.intake_guest_context_v1(repeat('e5', 32)) ->> 'can_save')::boolean, false, 'a booking with no guest record shows but cannot save');

-- 19-26 the guest details write
select is(public.intake_save_guest_details_v1(null, '{"contact_number":"0917 000 1111"}'::jsonb), '{"ok": false, "reason": "invalid_token"}'::jsonb, 'token-less details write is refused');
select is(public.intake_save_guest_details_v1(repeat('b2', 32), '{"contact_number":"09170001111"}'::jsonb) ->> 'reason', 'invalid_token', 'a pending booking cannot write details');
select is(public.intake_save_guest_details_v1(repeat('c3', 32), '{"contact_number":"09170001111"}'::jsonb) ->> 'reason', 'invalid_token', 'a cancelled booking cannot write details');
select is(public.intake_save_guest_details_v1(repeat('e5', 32), '{"contact_number":"09170001111"}'::jsonb) ->> 'reason', 'no_guest_record', 'a booking with no guest record cannot write details');
select is(public.intake_save_guest_details_v1(repeat('a1', 32), '{"contact_number":"0917 000 1111","id_type":"passport","id_on_file":true}'::jsonb) ->> 'ok', 'true', 'a valid details write succeeds');
select is((public.intake_save_guest_details_v1(repeat('a1', 32), '{"contact_number":"09170001111","id_type":"passport"}'::jsonb) ->> 'unchanged')::boolean, true, 'the same details again change nothing');
select throws_ok($$select public.intake_save_guest_details_v1(repeat('a1', 32), '{"id_number":"123456789"}'::jsonb)$$, '22023', null, 'an ID number is not an allowed field');
select throws_ok($$select public.intake_save_guest_details_v1(repeat('a1', 32), '{"id_on_file":false}'::jsonb)$$, '22023', null, 'a guest cannot clear id_on_file');

-- 27-31 companion validation and creation
select throws_ok($$select public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Bad Phone', null, null, 'abc')$$, '22023', null, 'a bad contact number is refused');
select throws_ok($$select public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Number 123456', null, null, null)$$, '22023', null, 'a name with an ID-number-like run of digits is refused');
select throws_ok($$select public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Intake Guest', 'visa', null, null)$$, '22023', null, 'an unknown ID type is refused');
select is(public.intake_save_guest_companion_v1(null, 'Zz Intake Guest', null, null, null) ->> 'reason', 'invalid_token', 'token-less companion write is refused');
select ok(set_config('cascade.cid', public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Intake Guest', 'passport', null, '0917 000 1111') ->> 'id', true) is not null, 'a person is created from a valid token');

-- 32-33 a second save of the same name (any case or spacing) is the same person
select is((public.intake_save_guest_companion_v1(repeat('a1', 32), 'zz  INTAKE guest', null, null, null) ->> 'id'), current_setting('cascade.cid'), 'the same name in another case finds the same person');
select throws_ok($$select public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz New Person', null, 'x/y.jpg', null)$$, '22023', null, 'a photo cannot arrive with a person that does not exist yet');

-- 34-36 photo path rules
select throws_ok($$select public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Intake Guest', null, 'e9000000-0000-4000-8000-000000000000/2c1c2c1c-0000-4000-8000-000000000001.jpg', null)$$, '22023', null, 'a path under another person is refused');
select throws_ok($$select public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Intake Guest', null, current_setting('cascade.cid') || '/2c1c2c1c-0000-4000-8000-000000000001.gif', null)$$, '22023', null, 'a path with an extension the bucket does not take is refused');
select throws_ok($$select public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Intake Guest', null, current_setting('cascade.cid') || '/2c1c2c1c-0000-4000-8000-000000000001.jpg', null)$$, 'P0002', null, 'a path with no object in the bucket is refused');

reset role;
insert into storage.objects(bucket_id, name) values
  ('guest-id-photos', current_setting('cascade.cid') || '/2c1c2c1c-0000-4000-8000-000000000001.jpg'),
  ('guest-id-photos', current_setting('cascade.cid') || '/2c1c2c1c-0000-4000-8000-000000000002.jpg');
set local role service_role;

-- 37-38 attach a photo
select is((public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Intake Guest', null, current_setting('cascade.cid') || '/2c1c2c1c-0000-4000-8000-000000000001.jpg', null) ->> 'unchanged')::boolean, false, 'a photo whose object exists attaches');
select is((public.intake_guest_context_v1(repeat('a1', 32)) -> 'people' -> 0 ->> 'has_id')::boolean, true, 'the context now shows that person has an ID, without the path');

reset role;
-- 39-45 what was written, and with what provenance
select is((select contact_number from public.guest_companions where id = current_setting('cascade.cid')::uuid), '09170001111', 'the companion contact is stored without spaces');
select is((select id_type from public.guest_companions where id = current_setting('cascade.cid')::uuid), 'passport', 'the companion ID type is stored');
select ok((select id_photo_path = current_setting('cascade.cid') || '/2c1c2c1c-0000-4000-8000-000000000001.jpg' and created_by is null and updated_by is null from public.guest_companions where id = current_setting('cascade.cid')::uuid),
  'the photo path is linked and no staff user is claimed as the author');
select ok((select count(*) = 2 and bool_and(changed_by is null and reason = 'guest form E9200001') from public.guest_companion_history where companion_id = current_setting('cascade.cid')::uuid),
  'the companion history has the create and the attach, each with reason guest form <ref> and no changed_by');
select ok((select contact_number = '09170001111' and id_type = 'passport' and id_on_file and contact_provenance -> 'last_change' ->> 'via' = 'guest_form' and contact_provenance -> 'last_change' ->> 'ref' = 'E9200001'
             from public.guest_profile_details where guest_id = 'e9300000-0000-4000-8000-0000000000a1'),
  'the guest details carry the guest form provenance');
select ok((select count(*) = 1 and bool_and(changed_by is null and reason = 'guest form E9200001') from public.guest_profile_history where guest_id = 'e9300000-0000-4000-8000-0000000000a1'),
  'one profile history row, reason guest form <ref>');
select is((select count(*)::int from public.guest_companions where guest_id = 'e9300000-0000-4000-8000-0000000000b2'), 0, 'a refused token wrote nothing for the other guest');

-- 46-48 the 12 a day limit: 11 more linked photos in the history make 12; the 13th is refused and writes nothing
insert into public.guest_companion_history(companion_id, guest_id, changed_by, before_state, after_state, reason)
select current_setting('cascade.cid')::uuid, 'e9300000-0000-4000-8000-0000000000a1', null, jsonb_build_object('id_photo_path', 'old-' || n), jsonb_build_object('id_photo_path', 'new-' || n), 'guest form E9200001'
  from generate_series(1, 11) n;
set local role service_role;
select is((public.intake_guest_context_v1(repeat('a1', 32)) ->> 'uploads_today')::int, 12, 'uploads_today counts the linked photos');
select is(public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Intake Guest', null, current_setting('cascade.cid') || '/2c1c2c1c-0000-4000-8000-000000000002.jpg', null) ->> 'reason', 'rate_limited', 'the 13th photo in a day is refused');
reset role;
select is((select id_photo_path from public.guest_companions where id = current_setting('cascade.cid')::uuid), current_setting('cascade.cid') || '/2c1c2c1c-0000-4000-8000-000000000001.jpg', 'a refused photo leaves the linked photo alone');

-- 49-50 the 12 people cap
insert into public.guest_companions(guest_id, property_id, name)
select 'e9300000-0000-4000-8000-0000000000a1', 'e9100000-0000-4000-8000-0000000000a1', 'Zz Filler ' || chr(64 + n::int) from generate_series(1, 11) n;
set local role service_role;
select throws_ok($$select public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz One Too Many', null, null, null)$$, '22023', null, 'a 13th person on one stay is refused');
select is((public.intake_save_guest_companion_v1(repeat('a1', 32), 'Zz Filler A', 'other', null, null) ->> 'created')::boolean, false, 'an existing person can still be updated at the cap');
reset role;

-- 51-54 the context never carries a path or contact, and the purge queue stays clean
select ok((select not (public.intake_guest_context_v1(repeat('a1', 32))::text like '%2c1c2c1c%' or public.intake_guest_context_v1(repeat('a1', 32))::text like '%09170001111%')), 'no storage path or phone number in the context text');
select is((public.intake_guest_context_v1(repeat('a1', 32)) ->> 'uploads_today')::int, 12, 'the context still reads 12 for the day');
select is((select count(*)::int from public.guest_id_photo_purge_queue where path like current_setting('cascade.cid') || '/%'), 0, 'attaching a first photo queues nothing for purge');
select is((select count(*)::int from public.guest_companions where guest_id = 'e9300000-0000-4000-8000-0000000000a1'), 12, 'the stay holds exactly 12 people');

select * from finish();
rollback;
