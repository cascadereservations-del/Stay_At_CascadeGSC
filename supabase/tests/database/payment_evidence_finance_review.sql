begin;
select plan(47);

select has_table('public', 'payment_evidence_candidates', 'payment evidence candidates exist');
select has_table('public', 'payment_evidence_comparisons', 'payment comparisons exist');
select has_table('public', 'payment_finance_reviews', 'Finance reviews exist');
select ok((select relrowsecurity from pg_class where oid = 'public.payment_evidence_candidates'::regclass), 'evidence RLS is enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.payment_evidence_comparisons'::regclass), 'comparison RLS is enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.payment_finance_reviews'::regclass), 'review RLS is enabled');
select has_function('public', 'record_payment_evidence_candidate', array[
  'uuid','text','text','text','text','text','timestamp with time zone','numeric',
  'text','text','numeric','text[]','text','text'
], 'guarded evidence recorder exists');
select has_function('public', 'compare_booking_payment_evidence', array['uuid','uuid[]'], 'deterministic comparison function exists');
select has_function('public', 'record_payment_finance_review', array['uuid','text','text'], 'named Finance review function exists');
select has_function('public', 'decide_direct_booking', array['uuid','text','text','uuid'], 'booking decision requires a Finance review id');
select ok(not has_table_privilege('anon', 'public.payment_evidence_candidates', 'select'), 'anonymous users cannot read evidence');
select ok(has_table_privilege('authenticated', 'public.payment_evidence_candidates', 'select'), 'authenticated role enters Finance-only evidence RLS');
select ok(not has_table_privilege('authenticated', 'public.payment_evidence_candidates', 'insert'), 'authenticated users cannot insert evidence directly');
select ok(not has_table_privilege('service_role', 'public.payment_evidence_candidates', 'insert'), 'service role cannot bypass evidence recorder');
select ok(not has_table_privilege('service_role', 'public.payment_evidence_candidates', 'select'), 'service role cannot read Finance evidence directly');
select ok(not has_table_privilege('service_role', 'public.payment_evidence_comparisons', 'select'), 'service role cannot read comparisons directly');
select ok(not has_table_privilege('service_role', 'public.payment_finance_reviews', 'select'), 'service role cannot read Finance reviews directly');
select ok(not has_table_privilege('authenticated', 'public.payment_finance_reviews', 'update'), 'Finance reviews are append-only to clients');
select ok(has_function_privilege('service_role', 'public.record_payment_evidence_candidate(uuid,text,text,text,text,text,timestamp with time zone,numeric,text,text,numeric,text[],text,text)', 'execute'), 'service integration may submit advisory evidence');
select ok(has_function_privilege('service_role', 'public.compare_booking_payment_evidence(uuid,uuid[])', 'execute'), 'service integration may run deterministic comparison');
select ok(not has_function_privilege('service_role', 'public.record_payment_finance_review(uuid,text,text)', 'execute'), 'service integration cannot impersonate Finance review');
select ok(has_function_privilege('authenticated', 'public.record_payment_finance_review(uuid,text,text)', 'execute'), 'authenticated staff may enter guarded Finance review');
select ok(not has_function_privilege('service_role', 'public.decide_direct_booking_without_finance_review(uuid,text,text)', 'execute'), 'service role cannot bypass Finance review');
select ok(has_function_privilege('service_role', 'public.decide_direct_booking(uuid,text,text,uuid)', 'execute'), 'service role may invoke only the reviewed booking decision');
select ok(not has_table_privilege('service_role', 'public.booking_decisions', 'insert'), 'service role cannot fabricate booking decision records directly');

insert into public.properties (id, name, is_active)
values ('51000000-0000-4000-8000-000000000001', 'Synthetic Module C Property', true)
on conflict (id) do nothing;

insert into auth.users (id) values
  ('52000000-0000-4000-8000-000000000001'),
  ('52000000-0000-4000-8000-000000000002'),
  ('52000000-0000-4000-8000-000000000003'),
  ('52000000-0000-4000-8000-000000000004')
on conflict (id) do nothing;

