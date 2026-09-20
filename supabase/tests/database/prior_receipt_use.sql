-- SPEC-10: prior_receipt_use_v1 sees a receipt reused across bookings, which
-- record_payment_evidence_candidate cannot (its duplicate check is scoped to one booking_id).
-- Unlike cleaning_drive_archive.sql this one IS behavioural: the whole point of the function is
-- which rows it returns, and a catalogue check would pass on a function that always returns none.
-- Every fixture is created inside this transaction and disappears with the closing rollback, so
-- CI's empty baseline database (B103) is enough and no production row is read.
begin;
select plan(10);

select has_function('public', 'prior_receipt_use_v1', array['uuid'], 'prior_receipt_use_v1(uuid) exists');
select is_definer('public', 'prior_receipt_use_v1', array['uuid'], 'it is security definer');
select function_privs_are('public', 'prior_receipt_use_v1', array['uuid'], 'service_role', array['EXECUTE'],
  'service_role may execute it');
select function_privs_are('public', 'prior_receipt_use_v1', array['uuid'], 'anon', array[]::text[],
  'anon may not');

select has_index('public', 'payment_evidence_candidates', 'payment_evidence_property_hash_idx',
  'the property-scoped image index exists');
select has_index('public', 'payment_evidence_candidates', 'payment_evidence_property_reference_idx',
  'the property-scoped reference index exists');

-- Fixtures. Two bookings at one property and five candidates:
--   A1 booking A, image H1, reference ABC12345
--   B1 booking B, image H1 (the same screenshot resent)  -> must be found by image
--   B2 booking B, image H2, reference ABC12345           -> must be found by reference
--   A2 booking A, image H3, reference null               -> must never match B1/B3's null reference
--   B3 booking B, image H4, reference null
insert into public.properties (id, name) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'pgTAP property');
insert into public.booking_inquiries (id, property_id, guest_name, checkin_date, checkout_date) values
  ('bbbbbbbb-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-000000000001', 'Ana Cruz',  '2026-10-01', '2026-10-03'),
  ('bbbbbbbb-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-000000000001', 'Ben Reyes', '2026-11-01', '2026-11-03');

insert into public.payment_evidence_candidates
  (id, property_id, booking_id, source_type, source_artifact_id, content_hash, idempotency_key,
   parser_version, observed_at, source_admissibility, candidate_status, normalized_reference, created_at)
values
  ('cccccccc-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-00000000000a',
   'receipt_ocr', 'receipt:pgtap-a1', repeat('1', 64), 'pgtap-idem-key-a1-0000', 'receipt-ocr-v1',
   '2026-09-01T00:00:00Z', 'not_applicable', 'candidate', 'ABC12345', '2026-09-01T00:00:00Z'),
  ('cccccccc-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-00000000000b',
   'receipt_ocr', 'receipt:pgtap-b1', repeat('1', 64), 'pgtap-idem-key-b1-0000', 'receipt-ocr-v1',
   '2026-09-02T00:00:00Z', 'not_applicable', 'candidate', null, '2026-09-02T00:00:00Z'),
  ('cccccccc-0000-4000-8000-0000000000b2', 'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-00000000000b',
   'receipt_ocr', 'receipt:pgtap-b2', repeat('2', 64), 'pgtap-idem-key-b2-0000', 'receipt-ocr-v1',
   '2026-09-03T00:00:00Z', 'not_applicable', 'candidate', 'ABC12345', '2026-09-03T00:00:00Z'),
  ('cccccccc-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-00000000000a',
   'receipt_ocr', 'receipt:pgtap-a2', repeat('3', 64), 'pgtap-idem-key-a2-0000', 'receipt-ocr-v1',
   '2026-09-04T00:00:00Z', 'not_applicable', 'candidate', null, '2026-09-04T00:00:00Z'),
  ('cccccccc-0000-4000-8000-0000000000b3', 'aaaaaaaa-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-00000000000b',
   'receipt_ocr', 'receipt:pgtap-b3', repeat('4', 64), 'pgtap-idem-key-b3-0000', 'receipt-ocr-v1',
   '2026-09-05T00:00:00Z', 'not_applicable', 'candidate', null, '2026-09-05T00:00:00Z');

-- The same screenshot under a different booking is found, named, and labelled as an image match.
select results_eq(
  $$ select booking_id, guest_name, match from public.prior_receipt_use_v1('cccccccc-0000-4000-8000-0000000000b1')
     order by seen_at desc $$,
  $$ values ('bbbbbbbb-0000-4000-8000-00000000000a'::uuid, 'Ana Cruz'::text, 'image'::text) $$,
  'the same image on another booking is found once, with the other guest name');

-- The same reference number on a different image is found too, and labelled as a reference match.
select results_eq(
  $$ select booking_id, match from public.prior_receipt_use_v1('cccccccc-0000-4000-8000-0000000000b2') $$,
  $$ values ('bbbbbbbb-0000-4000-8000-00000000000a'::uuid, 'reference'::text) $$,
  'the same reference on another booking is found and labelled reference');

-- A2 shares nothing with anything on booking B: null reference must not match B1/B3's null.
select is_empty(
  $$ select 1 from public.prior_receipt_use_v1('cccccccc-0000-4000-8000-0000000000a2') $$,
  'a null reference never matches another null reference');

-- A1 and A2 are both on booking A. Same booking is not a cross-booking reuse.
select is_empty(
  $$ select 1 from public.prior_receipt_use_v1('cccccccc-0000-4000-8000-0000000000a1')
     where booking_id = 'bbbbbbbb-0000-4000-8000-00000000000a' $$,
  'a candidate never reports its own booking');

select * from finish();
rollback;
