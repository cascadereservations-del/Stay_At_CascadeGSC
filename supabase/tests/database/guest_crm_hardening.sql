begin;
select plan(28);

-- Functions keep their callable signatures (20260914260000)
select has_function('public','admin_audit_feed_v1',array['uuid','integer'],'audit feed RPC exists');
select has_function('public','preview_guest_merge_v1',array['uuid','uuid'],'merge preview RPC exists');
select has_function('public','merge_guests_v1',array['uuid','uuid','text','text'],'merge RPC exists');
select has_function('public','save_guest_profile_v1',array['uuid','jsonb','integer','text'],'profile save RPC exists');

-- anon is denied outright
select ok(not has_function_privilege('anon','public.merge_guests_v1(uuid,uuid,text,text)','execute'), 'anon cannot merge guests');
select ok(not has_function_privilege('anon','public.save_guest_profile_v1(uuid,jsonb,integer,text)','execute'), 'anon cannot save guest profiles');

-- Bucket limits and property-scoped storage policies
select is((select file_size_limit from storage.buckets where id = 'guest-id-photos')::bigint, 10485760::bigint, 'guest-id-photos capped at 10 MB');
select is((select cardinality(allowed_mime_types) from storage.buckets where id = 'guest-id-photos'), 3, 'guest-id-photos allows exactly JPEG, PNG and WebP');
select is(
  (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'guest id photos%'
     and coalesce(qual, with_check) like '%foldername%' and coalesce(qual, with_check) like '%guest_companions%')::int,
  3, 'all three photo policies check the companion/guest path'
);

-- Synthetic fixtures: two properties, an owner, a cleaner and a property-scoped admin.
insert into public.properties(id,name,is_active) values
  ('f5000000-0000-4000-8000-0000000000a1','Synthetic CRM A',true),
  ('f5000000-0000-4000-8000-0000000000b1','Synthetic CRM B',true);
insert into auth.users(id) values
  ('f5000000-0000-4000-8000-0000000000a2'),('f5000000-0000-4000-8000-0000000000a3'),('f5000000-0000-4000-8000-0000000000a5');
insert into public.staff_access_profiles(user_id,role) values
  ('f5000000-0000-4000-8000-0000000000a2','owner'),
  ('f5000000-0000-4000-8000-0000000000a3','cleaner'),
  ('f5000000-0000-4000-8000-0000000000a5','admin');
insert into public.staff_property_access(user_id,property_id) values
  ('f5000000-0000-4000-8000-0000000000a3','f5000000-0000-4000-8000-0000000000a1'),
  ('f5000000-0000-4000-8000-0000000000a5','f5000000-0000-4000-8000-0000000000a1');
-- gA1/gA2 share an e-mail (mergeable; phone is unique per property so it cannot be the shared
-- contact in fixtures); gA3 shares only the name; gA4 shares the e-mail but carries a profile row
-- (enriched); gB1 lives in the other property.
insert into public.guests(id,property_id,name,email) values
  ('f5000000-0000-4000-8000-0000000000c1','f5000000-0000-4000-8000-0000000000a1','Synthetic Guest','synthetic.guest@example.test'),
  ('f5000000-0000-4000-8000-0000000000c2','f5000000-0000-4000-8000-0000000000a1','Synthetic Guest','Synthetic.Guest@example.test'),
  ('f5000000-0000-4000-8000-0000000000c3','f5000000-0000-4000-8000-0000000000a1','Synthetic Guest',null),
  ('f5000000-0000-4000-8000-0000000000c4','f5000000-0000-4000-8000-0000000000a1','Synthetic Guest','synthetic.guest@example.test'),
  ('f5000000-0000-4000-8000-0000000000d1','f5000000-0000-4000-8000-0000000000b1','Synthetic Guest','synthetic.guest@example.test');
insert into public.guest_profile_details(guest_id,property_id) values ('f5000000-0000-4000-8000-0000000000c4','f5000000-0000-4000-8000-0000000000a1');
insert into public.guest_profile_history(guest_id,changed_by,before_state,after_state,reason) values
  ('f5000000-0000-4000-8000-0000000000c1','f5000000-0000-4000-8000-0000000000a2','{}'::jsonb,'{"id_number":"PRIVATE-TEST"}'::jsonb,'fixture');