insert into public.staff_access_profiles (user_id, role, disabled_at, sessions_revoked_after) values
  ('52000000-0000-4000-8000-000000000001', 'finance', null, null),
  ('52000000-0000-4000-8000-000000000002', 'cleaner', null, null),
  ('52000000-0000-4000-8000-000000000003', 'finance', now(), null),
  ('52000000-0000-4000-8000-000000000004', 'admin', null, null)
on conflict (user_id) do update set role = excluded.role, disabled_at = excluded.disabled_at, sessions_revoked_after = excluded.sessions_revoked_after;

insert into public.staff_property_access (user_id, property_id) values
  ('52000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001'),
  ('52000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000001'),
  ('52000000-0000-4000-8000-000000000003', '51000000-0000-4000-8000-000000000001'),
  ('52000000-0000-4000-8000-000000000004', '51000000-0000-4000-8000-000000000001')
on conflict do nothing;

insert into public.booking_inquiries (
  id, property_id, guest_name, guest_phone, checkin_date, checkout_date,
  source, status, total_amount, deposit_amount
) values
  ('53000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001', 'Exact Fixture', '000', current_date + 60, current_date + 62, 'direct', 'pending', 3000, 1500),
  ('53000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000001', 'Mismatch Fixture', '000', current_date + 64, current_date + 66, 'direct', 'pending', 3000, 1500),
  ('53000000-0000-4000-8000-000000000003', '51000000-0000-4000-8000-000000000001', 'Duplicate Fixture', '000', current_date + 68, current_date + 70, 'direct', 'pending', 3000, 1500),
  ('53000000-0000-4000-8000-000000000004', '51000000-0000-4000-8000-000000000001', 'Ambiguous Fixture', '000', current_date + 72, current_date + 74, 'direct', 'pending', 3000, 1500),
  ('53000000-0000-4000-8000-000000000005', '51000000-0000-4000-8000-000000000001', 'Missing Bank Fixture', '000', current_date + 76, current_date + 78, 'direct', 'pending', 3000, 1500),
  ('53000000-0000-4000-8000-000000000006', '51000000-0000-4000-8000-000000000001', 'Spoof Fixture', '000', current_date + 80, current_date + 82, 'direct', 'pending', 3000, 1500);

insert into public.calendar_events (property_id, uid, source, status, checkin_date, checkout_date, recon_status)
values ('51000000-0000-4000-8000-000000000001', 'direct:53000000-0000-4000-8000-000000000005', 'direct', 'blocked', current_date + 76, current_date + 78, 'manual_entry');

set local role service_role;
select set_config('cascade.c_exact_receipt', public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000001','receipt_ocr','receipt_exact_001',repeat('a',64),
  'evidence-exact-receipt-0001','receipt-ocr-v1',now(),1500,'php','cas-1001',0.91,array['clear_amount'],'not_applicable',null
)::text, true);
select set_config('cascade.c_exact_bank', public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000001','bank_email','bankmsg_exact_001',repeat('b',64),
  'evidence-exact-bank-000001','bank-mail-v1',now(),1500,'PHP','CAS1001',null,array['allowlisted_bank_message'],'allowlisted',null
)::text, true);
select set_config('cascade.c_mismatch', public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000002','receipt_ocr','receipt_mismatch_01',repeat('c',64),
  'evidence-mismatch-00000001','receipt-ocr-v1',now(),1200,'PHP','CAS1002',0.8,array['clear_amount'],'not_applicable',null
)::text, true);
select set_config('cascade.c_dup_one', public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000003','receipt_ocr','receipt_duplicate_1',repeat('d',64),
  'evidence-duplicate-one-0001','receipt-ocr-v1',now(),1500,'PHP','CAS1003',0.8,array['clear_amount'],'not_applicable',null
)::text, true);
select set_config('cascade.c_dup_two', public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000003','receipt_ocr','receipt_duplicate_2',repeat('d',64),
  'evidence-duplicate-two-0002','receipt-ocr-v1',now(),1500,'PHP','CAS1003',0.8,array['clear_amount'],'not_applicable',null
)::text, true);
select set_config('cascade.c_ambiguous', public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000004','receipt_ocr','receipt_ambiguous_1',repeat('e',64),
  'evidence-ambiguous-0000001','receipt-ocr-v1',now(),1500,'PHP','CAS1004',0.8,array['clear_amount'],'not_applicable',null
)::text, true);
select set_config('cascade.c_missing_receipt', public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000005','receipt_ocr','receipt_missingbank_1',repeat('f',64),
  'evidence-missing-receipt-001','receipt-ocr-v1',now(),1500,'PHP','CAS1005',0.8,array['clear_amount'],'not_applicable',null
)::text, true);
select set_config('cascade.c_missing_bank', public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000005','bank_email','bankmsg_missing_0001',repeat('1',64),
  'evidence-missing-bank-000001','bank-mail-v1',now(),null,null,null,null,array['manual_review_required'],'missing','missing_message'
)::text, true);
select set_config('cascade.c_spoof', public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000006','bank_email','bankmsg_spoofed_001',repeat('2',64),
  'evidence-spoofed-bank-00001','bank-mail-v1',now(),null,null,null,null,array['manual_review_required'],'rejected','sender_not_allowlisted'
)::text, true);

