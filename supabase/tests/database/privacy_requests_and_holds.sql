begin;

select plan(49);

select has_table('public', 'privacy_requests', 'privacy requests exist');
select has_table('public', 'privacy_holds', 'privacy holds exist');
select has_table('public', 'privacy_action_audit', 'privacy action audit exists');
select has_column('public', 'privacy_requests', 'received_at', 'request receipt time is recorded');
select has_function('public', 'create_privacy_request', array['uuid','text','text','text','text','text','text'], 'request creation RPC exists');
select has_function('public', 'transition_privacy_request', array['uuid','text','text'], 'request transition RPC exists');
select has_function('public', 'manage_privacy_hold', array['uuid','text','uuid','text','text','text','text'], 'hold management RPC exists');

select ok((select relrowsecurity from pg_class where oid = 'public.privacy_requests'::regclass), 'request RLS is enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.privacy_holds'::regclass), 'hold RLS is enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.privacy_action_audit'::regclass), 'audit RLS is enabled');
select ok(not has_table_privilege('anon', 'public.privacy_requests', 'select'), 'anon cannot read requests');
select ok(not has_table_privilege('authenticated', 'public.privacy_requests', 'select'), 'authenticated cannot read requests directly');
select ok(not has_table_privilege('service_role', 'public.privacy_requests', 'select'), 'service role cannot bypass request RPCs');
select ok(not has_table_privilege('anon', 'public.privacy_holds', 'select'), 'anon cannot read holds');
select ok(not has_table_privilege('authenticated', 'public.privacy_requests', 'insert'), 'authenticated cannot insert requests directly');
select ok(not has_table_privilege('authenticated', 'public.privacy_holds', 'update'), 'authenticated cannot update holds directly');
select ok(not has_table_privilege('authenticated', 'public.privacy_action_audit', 'update'), 'authenticated cannot rewrite audit rows');
select ok(not has_table_privilege('service_role', 'public.privacy_action_audit', 'update'), 'service role cannot rewrite audit rows');
select ok(has_function_privilege('authenticated', 'public.create_privacy_request(uuid,text,text,text,text,text,text)', 'execute'), 'authenticated staff may enter request RPC');
select ok(has_function_privilege('authenticated', 'public.transition_privacy_request(uuid,text,text)', 'execute'), 'authenticated staff may enter transition RPC');
select ok(has_function_privilege('authenticated', 'public.manage_privacy_hold(uuid,text,uuid,text,text,text,text)', 'execute'), 'authenticated staff may enter hold RPC');
select ok(not has_function_privilege('anon', 'public.create_privacy_request(uuid,text,text,text,text,text,text)', 'execute'), 'anon cannot create privacy requests');
select ok(not has_function_privilege('service_role', 'public.create_privacy_request(uuid,text,text,text,text,text,text)', 'execute'), 'service role cannot impersonate a privacy reviewer');
select ok(public.staff_access_allowed('admin', 'manage_privacy', null, 'aal2'), 'AAL2 admin may manage privacy');
select ok(not public.staff_access_allowed('admin', 'manage_privacy', null, 'aal1'), 'AAL1 admin cannot manage privacy');
select ok(not public.staff_access_allowed('finance', 'manage_privacy', null, 'aal2'), 'Finance cannot manage privacy');

insert into public.properties (id, name, is_active) values
  ('41000000-0000-4000-8000-000000000001', 'Privacy Fixture One', true),
  ('41000000-0000-4000-8000-000000000002', 'Privacy Fixture Two', true)
on conflict (id) do nothing;

insert into auth.users (id) values
  ('42000000-0000-4000-8000-000000000001'),
  ('42000000-0000-4000-8000-000000000002'),
  ('42000000-0000-4000-8000-000000000003')
on conflict (id) do nothing;

insert into public.staff_access_profiles (user_id, role, disabled_at, sessions_revoked_after) values
  ('42000000-0000-4000-8000-000000000001', 'admin', null, null),
  ('42000000-0000-4000-8000-000000000002', 'finance', null, null),
  ('42000000-0000-4000-8000-000000000003', 'admin', now(), null)
on conflict (user_id) do update set
  role = excluded.role,
  disabled_at = excluded.disabled_at,
  sessions_revoked_after = excluded.sessions_revoked_after;

insert into public.staff_property_access (user_id, property_id) values
  ('42000000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-000000000001'),
  ('42000000-0000-4000-8000-000000000002', '41000000-0000-4000-8000-000000000001'),
  ('42000000-0000-4000-8000-000000000003', '41000000-0000-4000-8000-000000000001')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claims = '{"sub":"42000000-0000-4000-8000-000000000001","aal":"aal2","app_metadata":{"role":"finance","property_ids":["41000000-0000-4000-8000-000000000002"]}}';

select lives_ok(
  $$select set_config('cascade.test_privacy_request_1', public.create_privacy_request(
    '41000000-0000-4000-8000-000000000001', 'deletion', 'guest', 'guest-fixture-1',
    'email', 'Booking and receipt records', 'Identity received through approved channel'
  )::text, true)$$,
  'property-scoped AAL2 admin may create a request'
);

reset role;
select is(
  (select count(*) from public.privacy_requests where subject_reference = 'guest-fixture-1'),
  1::bigint,
  'request is stored once'
);
set local role authenticated;

