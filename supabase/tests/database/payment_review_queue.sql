begin;
select plan(15);

select has_function('public', 'get_payment_review_queue', array['uuid','integer'], 'Finance review queue RPC exists');
select ok(has_function_privilege('authenticated', 'public.get_payment_review_queue(uuid,integer)', 'execute'), 'authenticated staff may enter guarded queue RPC');
select ok(not has_function_privilege('service_role', 'public.get_payment_review_queue(uuid,integer)', 'execute'), 'service integrations cannot read Finance queue');

insert into public.properties (id, name, is_active)
values ('61000000-0000-4000-8000-000000000001', 'Synthetic Module D Property', true)
on conflict (id) do nothing;

insert into auth.users (id) values
  ('62000000-0000-4000-8000-000000000001'),
  ('62000000-0000-4000-8000-000000000002')
on conflict (id) do nothing;

insert into public.staff_access_profiles (user_id, role, disabled_at, sessions_revoked_after) values
  ('62000000-0000-4000-8000-000000000001', 'finance', null, null),
  ('62000000-0000-4000-8000-000000000002', 'cleaner', null, null)
on conflict (user_id) do update set role = excluded.role, disabled_at = null, sessions_revoked_after = null;

insert into public.staff_property_access (user_id, property_id) values
  ('62000000-0000-4000-8000-000000000001', '61000000-0000-4000-8000-000000000001'),
  ('62000000-0000-4000-8000-000000000002', '61000000-0000-4000-8000-000000000001')
on conflict do nothing;

insert into public.booking_inquiries (
  id, property_id, guest_name, guest_email, guest_phone, checkin_date,
  checkout_date, source, status, total_amount, deposit_amount
) values (
  '63000000-0000-4000-8000-000000000001',
  '61000000-0000-4000-8000-000000000001',
  'Synthetic Queue Guest', 'private@example.invalid', '000-PRIVATE',
  current_date + 80, current_date + 82, 'direct', 'pending', 4000, 2000
);

set local role service_role;
select set_config('cascade.d_receipt', public.record_payment_evidence_candidate(
  '63000000-0000-4000-8000-000000000001','receipt_ocr','receipt_module_d_001',repeat('3',64),
  'module-d-receipt-evidence-001','receipt-ocr-v1',now(),2000,'PHP','CASD001',0.91,
  array['clear_amount'],'not_applicable',null
)::text, true);
select set_config('cascade.d_bank', public.record_payment_evidence_candidate(
  '63000000-0000-4000-8000-000000000001','bank_email','bankmsg_module_d_001',repeat('4',64),
  'module-d-bank-evidence-000001','bank-mail-v1',now(),2000,'PHP','CASD001',null,
  array[]::text[],'allowlisted',null
)::text, true);
select set_config('cascade.d_comparison', public.compare_booking_payment_evidence(
  '63000000-0000-4000-8000-000000000001',
  array[current_setting('cascade.d_receipt')::uuid,current_setting('cascade.d_bank')::uuid]
)::text, true);
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"62000000-0000-4000-8000-000000000002","aal":"aal2"}';
select throws_ok(
  $$select public.get_payment_review_queue('61000000-0000-4000-8000-000000000001', 50)$$,
  '42501', null, 'OPS cannot read Finance review queue'
);

set local request.jwt.claims = '{"sub":"62000000-0000-4000-8000-000000000001","aal":"aal1"}';
select lives_ok(
  $$select public.get_payment_review_queue('61000000-0000-4000-8000-000000000001', 50)$$,
  'Finance queue readable on a password session (D-094)'
);

set local request.jwt.claims = '{"sub":"62000000-0000-4000-8000-000000000001","aal":"aal2"}';
select set_config('cascade.d_queue', public.get_payment_review_queue(
  '61000000-0000-4000-8000-000000000001', 50
)::text, true);
select is(jsonb_array_length((current_setting('cascade.d_queue')::jsonb)->'items'), 1, 'queue contains latest property-scoped comparison');
select is((current_setting('cascade.d_queue')::jsonb #>> '{items,0,comparison,outcome}'), 'exact_match', 'queue exposes deterministic outcome');
select is(jsonb_array_length(current_setting('cascade.d_queue')::jsonb #> '{items,0,evidence}'), 2, 'queue exposes evidence provenance');
select is((current_setting('cascade.d_queue')::jsonb #>> '{items,0,review_state}'), 'needs_review', 'unreviewed comparison is explicit');
select ok(current_setting('cascade.d_queue') !~ 'private@example.invalid', 'queue excludes guest email');
select ok(current_setting('cascade.d_queue') !~ '000-PRIVATE', 'queue excludes guest phone');
select lives_ok(
  $$select public.record_payment_finance_review(
    current_setting('cascade.d_comparison')::uuid,
    'needs_follow_up',
    'Request a clearer receipt image'
  )$$,
  'named Finance may append review history'
);
select is(
  jsonb_array_length(public.get_payment_review_queue(
    '61000000-0000-4000-8000-000000000001', 50
  ) #> '{items,0,review_history}'),
  1,
  'queue returns immutable review history'
);
select throws_ok(
  $$select public.get_payment_review_queue('61000000-0000-4000-8000-000000000001', 101)$$,
  '22023', null, 'queue limit is bounded'
);
reset role;

select is((select status from public.booking_inquiries where id = '63000000-0000-4000-8000-000000000001'), 'pending', 'queue and follow-up review do not confirm booking');

select * from finish();
rollback;
