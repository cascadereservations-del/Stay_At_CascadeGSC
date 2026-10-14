-- Session 82, lane XS: release s82_inbox_push_20261016. Push topics on a phone (paid, inbox), the owner/admin-only inbox topic, the recipients read, the
-- once-only claim and its purge by the weekly sweep, and a hand-typed brownout notice. Synthetic fixtures only (own property, own users, uuids d8400000-...);
-- every lookup is scoped to them, so the suite passes on a restored production copy. Grant-by-role facts that a --no-acl restore cannot show are asserted
-- by calling as the role (the release's own revokes are real), the rest by the release's forward checks. Everything rolls back.
begin;
select plan(73);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
grant execute on function public.notices_v1(uuid) to authenticated, service_role;
grant select, insert, update on public.ops_notices to authenticated;

create temp table _t(k text primary key, v jsonb);
grant all on _t to public;
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2', 'iat', 1790000000)::text, true),
         set_config('role', 'authenticated', true);
$$;
create function pg_temp.as_service() returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true), set_config('role', 'service_role', true);
$$;

-- fixtures: a cleaner, an admin, an owner, a finance person, a disabled admin and a person with no profile; one property of their own
insert into public.properties(id, name, is_active) values ('d8400000-0000-4000-8000-0000000000f1', 'Synthetic S82 inbox', true);
insert into auth.users(id, email) values
  ('d8400000-0000-4000-8000-0000000000a1', 'zz-xs-cleaner@example.com'), ('d8400000-0000-4000-8000-0000000000a2', 'zz-xs-admin@example.com'),
  ('d8400000-0000-4000-8000-0000000000a3', 'zz-xs-owner@example.com'), ('d8400000-0000-4000-8000-0000000000a4', 'zz-xs-finance@example.com'),
  ('d8400000-0000-4000-8000-0000000000a5', 'zz-xs-gone@example.com'), ('d8400000-0000-4000-8000-0000000000a6', 'zz-xs-ghost@example.com'),
  ('d8400000-0000-4000-8000-0000000000a7', 'zz-xs-outside@example.com');
insert into public.staff_access_profiles(user_id, role, disabled_at) values
  ('d8400000-0000-4000-8000-0000000000a1', 'cleaner', null), ('d8400000-0000-4000-8000-0000000000a2', 'admin', null),
  ('d8400000-0000-4000-8000-0000000000a3', 'owner', null), ('d8400000-0000-4000-8000-0000000000a4', 'finance', null),
  ('d8400000-0000-4000-8000-0000000000a5', 'admin', null), ('d8400000-0000-4000-8000-0000000000a7', 'admin', null); -- a7: active, but has no access to the fixture property
insert into public.staff_property_access(user_id, property_id) select u, 'd8400000-0000-4000-8000-0000000000f1'
  from unnest(array['d8400000-0000-4000-8000-0000000000a1', 'd8400000-0000-4000-8000-0000000000a2', 'd8400000-0000-4000-8000-0000000000a3',
                    'd8400000-0000-4000-8000-0000000000a4', 'd8400000-0000-4000-8000-0000000000a5']::uuid[]) u;