select set_config('cascade.x_exact', public.compare_booking_payment_evidence(
  '53000000-0000-4000-8000-000000000001', array[current_setting('cascade.c_exact_receipt')::uuid,current_setting('cascade.c_exact_bank')::uuid]
)::text, true);
select set_config('cascade.x_mismatch', public.compare_booking_payment_evidence(
  '53000000-0000-4000-8000-000000000002', array[current_setting('cascade.c_mismatch')::uuid]
)::text, true);
select set_config('cascade.x_duplicate', public.compare_booking_payment_evidence(
  '53000000-0000-4000-8000-000000000003', array[current_setting('cascade.c_dup_one')::uuid,current_setting('cascade.c_dup_two')::uuid]
)::text, true);
select set_config('cascade.x_ambiguous', public.compare_booking_payment_evidence(
  '53000000-0000-4000-8000-000000000004', array[current_setting('cascade.c_ambiguous')::uuid]
)::text, true);
select set_config('cascade.x_missing', public.compare_booking_payment_evidence(
  '53000000-0000-4000-8000-000000000005', array[current_setting('cascade.c_missing_receipt')::uuid,current_setting('cascade.c_missing_bank')::uuid]
)::text, true);
select set_config('cascade.x_spoof', public.compare_booking_payment_evidence(
  '53000000-0000-4000-8000-000000000006', array[current_setting('cascade.c_spoof')::uuid]
)::text, true);

select is(public.record_payment_evidence_candidate(
  '53000000-0000-4000-8000-000000000001','receipt_ocr','receipt_exact_001',repeat('a',64),
  'evidence-exact-receipt-0001','receipt-ocr-v1',now(),1500,'PHP','CAS1001',0.91,array['clear_amount'],'not_applicable',null
), current_setting('cascade.c_exact_receipt')::uuid, 'evidence ingestion is idempotent');
select is(public.compare_booking_payment_evidence(
  '53000000-0000-4000-8000-000000000001', array[current_setting('cascade.c_exact_bank')::uuid,current_setting('cascade.c_exact_receipt')::uuid]
), current_setting('cascade.x_exact')::uuid, 'comparison is idempotent regardless of candidate order');
reset role;

select is((select status from public.booking_inquiries where id = '53000000-0000-4000-8000-000000000001'), 'pending', 'evidence and comparison cannot confirm a booking');
select is((select comparison_outcome from public.payment_evidence_comparisons where id = current_setting('cascade.x_exact')::uuid), 'exact_match', 'matching receipt and bank evidence compares exactly');
select is((select comparison_outcome from public.payment_evidence_comparisons where id = current_setting('cascade.x_mismatch')::uuid), 'mismatch', 'wrong amount is a mismatch');
select is((select comparison_outcome from public.payment_evidence_comparisons where id = current_setting('cascade.x_duplicate')::uuid), 'duplicate_evidence', 'duplicate content is recorded');
select is((select comparison_outcome from public.payment_evidence_comparisons where id = current_setting('cascade.x_ambiguous')::uuid), 'ambiguity', 'single matching source remains ambiguous');
select is((select comparison_outcome from public.payment_evidence_comparisons where id = current_setting('cascade.x_missing')::uuid), 'missing_fields', 'missing bank evidence is recorded without deciding payment');
select is((select comparison_outcome from public.payment_evidence_comparisons where id = current_setting('cascade.x_spoof')::uuid), 'missing_fields', 'spoofed-looking bank evidence fails closed');