select throws_ok(
  $$select public.create_privacy_request(
    '41000000-0000-4000-8000-000000000002', 'access', 'guest', 'guest-fixture-denied',
    'email', 'Booking records', 'Cross-property request must fail'
  )$$,
  '42501', null,
  'admin cannot create a request outside assigned property'
);

select lives_ok(
  $$select public.manage_privacy_hold(
    '43000000-0000-4000-8000-000000000001', 'create',
    '41000000-0000-4000-8000-000000000001', 'guest', 'guest-fixture-1',
    'legal', 'Pending legal review'
  )$$,
  'admin may open a matching privacy hold'
);

select lives_ok(
  $$select public.transition_privacy_request(
    current_setting('cascade.test_privacy_request_1')::uuid,
    'verify_identity', 'Identity verified through approved booking details'
  )$$,
  'request identity may be verified'
);

select lives_ok(
  $$select public.transition_privacy_request(
    current_setting('cascade.test_privacy_request_1')::uuid,
    'start_review', 'Relevant systems assigned for review'
  )$$,
  'verified request may enter review'
);

select lives_ok(
  $$select public.transition_privacy_request(
    current_setting('cascade.test_privacy_request_1')::uuid,
    'place_on_hold', 'Matching legal hold is active'
  )$$,
  'review request may be placed on hold'
);

select throws_ok(
  $$select public.transition_privacy_request(
    current_setting('cascade.test_privacy_request_1')::uuid,
    'resume_review', 'Attempted resume while hold remains active'
  )$$,
  '23514', null,
  'active matching hold blocks review resumption'
);

select lives_ok(
  $$select public.manage_privacy_hold(
    '43000000-0000-4000-8000-000000000001', 'release',
    null, null, null, null, 'Legal review completed'
  )$$,
  'active hold may be released with a reason'
);

reset role;
select is(
  (select status from public.privacy_requests where subject_reference = 'guest-fixture-1'),
  'on_hold',
  'hold release does not silently mutate request status'
);
set local role authenticated;

select lives_ok(
  $$select public.transition_privacy_request(
    current_setting('cascade.test_privacy_request_1')::uuid,
    'resume_review', 'All matching holds were reviewed and released'
  )$$,
  'request review may resume after hold release'
);

select lives_ok(
  $$select public.manage_privacy_hold(
    '43000000-0000-4000-8000-000000000002', 'create',
    '41000000-0000-4000-8000-000000000001', 'guest', 'guest-fixture-1',
    'dispute', 'Open guest dispute'
  )$$,
  'a second matching hold may be opened'
);

select throws_ok(
  $$select public.transition_privacy_request(
    current_setting('cascade.test_privacy_request_1')::uuid,
    'approve', 'Deletion approval attempted during dispute'
  )$$,
  '23514', null,
  'active hold blocks deletion approval'
);

select lives_ok(
  $$select public.manage_privacy_hold(
    '43000000-0000-4000-8000-000000000002', 'release',
    null, null, null, null, 'Guest dispute resolved'
  )$$,
  'second hold may be released'
);

select lives_ok(
  $$select public.transition_privacy_request(
    current_setting('cascade.test_privacy_request_1')::uuid,
    'approve', 'Owner approved reviewed anonymization scope'
  )$$,
  'reviewed deletion request may be approved after holds release'
);

select lives_ok(
  $$select public.transition_privacy_request(
    current_setting('cascade.test_privacy_request_1')::uuid,
    'complete', 'Manual response and approved data action completed'
  )$$,
  'approved request may be completed'
);

reset role;
select ok(
  (select status = 'completed' and responded_at is not null
   from public.privacy_requests where subject_reference = 'guest-fixture-1'),
  'completed request records its response time'
);

select ok(
  (select count(*) >= 11 from public.privacy_action_audit
   where property_id = '41000000-0000-4000-8000-000000000001'),
  'successful request and hold actions are append-only audited'
);
set local role authenticated;

select lives_ok(
  $$select set_config('cascade.test_privacy_request_2', public.create_privacy_request(
    '41000000-0000-4000-8000-000000000001', 'correction', 'guest', 'guest-fixture-2',
    'phone', 'Guest contact correction', 'Correction request received by phone'
  )::text, true)$$,
  'a second request may be created'
);

select lives_ok(
  $$select public.transition_privacy_request(
    current_setting('cascade.test_privacy_request_2')::uuid,
    'cancel', 'Requester withdrew the correction request'
  )$$,
  'received request may be cancelled'
);

reset role;
select is(
  (select status from public.privacy_requests where subject_reference = 'guest-fixture-2'),
  'cancelled',
  'cancel transition is persisted'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"42000000-0000-4000-8000-000000000002","aal":"aal2","app_metadata":{"role":"owner"}}';
select throws_ok(
  $$select public.create_privacy_request(
    '41000000-0000-4000-8000-000000000001', 'access', 'guest', 'guest-finance-denied',
    'email', 'Booking records', 'Finance user must not manage privacy'
  )$$,
  '42501', null,
  'Finance cannot manage privacy despite poisoned JWT metadata'
);

set local request.jwt.claims = '{"sub":"42000000-0000-4000-8000-000000000003","aal":"aal2","app_metadata":{"role":"owner"}}';
select throws_ok(
  $$select public.create_privacy_request(
    '41000000-0000-4000-8000-000000000001', 'access', 'guest', 'guest-disabled-denied',
    'email', 'Booking records', 'Disabled admin must not manage privacy'
  )$$,
  '42501', null,
  'disabled admin loses privacy access immediately'
);

reset role;
select * from finish();
rollback;