-- Cleaner (read_operations, no manage_operations) can read the feed but no guest branch.
select set_config('request.jwt.claims', json_build_object('sub','f5000000-0000-4000-8000-0000000000a3','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select is(
  (select count(*) from jsonb_array_elements(public.admin_audit_feed_v1('f5000000-0000-4000-8000-0000000000a1'::uuid, 500)->'rows') r where r->>'src' = 'guest')::int,
  0, 'cleaner sees no guest profile history in the audit feed'
);

-- Owner sees the guest branch.
select set_config('request.jwt.claims', json_build_object('sub','f5000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select ok(
  (select count(*) from jsonb_array_elements(public.admin_audit_feed_v1('f5000000-0000-4000-8000-0000000000a1'::uuid, 500)->'rows') r where r->>'src' = 'guest') >= 1,
  'owner sees guest profile history in the audit feed'
);

-- Property-scoped admin: cross-property merge denied in both directions.
select set_config('request.jwt.claims', json_build_object('sub','f5000000-0000-4000-8000-0000000000a5','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select throws_ok(
  $$select public.preview_guest_merge_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, 'f5000000-0000-4000-8000-0000000000d1'::uuid)$$,
  '42501','guest merge scope denied','admin of property A cannot preview a merge that pulls in property B'
);
select throws_ok(
  $$select public.preview_guest_merge_v1('f5000000-0000-4000-8000-0000000000d1'::uuid, 'f5000000-0000-4000-8000-0000000000c1'::uuid)$$,
  '42501','manage_operations denied','admin of property A cannot preview a merge whose survivor is in property B'
);

-- Owner: merge validation.
select set_config('request.jwt.claims', json_build_object('sub','f5000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select throws_ok(
  $$select public.preview_guest_merge_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, 'f5000000-0000-4000-8000-0000000000c1'::uuid)$$,
  '22023','cannot merge a guest into itself','same-guest merge rejected'
);
select throws_ok(
  $$select public.merge_guests_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, 'f5000000-0000-4000-8000-0000000000c3'::uuid, 'looks like the same person', 'synthetic-key-name-only-0001')$$,
  '22023','no verified shared contact; name-only similarity cannot be merged','name-only similarity is not enough'
);
select throws_ok(
  $$select public.merge_guests_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, 'f5000000-0000-4000-8000-0000000000c4'::uuid, 'duplicate booking record', 'synthetic-key-enriched-0001')$$,
  '22023','Review the source profile and companions before merging this guest','enriched source guest is refused'
);
reset role;
select is((select is_active from public.guests where id = 'f5000000-0000-4000-8000-0000000000c4'), true, 'refused enriched guest stays active and unmodified');
select set_config('request.jwt.claims', json_build_object('sub','f5000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select throws_ok(
  $$select public.merge_guests_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, 'f5000000-0000-4000-8000-0000000000c2'::uuid, ' x ', 'synthetic-key-short-reason-01')$$,
  '22023','merge reason required','short merge reason rejected'
);
select is(
  (public.merge_guests_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, 'f5000000-0000-4000-8000-0000000000c2'::uuid, 'duplicate booking record', 'synthetic-key-merge-ok-00001')->>'ok')::boolean,
  true, 'shared-contact merge succeeds'
);
select is(
  (public.merge_guests_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, 'f5000000-0000-4000-8000-0000000000c2'::uuid, 'duplicate booking record', 'synthetic-key-merge-ok-00001')->>'replayed')::boolean,
  true, 'same key and pair replays without a second merge'
);
select throws_ok(
  $$select public.merge_guests_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, 'f5000000-0000-4000-8000-0000000000c3'::uuid, 'duplicate booking record', 'synthetic-key-merge-ok-00001')$$,
  '40001','idempotency conflict','same key with a different pair is a conflict'
);
reset role;
select is((select is_active from public.guests where id = 'f5000000-0000-4000-8000-0000000000c2'), false, 'merged guest is inactive');

-- Owner: profile validation and version contract.
select set_config('request.jwt.claims', json_build_object('sub','f5000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select throws_ok(
  $$select public.save_guest_profile_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, '{"contact_number":"09170000001"}'::jsonb, null, 'ab')$$,
  '22023','profile change reason required','short profile reason rejected'
);
select throws_ok(
  $$select public.save_guest_profile_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, '{"birthday":"2999-01-01"}'::jsonb, null, 'typo check')$$,
  '22023','birthday cannot be in the future','future birthday rejected'
);
select throws_ok(
  $$select public.save_guest_profile_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, '{"id_drive_url":"http://example.com/x"}'::jsonb, null, 'link check')$$,
  '22023','invalid Drive document link','non-Drive document link rejected'
);
select is(
  (public.save_guest_profile_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, '{"contact_number":"09170000001","birthday":"1990-05-01"}'::jsonb, null, 'legacy edit without a version')->>'ok')::boolean,
  true, 'first save on a fresh profile accepts a null expected version'
);
reset role;
select is((select version from public.guest_profile_details where guest_id = 'f5000000-0000-4000-8000-0000000000c1'), 2, 'first save leaves the profile at version 2');
select set_config('request.jwt.claims', json_build_object('sub','f5000000-0000-4000-8000-0000000000a2','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select set_config('role','authenticated',true);
select throws_ok(
  $$select public.save_guest_profile_v1('f5000000-0000-4000-8000-0000000000c1'::uuid, '{"address":"Purok 1"}'::jsonb, null, 'second edit without a version')$$,
  '40001','stale version: profile changed since it was loaded','a null expected version is refused once the profile has history'
);
reset role;

select * from finish();
rollback;
