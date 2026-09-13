begin;
select plan(33);

select has_table('public', 'marketing_drafts', 'marketing drafts exist');
select has_table('public', 'marketing_draft_reviews', 'marketing reviews exist');
select has_function('public', 'create_marketing_draft', array['uuid','text','text','text','text','text','text','text','text','boolean','text','boolean','text','text'], 'draft RPC exists');
select has_function('public', 'review_marketing_draft', array['uuid','text','text','boolean','boolean','boolean','text','text'], 'review RPC exists');
select ok(not has_function_privilege('service_role', 'public.create_marketing_draft(uuid,text,text,text,text,text,text,text,text,boolean,text,boolean,text,text)', 'execute'), 'service cannot create drafts');
select ok(not has_function_privilege('service_role', 'public.review_marketing_draft(uuid,text,text,boolean,boolean,boolean,text,text)', 'execute'), 'service cannot review drafts');
select ok(not has_table_privilege('authenticated', 'public.marketing_drafts', 'insert'), 'draft rows cannot be forged');
select ok(not has_table_privilege('authenticated', 'public.marketing_draft_reviews', 'insert'), 'review rows cannot be forged');
select ok(not has_table_privilege('authenticated', 'public.marketing_draft_reviews', 'update'), 'reviews are immutable');
select ok(not has_table_privilege('anon', 'public.marketing_drafts', 'select'), 'anonymous cannot read drafts');
select hasnt_column('public', 'marketing_drafts', 'recipient_email', 'raw recipient email is absent');
select hasnt_column('public', 'marketing_drafts', 'recipient_phone', 'raw recipient phone is absent');

insert into public.properties(id, name, is_active)
values ('e1000000-0000-4000-8000-000000000001', 'Synthetic Marketing', true);
insert into public.guests(id, property_id, name)
values ('e3000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001', 'Synthetic Guest');
insert into auth.users(id)
values ('e2000000-0000-4000-8000-000000000001'), ('e2000000-0000-4000-8000-000000000002');
insert into public.staff_access_profiles(user_id, role)
values ('e2000000-0000-4000-8000-000000000001', 'admin'), ('e2000000-0000-4000-8000-000000000002', 'cleaner');
insert into public.staff_property_access(user_id, property_id)
values ('e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000001'),
       ('e2000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000001');

set local role authenticated;
set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-000000000001","aal":"aal2"}';
select set_config('cascade.w7_profile', public.create_crm_profile(
  'e3000000-0000-4000-8000-000000000001', repeat('1',64), repeat('2',64), 'wave7-profile-key-001'
)::text, true);
select lives_ok(
  $$select public.record_crm_consent(current_setting('cascade.w7_profile')::uuid, 'marketing', 'granted', repeat('3',64), '2026-09-05 08:00:00+00', 'Explicit synthetic marketing consent', 'wave7-consent-key-001')$$,
  'marketing consent is recorded separately'
);

set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-0000000000ff","aal":"aal1"}';
select throws_ok(
  $$select public.create_marketing_draft(current_setting('cascade.w7_profile')::uuid, 'email', 'enc:subject:123456789', repeat('4',64), 'enc:content:123456789', repeat('5',64), 'human', null, 'Synthetic prior guest', false, null, false, null, 'wave7-aal1-key-001')$$,
  '42501', 'marketing draft denied', 'unknown user cannot create a draft (aal no longer gates, D-094)'
);

set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-000000000001","aal":"aal2"}';
select throws_ok(
  $$select public.create_marketing_draft(current_setting('cascade.w7_profile')::uuid, 'email', 'enc:subject:123456789', repeat('4',64), 'enc:content:123456789', repeat('5',64), 'advisory_model', null, 'Synthetic prior guest', false, null, false, null, 'wave7-invalid-key-001')$$,
  '22023', 'invalid marketing draft', 'advisory draft requires its output hash'
);
select set_config('cascade.w7_draft', public.create_marketing_draft(
  current_setting('cascade.w7_profile')::uuid, 'email', 'enc:subject:123456789', repeat('4',64),
  'enc:content:123456789', repeat('5',64), 'advisory_model', repeat('6',64),
  'Synthetic prior guest with explicit consent', true, repeat('7',64), true, repeat('8',64),
  'wave7-draft-key-001'
)::text, true);
select ok(current_setting('cascade.w7_draft')::uuid is not null, 'eligible draft is created');
select is(public.create_marketing_draft(
  current_setting('cascade.w7_profile')::uuid, 'email', 'enc:subject:123456789', repeat('4',64),
  'enc:content:123456789', repeat('5',64), 'advisory_model', repeat('6',64),
  'Synthetic prior guest with explicit consent', true, repeat('7',64), true, repeat('8',64),
  'wave7-draft-key-001'
), current_setting('cascade.w7_draft')::uuid, 'draft retry is stable');
select is((select content_hash from public.marketing_drafts where id=current_setting('cascade.w7_draft')::uuid), repeat('5',64), 'draft content hash is exact');
select is((select publication_authorized from public.marketing_drafts where id=current_setting('cascade.w7_draft')::uuid), false, 'draft never authorizes publication');
select is((select draft_source from public.marketing_drafts where id=current_setting('cascade.w7_draft')::uuid), 'advisory_model', 'model output remains advisory provenance');