-- =============================================================== 1. subscribe without topics: as before
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a2');
insert into _t select 'old1', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin1', repeat('p', 87), repeat('a', 22), 'zz agent');
reset role;
select is((select v from _t where k = 'old1'), '{"ok": true}'::jsonb, 'no topics asked: the answer is exactly {ok:true}, as before');
select is((select topics from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-admin1'), array['paid', 'notices'], 'and the phone listens for the paid notice and the notices (on by default)');
select is((select count(*)::int from pg_proc where pronamespace = 'public'::regnamespace and proname = 'staff_push_subscribe_v1'), 1, 'there is one subscribe function, so a four-key RPC call is not ambiguous');

-- =============================================================== 2. topics: merge, never remove
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a2');
insert into _t select 'inbox_only', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin2', repeat('p', 87), repeat('a', 22), 'zz agent', array['inbox']);
insert into _t select 'add_paid', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin2', repeat('p', 87), repeat('a', 22), 'zz agent', array['paid']);
insert into _t select 'again_inbox', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin2', repeat('p', 87), repeat('a', 22), 'zz agent', array['inbox']);
insert into _t select 'plain_again', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin2', repeat('p', 87), repeat('a', 22), 'zz agent');
reset role;
select is((select v from _t where k = 'inbox_only'), '{"ok": true, "topics": ["inbox"]}'::jsonb, 'an admin asks for inbox only: kept, and the answer names the topics');
select is((select v from _t where k = 'add_paid'), '{"ok": true, "topics": ["inbox", "paid"]}'::jsonb, 'asking for paid on the same phone adds it and keeps inbox');
select is((select v from _t where k = 'again_inbox'), '{"ok": true, "topics": ["inbox", "paid"]}'::jsonb, 'asking for inbox alone again never removes paid');
select is((select topics from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-admin2'), array['inbox', 'paid'], 'one row holds both');
select is((select topics from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-admin2'), array['inbox', 'paid'], 'and an old-style call without topics leaves them alone');
select is((select count(*)::int from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-admin2'), 1, 'still one phone, one row');

select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'owner_both', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-owner1', repeat('p', 87), repeat('a', 22), null, array['paid', 'inbox', 'inbox']);
reset role;
select is((select v from _t where k = 'owner_both'), '{"ok": true, "topics": ["inbox", "paid"]}'::jsonb, 'an owner gets both, a repeated topic once');

-- =============================================================== 3. roles: inbox is for owner/admin only
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'cl_inbox', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-cleaner1', repeat('p', 87), repeat('a', 22), null, array['inbox']);
insert into _t select 'cl_both', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-cleaner2', repeat('p', 87), repeat('a', 22), null, array['paid', 'inbox']);
reset role;
select is((select v from _t where k = 'cl_inbox'), '{"ok": true, "topics": ["paid"]}'::jsonb, 'a cleaner asking for inbox alone keeps the paid topic only, and is told so');
select is((select v from _t where k = 'cl_both'), '{"ok": true, "topics": ["paid"]}'::jsonb, 'a cleaner asking for both keeps paid');
select is((select topics from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-cleaner1'), array['paid'], 'her row never holds inbox');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a4');
insert into _t select 'fin_inbox', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-fin1', repeat('p', 87), repeat('a', 22), null, array['inbox']);
reset role;
select is((select v from _t where k = 'fin_inbox'), '{"ok": true, "topics": ["paid"]}'::jsonb, 'a finance person does not get the inbox either');

select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a2');
insert into _t select 'junk', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin3', repeat('p', 87), repeat('a', 22), null, array['junk']);
insert into _t select 'empty', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin3', repeat('p', 87), repeat('a', 22), null, array[]::text[]);
insert into _t select 'mixed', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin3', repeat('p', 87), repeat('a', 22), null, array['inbox', 'junk']);
insert into _t select 'badurl', public.staff_push_subscribe_v1('http://fcm.googleapis.com/fcm/send/zz-xs-admin3', repeat('p', 87), repeat('a', 22), null, array['inbox']);
reset role;
select is((select v->>'reason' from _t where k = 'junk'), 'bad_topics', 'an unknown topic is refused');
select is((select v->>'reason' from _t where k = 'empty'), 'bad_topics', 'an empty list is refused');
select is((select v->>'reason' from _t where k = 'mixed'), 'bad_topics', 'one unknown topic among good ones refuses the lot');
select is((select v->>'reason' from _t where k = 'badurl'), 'bad_request', 'the endpoint rules are the same as before');
select is((select count(*)::int from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-admin3'), 0, 'and none of those wrote a row');

select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a6');
insert into _t select 'ghost', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-ghost', repeat('p', 87), repeat('a', 22), null, array['inbox']);
insert into _t select 'ghost_off', public.staff_push_unsubscribe_topic_v1('https://fcm.googleapis.com/fcm/send/zz-xs-ghost', 'inbox');
reset role;
select is((select v->>'reason' from _t where k = 'ghost'), 'not_authorized', 'no profile, no push subscription');
select is((select v->>'reason' from _t where k = 'ghost_off'), 'not_authorized', 'and no unsubscribe');

-- a phone moved to someone else does not carry the previous person's inbox topic
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'moved', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin2', repeat('q', 87), repeat('b', 22), null, array['inbox']);
reset role;
select is((select v from _t where k = 'moved'), '{"ok": true, "topics": ["paid"]}'::jsonb, 'the admin''s phone signed in as the cleaner: she gets paid only');
select is((select user_id::text from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-admin2'), 'd8400000-0000-4000-8000-0000000000a1', 'and the phone moved to her');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'moved_plain', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin2', repeat('q', 87), repeat('b', 22), null);
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'moved_owner', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-admin2', repeat('r', 87), repeat('c', 22), null);
reset role;
select is((select topics from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-admin2'), array['paid', 'notices'], 'a topic-less call that moves a phone to someone else resets it to the default (paid and notices)');

-- =============================================================== 4. unsubscribe one topic
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'off_inbox', public.staff_push_unsubscribe_topic_v1('https://fcm.googleapis.com/fcm/send/zz-xs-owner1', 'inbox');
reset role;
select is((select v from _t where k = 'off_inbox'), '{"ok": true, "topics": ["paid"]}'::jsonb, 'removing inbox leaves paid');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'off_other', public.staff_push_unsubscribe_topic_v1('https://fcm.googleapis.com/fcm/send/zz-xs-owner1', 'paid');
reset role;
select is((select topics from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-owner1'), array['paid'], 'a cleaner cannot change the owner''s phone');
select is((select v->>'ok' from _t where k = 'off_other'), 'true', 'and is simply told nothing changed');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a3');
insert into _t select 'off_paid', public.staff_push_unsubscribe_topic_v1('https://fcm.googleapis.com/fcm/send/zz-xs-owner1', 'paid');
insert into _t select 'off_bad', public.staff_push_unsubscribe_topic_v1('https://fcm.googleapis.com/fcm/send/zz-xs-owner1', 'junk');
reset role;
select is((select v from _t where k = 'off_paid'), '{"ok": true, "topics": []}'::jsonb, 'removing the last topic answers an empty list');
select is((select count(*)::int from public.staff_push_subscriptions where endpoint = 'https://fcm.googleapis.com/fcm/send/zz-xs-owner1'), 0, 'and deletes the row');
select is((select v->>'reason' from _t where k = 'off_bad'), 'bad_request', 'an unknown topic is refused');

-- =============================================================== 5. recipients: inbox topic, active owner/admin only
-- direct rows for the cases the RPC will not create: a finance and a cleaner row that hold inbox, a disabled admin who holds inbox
insert into public.staff_push_subscriptions(user_id, endpoint, p256dh, auth, topics) values
  ('d8400000-0000-4000-8000-0000000000a4', 'https://fcm.googleapis.com/fcm/send/zz-xs-r-fin', repeat('p', 87), repeat('a', 22), '{inbox}'),
  ('d8400000-0000-4000-8000-0000000000a1', 'https://fcm.googleapis.com/fcm/send/zz-xs-r-cl', repeat('p', 87), repeat('a', 22), '{paid,inbox}'),
  ('d8400000-0000-4000-8000-0000000000a5', 'https://fcm.googleapis.com/fcm/send/zz-xs-r-gone', repeat('p', 87), repeat('a', 22), '{inbox}'),
  ('d8400000-0000-4000-8000-0000000000a2', 'https://fcm.googleapis.com/fcm/send/zz-xs-r-adm-paid', repeat('p', 87), repeat('a', 22), '{paid}'),
  ('d8400000-0000-4000-8000-0000000000a2', 'https://fcm.googleapis.com/fcm/send/zz-xs-r-adm', repeat('p', 87), repeat('a', 22), '{inbox}'),
  ('d8400000-0000-4000-8000-0000000000a3', 'https://fcm.googleapis.com/fcm/send/zz-xs-r-owner', repeat('p', 87), repeat('a', 22), '{inbox,paid}');
update public.staff_access_profiles set disabled_at = now() where user_id = 'd8400000-0000-4000-8000-0000000000a5';
select pg_temp.as_service();
create temp table _rcpt as select * from public.staff_push_inbox_recipients_v1();
reset role;
grant select on _rcpt to public;
select is((select array_agg(endpoint order by endpoint) from _rcpt where endpoint like '%zz-xs-%'),
          array['https://fcm.googleapis.com/fcm/send/zz-xs-r-adm', 'https://fcm.googleapis.com/fcm/send/zz-xs-r-owner']::text[],
          'recipients are the active owner/admin phones that hold inbox, nobody else');
select is((select count(*)::int from _rcpt where endpoint like '%zz-xs-r-gone'), 0, 'a disabled admin is excluded');
select is((select count(*)::int from _rcpt where endpoint like '%zz-xs-r-fin' or endpoint like '%zz-xs-r-cl'), 0, 'a finance or cleaner row is excluded even if it somehow holds inbox');
select is((select count(*)::int from _rcpt where endpoint like '%zz-xs-r-adm-paid'), 0, 'an admin phone that holds paid only is excluded');
select is((select array_agg(a.attname::text order by a.attnum) from pg_attribute a where a.attrelid = '_rcpt'::regclass and a.attnum > 0 and not a.attisdropped),
          array['id', 'endpoint', 'p256dh', 'auth'], 'the read returns the id and the keys the sender needs, and no user id or name');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a2');
select throws_ok($$select * from public.staff_push_inbox_recipients_v1()$$, '42501', null, 'an admin session cannot read the recipients');
reset role;

-- =============================================================== 5b. notices: the topic for every active role, and who is told
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'n_only', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-cleaner3', repeat('p', 87), repeat('a', 22), null, array['notices']);
insert into _t select 'n_merge', public.staff_push_subscribe_v1('https://fcm.googleapis.com/fcm/send/zz-xs-cleaner3', repeat('p', 87), repeat('a', 22), null, array['paid']);
insert into _t select 'n_off', public.staff_push_unsubscribe_topic_v1('https://fcm.googleapis.com/fcm/send/zz-xs-cleaner3', 'notices');
reset role;
select is((select v from _t where k = 'n_only'), '{"ok": true, "topics": ["notices"]}'::jsonb, 'a cleaner may hold the notices topic');
select is((select v from _t where k = 'n_merge'), '{"ok": true, "topics": ["notices", "paid"]}'::jsonb, 'and asking for paid later keeps it');
select is((select v from _t where k = 'n_off'), '{"ok": true, "topics": ["paid"]}'::jsonb, 'turning notices off leaves paid');

insert into public.staff_push_subscriptions(user_id, endpoint, p256dh, auth, topics) values
  ('d8400000-0000-4000-8000-0000000000a1', 'https://fcm.googleapis.com/fcm/send/zz-xs-n-cl', repeat('p', 87), repeat('a', 22), '{notices}'),
  ('d8400000-0000-4000-8000-0000000000a4', 'https://fcm.googleapis.com/fcm/send/zz-xs-n-fin', repeat('p', 87), repeat('a', 22), '{notices}'),
  ('d8400000-0000-4000-8000-0000000000a5', 'https://fcm.googleapis.com/fcm/send/zz-xs-n-gone', repeat('p', 87), repeat('a', 22), '{notices}'),
  ('d8400000-0000-4000-8000-0000000000a7', 'https://fcm.googleapis.com/fcm/send/zz-xs-n-out', repeat('p', 87), repeat('a', 22), '{notices}'),
  ('d8400000-0000-4000-8000-0000000000a2', 'https://fcm.googleapis.com/fcm/send/zz-xs-n-adm-paid', repeat('p', 87), repeat('a', 22), '{paid}');
select pg_temp.as_service();
create temp table _nrcpt as select * from public.staff_push_notice_recipients_v1('d8400000-0000-4000-8000-0000000000f1');
reset role;
grant select on _nrcpt to public;
select is((select array_agg(endpoint order by endpoint) from _nrcpt where endpoint like '%zz-xs-%'),
          array['https://fcm.googleapis.com/fcm/send/zz-xs-admin1', 'https://fcm.googleapis.com/fcm/send/zz-xs-admin2',
                'https://fcm.googleapis.com/fcm/send/zz-xs-n-cl', 'https://fcm.googleapis.com/fcm/send/zz-xs-n-fin']::text[],
          'notice recipients: every active staff phone of the property that holds notices (a default phone, a cleaner, a finance person), in any role');
select is((select count(*)::int from _nrcpt where endpoint like '%zz-xs-n-gone'), 0, 'a disabled person is excluded');
select is((select count(*)::int from _nrcpt where endpoint like '%zz-xs-n-out'), 0, 'an active person with no access to the property is excluded');
select is((select count(*)::int from _nrcpt where endpoint like '%zz-xs-n-adm-paid' or endpoint like '%zz-xs-r-%' or endpoint like '%zz-xs-cleaner1'), 0, 'a phone that does not hold notices is excluded');
select is((select array_agg(a.attname::text order by a.attnum) from pg_attribute a where a.attrelid = '_nrcpt'::regclass and a.attnum > 0 and not a.attisdropped),
          array['id', 'endpoint', 'p256dh', 'auth'], 'the notice read returns the id and the keys, no user id or name');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a2');
select throws_ok($$select * from public.staff_push_notice_recipients_v1()$$, '42501', null, 'a staff session cannot read the notice recipients');
reset role;
select ok(exists (select 1 from pg_trigger where tgname = 'ops_notices_push' and tgrelid = 'public.ops_notices'::regclass and not tgisinternal), 'the brownout/water trigger is on ops_notices');
select ok(not has_function_privilege('authenticated', 'public.ops_notices_push_trg()', 'execute') and not has_function_privilege('anon', 'public.ops_notices_push_trg()', 'execute'), 'and no API role can run its function');

-- =============================================================== 6. claim: once per key
select pg_temp.as_service();
insert into _t select 'c1', to_jsonb(public.staff_push_claim_v1('zz-xs:handover:one'));
insert into _t select 'c2', to_jsonb(public.staff_push_claim_v1('zz-xs:handover:one'));
insert into _t select 'c3', to_jsonb(public.staff_push_claim_v1('zz-xs:handover:two'));
insert into _t select 'c4', to_jsonb(public.staff_push_claim_v1(null));
insert into _t select 'c5', to_jsonb(public.staff_push_claim_v1(repeat('k', 201)));
reset role;
select is((select v from _t where k = 'c1'), 'true'::jsonb, 'the first claim of a key is true');
select is((select v from _t where k = 'c2'), 'false'::jsonb, 'the second is false');
select is((select v from _t where k = 'c3'), 'true'::jsonb, 'another key is its own claim');
select is((select v from _t where k = 'c4'), 'false'::jsonb, 'a null key claims nothing');
select is((select v from _t where k = 'c5'), 'false'::jsonb, 'nor does an over-long one');
select is((select count(*)::int from public.staff_push_claims where key like 'zz-xs:%'), 2, 'two rows were written');
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a2');
select throws_ok($$select public.staff_push_claim_v1('zz-xs:handover:three')$$, '42501', null, 'a staff session cannot claim');
reset role;
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a2');
select throws_ok($$select count(*) from public.staff_push_claims$$, '42501', null, 'and cannot read the claims table');
reset role;

-- =============================================================== 7. the weekly sweep purges claims older than 7 days
insert into public.staff_push_claims(key, claimed_at) values ('zz-xs:old', now() - interval '8 days'), ('zz-xs:fresh', now() - interval '6 days');
insert into _t select 'sweep', public.s_weekly_sweep_v1();
select is((select count(*)::int from public.staff_push_claims where key = 'zz-xs:old'), 0, 'a claim older than 7 days is purged by the sweep');
select is((select count(*)::int from public.staff_push_claims where key in ('zz-xs:fresh', 'zz-xs:handover:one')), 2, 'a recent claim stays');
select ok((select v ? 'purged_push_claims' and v ? 'purged_upload_hashes' and v ? 'purged_progress_rows' and v ? 'paid_notices_asked' from _t where k = 'sweep'), 'and the sweep still reports its other counts');

-- =============================================================== 8. a hand-typed brownout
select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a2');
insert into _t select 'bo', public.ops_notice_add_v1('brownout', 'Brownout 1:00 to 4:00 pm', (now() at time zone 'Asia/Manila')::date + 1, '13:00', 3, 'Line maintenance on our street', 'd8400000-0000-4000-8000-0000000000f1');
select throws_ok($$select public.ops_notice_add_v1('brownout', 'Call 0917 123 4567', current_date + 1, null, null, null, 'd8400000-0000-4000-8000-0000000000f1')$$,
  '22023', 'contact_or_amount_not_allowed', 'a brownout title with a phone number is refused');
select throws_ok($$select public.ops_notice_add_v1('brownout', 'Brownout', current_date + 1, null, null, 'refund P500 to zz@example.com', 'd8400000-0000-4000-8000-0000000000f1')$$,
  '22023', 'contact_or_amount_not_allowed', 'so is a detail with an amount or an e-mail');
select throws_ok($$select public.ops_notice_add_v1('holiday', 'Zz', current_date + 1, null, null, null, 'd8400000-0000-4000-8000-0000000000f1')$$,
  '22023', 'type_not_allowed', 'the other types stay refused');
select throws_ok($$select public.ops_notice_add_v1('brownout', 'Zz', current_date + 400, null, null, null, 'd8400000-0000-4000-8000-0000000000f1')$$,
  '22023', 'date_out_of_range', 'the date rule still applies');
select throws_ok($$select public.ops_notice_add_v1('brownout', 'Zz', current_date + 1, '13:00', 100, null, 'd8400000-0000-4000-8000-0000000000f1')$$,
  '22023', 'duration_out_of_range', 'and the duration rule');
reset role;
select is((select v->>'type' from _t where k = 'bo'), 'brownout', 'an admin adds a brownout');
select is((select source || '/' || notice_type from public.ops_notices where id = (select (v->>'id')::uuid from _t where k = 'bo')), 'manual/brownout', 'it is stored as a manual brownout');

select pg_temp.as_user('d8400000-0000-4000-8000-0000000000a1');
insert into _t select 'cl_notices', public.notices_v1('d8400000-0000-4000-8000-0000000000f1');
select throws_ok($$select public.ops_notice_add_v1('brownout', 'Zz cleaner brownout', current_date + 1, null, null, null, 'd8400000-0000-4000-8000-0000000000f1')$$,
  '42501', 'forbidden', 'a cleaner cannot add a brownout');
select throws_ok($$select public.ops_notice_add_v1('note', 'Zz cleaner note', current_date + 1, null, null, null, 'd8400000-0000-4000-8000-0000000000f1')$$,
  '42501', 'forbidden', 'or any other notice');
reset role;
select is((select n->>'type' || '/' || (n->>'source') || '/' || (n->>'title') from _t, jsonb_array_elements(v->'notices') n where k = 'cl_notices' limit 1),
          'power/manual/Brownout 1:00 to 4:00 pm', 'the brownout shows for a cleaner as a power notice from a manual source');
select is((select n->>'end_time' from _t, jsonb_array_elements(v->'notices') n where k = 'cl_notices' limit 1), '16:00', 'with its end time worked out');
select is((select array_agg(nk.key order by nk.key) from _t, jsonb_array_elements(v->'notices') n, jsonb_object_keys(n) as nk(key) where _t.k = 'cl_notices'),
          array['date', 'detail', 'duration_hours', 'end_time', 'id', 'source', 'start_time', 'title', 'type', 'url']::text[],
          'the notice carries only the allow-listed keys');
select ok((select v::text !~* '(payout|price|gross_amount|guest_email|guest_phone|psid|0917|@example)' from _t where k = 'cl_notices'), 'and the cleaner payload names no contact or money');
select ok((select v->>'inbox_open' is null and v->'house' = '[]'::jsonb from _t where k = 'cl_notices'), 'and still hides the house list and the inbox count');

-- =============================================================== 9. the rain-alert cron job signs its call (true where pg_cron is absent or the job is not scheduled on this copy)
select ok(case when to_regclass('cron.job') is null then true
               else (xpath('/row/c/text()', query_to_xml('select count(*)::text as c from cron.job where jobname = ''rain-alert-2h'' and command not like ''%cascade_cron_shared_secret%''', false, true, '')))[1]::text = '0' end,
          'rain-alert-2h, when scheduled, reads the vault secret for x-cascade-cron-secret');

select * from finish();
rollback;