set local role authenticated;
set local request.jwt.claims = '{"sub":"52000000-0000-4000-8000-000000000002","aal":"aal2"}';
select is((select count(*) from public.payment_evidence_candidates), 0::bigint, 'OPS cleaner sees no Finance evidence');
select throws_ok(
  $$select public.record_payment_finance_review(current_setting('cascade.x_exact')::uuid,'approved','Cleaner attempted approval')$$,
  '42501', null, 'OPS cleaner cannot review payment'
);

set local request.jwt.claims = '{"sub":"52000000-0000-4000-8000-000000000001","aal":"aal1"}';
select throws_ok(
  $$select public.record_payment_finance_review(current_setting('cascade.x_exact')::uuid,'approved','AAL1 attempted approval')$$,
  '42501', null, 'Finance review requires AAL2'
);

set local request.jwt.claims = '{"sub":"52000000-0000-4000-8000-000000000003","aal":"aal2"}';
select throws_ok(
  $$select public.record_payment_finance_review(current_setting('cascade.x_exact')::uuid,'approved','Disabled user attempted approval')$$,
  '42501', null, 'disabled Finance user cannot review payment'
);

set local request.jwt.claims = '{"sub":"52000000-0000-4000-8000-000000000001","aal":"aal2"}';
select ok((select count(*) > 0 from public.payment_evidence_candidates), 'authorized Finance user can read evidence');
select lives_ok(
  $$select set_config('cascade.review_missing', public.record_payment_finance_review(
    current_setting('cascade.x_missing')::uuid,'approved','Bank email missing; receipt manually verified against account'
  )::text, true)$$,
  'named Finance may approve after manual review when bank email is missing'
);
select is(
  public.record_payment_finance_review(
    current_setting('cascade.x_missing')::uuid,'approved','Bank email missing; receipt manually verified against account'
  ),
  current_setting('cascade.review_missing')::uuid,
  'identical final Finance review retry is idempotent'
);
select lives_ok(
  $$select set_config('cascade.review_followup', public.record_payment_finance_review(
    current_setting('cascade.x_exact')::uuid,'needs_follow_up','Request clearer supporting evidence'
  )::text, true)$$,
  'Finance may record a non-final follow-up review'
);
reset role;

select is(
  (select reviewer_user_id from public.payment_finance_reviews where id = current_setting('cascade.review_missing')::uuid),
  '52000000-0000-4000-8000-000000000001'::uuid,
  'review records the named authenticated Finance user'
);

set local role service_role;
select throws_ok(
  $$select public.decide_direct_booking(
    '53000000-0000-4000-8000-000000000001','confirm','module-c-followup-denied-001',
    current_setting('cascade.review_followup')::uuid
  )$$,
  '42501', null, 'follow-up review cannot authorize booking confirmation'
);
select is(
  public.decide_direct_booking(
    '53000000-0000-4000-8000-000000000005','confirm','module-c-manual-approve-0001',
    current_setting('cascade.review_missing')::uuid
  )->>'outcome',
  'confirmed',
  'reviewed manual approval reaches the canonical booking transaction'
);
reset role;

select is((select status from public.booking_inquiries where id = '53000000-0000-4000-8000-000000000005'), 'confirmed', 'booking confirms only after named review');
select is(
  (select finance_review_id from public.booking_decisions where idempotency_key = 'module-c-manual-approve-0001'),
  current_setting('cascade.review_missing')::uuid,
  'booking decision is immutably linked to Finance review'
);

select * from finish();
rollback;
