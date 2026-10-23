-- Session 96 (lane SQL): release s96_spec47_20261029. guest_topics, record_guest_topic_v1 (upsert, silent no-ops), purge_guest_topics_v1 (365 days since last_seen),
-- staff_guest_card_v1 notable key (max 3, newest first, one per topic, [] when none, every old key unchanged) and the grants.
-- The ID photo release was REMOVED from this release (D-346: photos stay until staff delete them): a test below proves guest_companions is untouched.
-- Synthetic fixtures only (uuids f9600000-...); every lookup is scoped to them because a real backup holds real rows. Everything rolls back.
begin;
select plan(56);

grant usage on schema public to anon, authenticated, service_role;

insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.guests(id, property_id, name) values
  ('f9600000-0000-4000-8000-0000000000c1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S96 Writer'),
  ('f9600000-0000-4000-8000-0000000000c2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S96 Empty'),
  ('f9600000-0000-4000-8000-0000000000c3', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S96 Notable'),
  ('f9600000-0000-4000-8000-0000000000c4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S96 Returning'),
  ('f9600000-0000-4000-8000-0000000000c5', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S96 Deleted');

-- 1. record_guest_topic_v1 ---------------------------------------------------------------------------------------------------------------------
select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c1', 'f9600000-0000-4000-8000-0000000000b1', 'wifi', 'airbnb');
select is((select hits from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c1' and topic = 'wifi' and source = 'airbnb'), 1, 'first record: one row, hits 1');
update public.guest_topics set last_seen = now() - interval '2 days', first_seen = now() - interval '2 days' where guest_id = 'f9600000-0000-4000-8000-0000000000c1';
select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c1', null, 'wifi', 'airbnb');
select is((select hits from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c1' and topic = 'wifi' and source = 'airbnb'), 2, 'second record: still one row, hits 2');
select ok((select last_seen > first_seen + interval '1 day' from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c1' and topic = 'wifi' and source = 'airbnb'), 'last_seen moves, first_seen stays');
select is((select booking_id from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c1' and topic = 'wifi' and source = 'airbnb'), 'f9600000-0000-4000-8000-0000000000b1'::uuid, 'a later call with no booking keeps the booking already stored');
select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c1', null, 'wifi', 'messenger');
select is((select count(*)::int from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c1' and topic = 'wifi'), 2, 'the same topic from another source is its own row');
select lives_ok($$select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c1', null, 'gossip', 'airbnb')$$, 'an unknown topic does not raise');
select lives_ok($$select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c1', null, 'wifi', 'sms')$$, 'an unknown source does not raise');
select lives_ok($$select public.record_guest_topic_v1(null, null, 'wifi', 'airbnb')$$, 'a null guest does not raise');
select lives_ok($$select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000fe', null, 'wifi', 'airbnb')$$, 'an unknown guest does not raise');
select lives_ok($$select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c1', null, null, 'airbnb')$$, 'a null topic does not raise');
select is((select count(*)::int from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c1'), 2, 'and none of those wrote a row');
select is((select count(*)::int from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000fe' or guest_id is null), 0, 'no row for the unknown or null guest');
select throws_ok($$insert into public.guest_topics(guest_id, topic, source) values ('f9600000-0000-4000-8000-0000000000c1', 'gossip', 'airbnb')$$, '23514', null, 'the table CHECK refuses an unknown topic');
select throws_ok($$insert into public.guest_topics(guest_id, topic, source) values ('f9600000-0000-4000-8000-0000000000c1', 'wifi', 'sms')$$, '23514', null, 'the table CHECK refuses an unknown source');
select is((select count(*)::int from pg_attribute where attrelid = 'public.guest_topics'::regclass and attnum > 0 and not attisdropped and attname ~ '(text|message|body|content)'), 0, 'no column could hold message text');

-- all eleven topic keys are accepted
select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c2', null, t, 'staff')
  from unnest(array['directions','links','wifi','brownout','guest_count','early_checkin','late_checkout','parking','pets','id','complaint']) t;
select is((select count(*)::int from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c2'), 11, 'all eleven contract topics are accepted');
delete from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c2';

-- 2. purge_guest_topics_v1 ---------------------------------------------------------------------------------------------------------------------
update public.guest_topics set last_seen = now() - interval '366 days' where guest_id = 'f9600000-0000-4000-8000-0000000000c1' and source = 'messenger';
update public.guest_topics set last_seen = now() - interval '364 days' where guest_id = 'f9600000-0000-4000-8000-0000000000c1' and source = 'airbnb';
select is((select public.purge_guest_topics_v1()), 1, 'purge returns the number of rows it deleted (exactly the 366-day fixture)');
select is((select count(*)::int from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c1' and source = 'messenger'), 0, 'a topic unseen for 366 days is deleted');
select is((select count(*)::int from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c1' and source = 'airbnb'), 1, 'a topic unseen for 364 days is kept');
select is((select public.purge_guest_topics_v1()), 0, 'a second purge deletes nothing');
-- a returning guest keeps topics: c1 has no stay at all and its recent topic survived; a guest with an old stay keeps a recent topic too
insert into public.airbnb_reservations(property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZS96A1', 'completed', 'f9600000-0000-4000-8000-0000000000c4', 'Zz S96 Returning', current_date - 400, current_date - 398),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZS96A2', 'completed', 'f9600000-0000-4000-8000-0000000000c4', 'Zz S96 Returning', current_date - 200, current_date - 198);
select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c4', null, 'pets', 'staff');
select public.purge_guest_topics_v1();
select is((select count(*)::int from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c4'), 1, 'no stay-window rule: a guest whose last stay ended 198 days ago keeps a recent topic');

-- 3. on delete cascade -------------------------------------------------------------------------------------------------------------------------
select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c5', null, 'parking', 'staff');
delete from public.guests where id = 'f9600000-0000-4000-8000-0000000000c5';
select is((select count(*)::int from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c5'), 0, 'deleting the guest deletes its topics');

-- 4. staff_guest_card_v1 notable ---------------------------------------------------------------------------------------------------------------
insert into public.guest_topics(guest_id, topic, source, last_seen, first_seen) values
  ('f9600000-0000-4000-8000-0000000000c3', 'parking',  'airbnb',    now() - interval '1 hour',  now() - interval '1 hour'),
  ('f9600000-0000-4000-8000-0000000000c3', 'parking',  'messenger', now() - interval '90 minutes', now() - interval '90 minutes'),
  ('f9600000-0000-4000-8000-0000000000c3', 'wifi',     'messenger', now() - interval '2 hours', now() - interval '2 hours'),
  ('f9600000-0000-4000-8000-0000000000c3', 'pets',     'airbnb',    now() - interval '3 hours', now() - interval '3 hours'),
  ('f9600000-0000-4000-8000-0000000000c3', 'complaint','staff',     now() - interval '4 hours', now() - interval '4 hours');
select is(jsonb_array_length(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c3', current_date) -> 'notable'), 3, 'notable holds at most 3 entries');
select is((select jsonb_agg(e ->> 'topic') from jsonb_array_elements(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c3', current_date) -> 'notable') e),
  '["parking", "wifi", "pets"]'::jsonb, 'newest last_seen first, one entry per topic (parking 1h and 90 min old is listed once, so wifi and pets still fit)');
select is(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c3', current_date) -> 'notable' -> 0 ->> 'source', 'airbnb', 'a topic seen from two sources shows the source of the newest sighting');
select ok((select (e ? 'topic') and (e ? 'last_seen') and (e ? 'source') and (select count(*) from jsonb_object_keys(e)) = 3 and jsonb_typeof(e -> 'last_seen') = 'string'
             from jsonb_array_elements(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c3', current_date) -> 'notable') e limit 1), 'each entry is exactly {topic, last_seen, source}');
select is(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c2', current_date) -> 'notable', '[]'::jsonb, 'a guest with no topics: notable is an empty array');
select is(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', null, current_date) -> 'notable', '[]'::jsonb, 'no guest at all: notable is an empty array');
select is(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000fe', current_date) -> 'notable', '[]'::jsonb, 'an unknown guest: notable is an empty array');
select is(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid, 'f9600000-0000-4000-8000-0000000000c3', current_date) -> 'notable' -> 0 ->> 'topic', 'parking', 'sanity: the property scope matches');
select is(public.staff_guest_card_v1('f9600000-0000-4000-8000-0000000000aa', 'f9600000-0000-4000-8000-0000000000c3', current_date) -> 'notable', '[]'::jsonb, 'another property sees no topics of this guest');

-- every old key is unchanged: a guest with no stays, and a returning guest
select ok((select c ?& array['repeat', 'stay_count', 'earlier_stays', 'notes', 'id_photo_path', 'id_face_box', 'tier', 'tier_line', 'notable'] and (select count(*) from jsonb_object_keys(c)) = 9
             from (select public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c2', current_date) c) x), 'the card has its seven old keys, id_face_box (s97) and exactly one new one (notable)');
select is((select c - 'notable' - 'notes' - 'id_photo_path' - 'id_face_box' from (select public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c2', current_date) c) x),
  '{"repeat": false, "stay_count": 1, "earlier_stays": [], "tier": null, "tier_line": null}'::jsonb, 'no-stay guest: repeat, stay_count, earlier_stays, tier and tier_line as before (notes, id_photo_path, id_face_box and notable not compared)');
select public.refresh_guest_stats('f9600000-0000-4000-8000-0000000000c4');
select is((select c - 'notable' - 'notes' - 'id_photo_path' - 'id_face_box' - 'earlier_stays' from (select public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c4', current_date) c) x),
  jsonb_build_object('repeat', true, 'stay_count', 3, 'tier', 'returning', 'tier_line', public.guest_tier_line_v1('returning', 2)), 'returning guest: repeat, stay_count, tier and tier_line as before (notes, id_photo_path, id_face_box, notable and earlier_stays not compared)');
select is((select jsonb_array_length(c -> 'earlier_stays') from (select public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c4', current_date) c) x), 2, 'earlier_stays still lists both earlier stays');
select is((select c -> 'earlier_stays' -> 0 ->> 'month' from (select public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9600000-0000-4000-8000-0000000000c4', current_date) c) x),
  to_char(current_date - 198, 'YYYY-MM'), 'earlier_stays is still newest checkout first');
select ok(pg_get_function_result('public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure) = 'jsonb' and (select provolatile = 's' and prosecdef from pg_proc where oid = 'public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure),
  'the card keeps its signature, STABLE and SECURITY DEFINER');

-- 5. ID photos are untouched by this release (D-346) ---------------------------------------------------------------------------------------------
select is((select count(*)::int from pg_proc where proname in ('release_expired_id_photos_v1')), 0, 'there is no ID photo release function');
select is((select count(*)::int from pg_trigger where tgrelid = 'public.guest_companions'::regclass and tgname = 'guest_companions_release_photo' and not tgisinternal), 1, 'the SPEC-40 trigger on guest_companions is as it was');

-- 6. heartbeat ----------------------------------------------------------------------------------------------------------------------------------
select ok((select expected_interval_seconds = 172800 and not ops_risk and last_succeeded_at is not null from public.job_heartbeats where job_name = 'guest-retention-nightly'), 'guest-retention-nightly is seeded: 2 days, no ops risk, succeeded at apply');

-- 6b. guest_retention_nightly_v1 -------------------------------------------------------------------------------------------------------------------
update public.guest_topics set last_seen = now() - interval '400 days' where guest_id = 'f9600000-0000-4000-8000-0000000000c4';
select is((select public.guest_retention_nightly_v1()), 1, 'the nightly wrapper returns the rows it purged');
select is((select count(*)::int from public.guest_topics where guest_id = 'f9600000-0000-4000-8000-0000000000c4'), 0, 'and the old topic is gone');
select ok((select last_started_at is not null and last_succeeded_at >= last_started_at and consecutive_failures = 0 and last_error_code is null from public.job_heartbeats where job_name = 'guest-retention-nightly'),
  'the heartbeat shows a started and a succeeded run');
select ok(not has_function_privilege('anon', 'public.guest_retention_nightly_v1()', 'execute') and not has_function_privilege('authenticated', 'public.guest_retention_nightly_v1()', 'execute')
          and not has_function_privilege('service_role', 'public.guest_retention_nightly_v1()', 'execute'), 'no API role can run the wrapper');
select ok(not has_sequence_privilege('anon', 'public.guest_topics_id_seq', 'usage, select, update') and not has_sequence_privilege('authenticated', 'public.guest_topics_id_seq', 'usage, select, update')
          and not has_sequence_privilege('service_role', 'public.guest_topics_id_seq', 'usage, select, update'), 'no API role has any privilege on the id sequence');

-- 7. grants (the migration revokes explicitly, so they hold in a --no-acl rehearsal too) ----------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.record_guest_topic_v1(uuid,uuid,text,text)', 'execute'), 'anon cannot record a topic');
select ok(not has_function_privilege('authenticated', 'public.record_guest_topic_v1(uuid,uuid,text,text)', 'execute'), 'authenticated cannot record a topic');
select ok(has_function_privilege('service_role', 'public.record_guest_topic_v1(uuid,uuid,text,text)', 'execute'), 'service_role can record a topic');
select ok(not has_function_privilege('anon', 'public.purge_guest_topics_v1()', 'execute') and not has_function_privilege('authenticated', 'public.purge_guest_topics_v1()', 'execute')
          and not has_function_privilege('service_role', 'public.purge_guest_topics_v1()', 'execute'), 'no API role can run the purge');
select ok(not has_function_privilege('anon', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') and not has_function_privilege('authenticated', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute'), 'anon and authenticated cannot read the staff card');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where a.grantee = 0
                       and p.oid in ('public.record_guest_topic_v1(uuid,uuid,text,text)'::regprocedure, 'public.purge_guest_topics_v1()'::regprocedure, 'public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure)), 'PUBLIC holds no execute on any of the three');
select ok(not has_table_privilege('anon', 'public.guest_topics', 'select, insert, update, delete') and not has_table_privilege('authenticated', 'public.guest_topics', 'select, insert, update, delete')
          and not has_table_privilege('service_role', 'public.guest_topics', 'select, insert, update, delete'), 'no API role has any privilege on guest_topics');
select ok((select relrowsecurity from pg_class where oid = 'public.guest_topics'::regclass), 'guest_topics has RLS on');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'public.record_guest_topic_v1(uuid,uuid,text,text)'::regprocedure), 'record_guest_topic_v1 is SECURITY DEFINER with an empty search_path');
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'public.purge_guest_topics_v1()'::regprocedure), 'purge_guest_topics_v1 is SECURITY DEFINER with an empty search_path');

-- calling as the refused role really is refused
set local role anon;
select throws_ok($$select public.record_guest_topic_v1('f9600000-0000-4000-8000-0000000000c1', null, 'wifi', 'airbnb')$$, '42501', null, 'anon is refused when it calls record_guest_topic_v1');
reset role;

select * from finish();
rollback;