select throws_ok(
  $$select public.review_marketing_draft(current_setting('cascade.w7_draft')::uuid, 'approved', repeat('9',64), true, true, true, 'Exact content reviewed', 'wave7-review-stale-001')$$,
  '22023', 'invalid or stale marketing review', 'different content hash fails closed'
);
select throws_ok(
  $$select public.review_marketing_draft(current_setting('cascade.w7_draft')::uuid, 'approved', repeat('5',64), false, true, true, 'Targeting not approved', 'wave7-review-target-001')$$,
  '22023', 'required marketing review scope missing', 'targeting needs explicit approval'
);
select throws_ok(
  $$select public.review_marketing_draft(current_setting('cascade.w7_draft')::uuid, 'approved', repeat('5',64), true, false, true, 'Discount not approved', 'wave7-review-discount-001')$$,
  '22023', 'required marketing review scope missing', 'discount needs explicit approval'
);
select throws_ok(
  $$select public.review_marketing_draft(current_setting('cascade.w7_draft')::uuid, 'approved', repeat('5',64), true, true, false, 'Claim not approved', 'wave7-review-claim-001')$$,
  '22023', 'required marketing review scope missing', 'claim needs explicit approval'
);
select lives_ok(
  $$select public.record_crm_consent(current_setting('cascade.w7_profile')::uuid, 'marketing', 'withdrawn', repeat('a',64), '2026-09-05 09:00:00+00', 'Synthetic withdrawal before review', 'wave7-consent-key-002')$$,
  'consent may be withdrawn before review'
);
select throws_ok(
  $$select public.review_marketing_draft(current_setting('cascade.w7_draft')::uuid, 'approved', repeat('5',64), true, true, true, 'Consent rechecked', 'wave7-review-consent-001')$$,
  '22023', 'marketing consent or lifecycle no longer eligible', 'withdrawal blocks approval'
);
select lives_ok(
  $$select public.record_crm_consent(current_setting('cascade.w7_profile')::uuid, 'marketing', 'granted', repeat('b',64), '2026-09-05 10:00:00+00', 'Synthetic consent granted again', 'wave7-consent-key-003')$$,
  'fresh consent can restore eligibility'
);
select set_config('cascade.w7_review', public.review_marketing_draft(
  current_setting('cascade.w7_draft')::uuid, 'approved', repeat('5',64), true, true, true,
  'Named reviewer approved exact synthetic content', 'wave7-review-key-001'
)::text, true);
select ok(current_setting('cascade.w7_review')::uuid is not null, 'named review is recorded');
select is(public.review_marketing_draft(
  current_setting('cascade.w7_draft')::uuid, 'approved', repeat('5',64), true, true, true,
  'Named reviewer approved exact synthetic content', 'wave7-review-key-001'
), current_setting('cascade.w7_review')::uuid, 'review retry is stable');
select is((select reviewed_content_hash from public.marketing_draft_reviews where id=current_setting('cascade.w7_review')::uuid), repeat('5',64), 'approval binds exact content hash');
select is((select publication_authorized from public.marketing_draft_reviews where id=current_setting('cascade.w7_review')::uuid), false, 'review never authorizes publication');
select is((select reviewed_by_user_id from public.marketing_draft_reviews where id=current_setting('cascade.w7_review')::uuid), 'e2000000-0000-4000-8000-000000000001'::uuid, 'review retains named human');

set local request.jwt.claims = '{"sub":"e2000000-0000-4000-8000-000000000002","aal":"aal2"}';
select throws_ok(
  $$select public.create_marketing_draft(current_setting('cascade.w7_profile')::uuid, 'email', 'enc:subject:123456789', repeat('4',64), 'enc:content:987654321', repeat('c',64), 'human', null, 'Cleaner must not target', false, null, false, null, 'wave7-cleaner-key-001')$$,
  '42501', 'marketing draft denied', 'cleaner cannot create marketing drafts'
);

select * from finish();
rollback;
