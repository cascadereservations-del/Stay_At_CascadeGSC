-- Session 78 (lane E): release s78_guards_20261008, TASKS #20a. V8 - one receipt on two live bookings.
-- Synthetic rows only: property e8780000-...-a1, bookings e8780000-...-b*, everything rolls back.
begin;
select plan(16);

select ok((select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.run_system_verifier_v1(uuid,text,timestamptz)'::regprocedure),
  'the checks stay security definer with an empty search_path');
select ok(has_function_privilege('service_role', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute'),
  'the checks are service_role only');

insert into public.properties(id, name, is_active) values ('e8780000-0000-4000-8000-0000000000a1', 'Synthetic Receipt Reuse', true);

create function pg_temp.bk(p_n int, p_status text, p_from date, p_to date) returns uuid language sql as $$
  insert into public.booking_inquiries(id, property_id, guest_name, guest_email, checkin_date, checkout_date, status, source)
  values (('e8780000-0000-4000-8000-0000000000b' || lpad(p_n::text, 1, '0'))::uuid, 'e8780000-0000-4000-8000-0000000000a1',
          'Guest ' || p_n, 'g' || p_n || '@example.com', p_from, p_to, p_status, 'direct')
  returning id
$$;
create function pg_temp.ev(p_booking uuid, p_type text, p_hash text, p_ref text, p_amount numeric, p_at timestamptz) returns void language sql as $$
  insert into public.payment_evidence_candidates(property_id, booking_id, source_type, source_artifact_id, content_hash, idempotency_key,
    parser_version, observed_at, normalized_amount, normalized_currency, normalized_reference, source_admissibility, candidate_status)
  values ('e8780000-0000-4000-8000-0000000000a1', p_booking, p_type, 'synthetic:' || gen_random_uuid()::text, p_hash,
          'synthetic-v8:' || gen_random_uuid()::text, 'test-v1', p_at, p_amount, case when p_amount is null then null else 'PHP' end,
          p_ref, 'not_applicable', 'candidate')
$$;
create function pg_temp.v8(p_now timestamptz default '2030-01-01 02:00+00') returns jsonb language sql as $$
  select coalesce(jsonb_agg(e order by e->>'key'), '[]'::jsonb)
    from jsonb_array_elements(public.run_system_verifier_v1('e8780000-0000-4000-8000-0000000000a1', 'hourly', p_now)->'found') e
   where e->>'check_id' = 'V8'
$$;

-- Bookings 1..9 (uuid order follows the digit), all upcoming in Feb 2030.
select pg_temp.bk(1, 'pending',   '2030-02-01', '2030-02-03');
select pg_temp.bk(2, 'pending',   '2030-02-10', '2030-02-12');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b1', 'receipt_ocr', repeat('a', 64), null, 1750, '2030-01-01 00:00+00');
select is(pg_temp.v8(), '[]'::jsonb, 'one booking with a receipt is not a reuse');

-- The same image uploaded on a second live booking, days later.
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b2', 'receipt_ocr', repeat('a', 64), null, 1750, '2030-01-05 00:00+00');
select is((select e->>'key' || '|' || (e->'detail'->'match')::text from jsonb_array_elements(pg_temp.v8()) e),
  'V8:e8780000-0000-4000-8000-0000000000b1:e8780000-0000-4000-8000-0000000000b2|["image"]',
  'the same image on two live bookings is V8, keyed by both bookings, matched on the image');
select is((select e->>'severity' || '|' || (e->'detail'->'a'->>'guest') || '|' || (e->'detail'->'b'->>'status') from jsonb_array_elements(pg_temp.v8()) e),
  'red|Guest 1|pending', 'V8 is red and names both bookings');

-- A reference read off a receipt on booking 3, typed by the host as paid-outside on booking 4 (SPEC-44 refuses only the
-- other order: a typed reference already seen).
select pg_temp.bk(3, 'confirmed', '2030-02-15', '2030-02-17');
select pg_temp.bk(4, 'pending',   '2030-02-20', '2030-02-22');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b3', 'receipt_ocr',     repeat('b', 64), '1012345678901', 2000, '2030-01-02 00:00+00');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b4', 'manual_evidence', repeat('c', 64), '1012345678901', 2000, '2030-01-03 00:00+00');
select is((select (e->'detail'->'match')::text || '|' || (e->'detail'->>'reference') from jsonb_array_elements(pg_temp.v8()) e
            where e->>'key' = 'V8:e8780000-0000-4000-8000-0000000000b3:e8780000-0000-4000-8000-0000000000b4'),
  '["reference"]|1012345678901', 'the same reference on two live bookings is V8, matched on the reference');

-- Same amount, no reference on one side, 10 minutes apart: a re-cropped screenshot of one payment.
select pg_temp.bk(5, 'pending', '2030-02-24', '2030-02-25');
select pg_temp.bk(6, 'pending', '2030-02-26', '2030-02-27');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b5', 'receipt_ocr', repeat('d', 64), null,            3100, '2030-01-04 10:00+00');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b6', 'receipt_ocr', repeat('e', 64), '5550001112223', 3100, '2030-01-04 10:10+00');
select is((select (e->'detail'->'match')::text || '|' || (e->'detail'->>'amount') from jsonb_array_elements(pg_temp.v8()) e
            where e->>'key' = 'V8:e8780000-0000-4000-8000-0000000000b5:e8780000-0000-4000-8000-0000000000b6'),
  '["amount_time"]|3100.00', 'the same amount within 30 minutes, one side without a reference, is V8');

-- Not a reuse: the same amount two hours apart; the same amount with two different references; a manual attestation hash.
select pg_temp.bk(7, 'pending', '2030-03-01', '2030-03-02');
select pg_temp.bk(8, 'pending', '2030-03-03', '2030-03-04');
select pg_temp.bk(9, 'pending', '2030-03-05', '2030-03-06');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b7', 'receipt_ocr',     repeat('f', 64), null,            4200, '2030-01-06 10:00+00');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b8', 'receipt_ocr',     repeat('1', 64), '6660001112223', 4200, '2030-01-06 12:00+00');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b9', 'receipt_ocr',     repeat('2', 64), '7770001112223', 4200, '2030-01-06 12:05+00');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b9', 'manual_evidence', repeat('3', 64), '8880001112223', 4200, '2030-01-06 12:06+00');
select pg_temp.ev('e8780000-0000-4000-8000-0000000000b7', 'manual_evidence', repeat('3', 64), '9990001112223',  900, '2030-01-07 12:00+00');
select is((select count(*)::int from jsonb_array_elements(pg_temp.v8()) e
            where e->>'key' like '%-0000000000b7%' or e->>'key' like '%-0000000000b8%' or e->>'key' like '%-0000000000b9%'),
  0, 'two hours apart, two different references, and a shared manual attestation hash are not a reuse');

select is(jsonb_array_length(pg_temp.v8()), 3, 'exactly the three reuses are found');

-- A pair that is over (both stays checked out) is quiet.
select is(jsonb_array_length(pg_temp.v8('2030-04-01 02:00+00')), 0, 'a reuse between stays that have both ended is quiet');

-- Stored through apply_verifier_run_v1 under the hourly scope: new, red, open.
select ok(public.apply_verifier_run_v1('hourly', public.run_system_verifier_v1('e8780000-0000-4000-8000-0000000000a1', 'hourly', '2030-01-01 02:00+00')->'found', '2030-01-01 02:00+00')
            -> 'new' @> jsonb_build_array(jsonb_build_object('key', 'V8:e8780000-0000-4000-8000-0000000000b1:e8780000-0000-4000-8000-0000000000b2')),
  'apply: a first-seen V8 is new (alerted)');
select is((select status || '|' || check_id || '|' || severity from public.verifier_findings where key = 'V8:e8780000-0000-4000-8000-0000000000b1:e8780000-0000-4000-8000-0000000000b2'),
  'open|V8|red', 'apply: the V8 finding is stored open and red');

-- The honest resend: booking 2 lapses (cancelled), so the same image now covers one live booking. The hourly run resolves it.
update public.booking_inquiries set status = 'cancelled' where id = 'e8780000-0000-4000-8000-0000000000b2';
select is((select count(*)::int from jsonb_array_elements(pg_temp.v8()) e where e->>'key' like '%-0000000000b2'), 0,
  'a receipt reused after the first booking lapsed is an honest resend and is quiet');
select public.apply_verifier_run_v1('hourly', public.run_system_verifier_v1('e8780000-0000-4000-8000-0000000000a1', 'hourly', '2030-01-01 03:00+00')->'found', '2030-01-01 03:00+00');
select is((select status || '|' || resolved_by from public.verifier_findings where key = 'V8:e8780000-0000-4000-8000-0000000000b1:e8780000-0000-4000-8000-0000000000b2'),
  'resolved|auto', 'apply (hourly): a V8 that is gone resolves');

-- The daily scope carries V8 too.
update public.booking_inquiries set status = 'cancelled' where id = 'e8780000-0000-4000-8000-0000000000b4';
select public.apply_verifier_run_v1('daily', public.run_system_verifier_v1('e8780000-0000-4000-8000-0000000000a1', 'daily', '2030-01-01 04:00+00')->'found', '2030-01-01 04:00+00');
select is((select status || '|' || resolved_by from public.verifier_findings where key = 'V8:e8780000-0000-4000-8000-0000000000b3:e8780000-0000-4000-8000-0000000000b4'),
  'resolved|auto', 'apply (daily): a V8 that is gone resolves');
select is((select status from public.verifier_findings where key = 'V8:e8780000-0000-4000-8000-0000000000b5:e8780000-0000-4000-8000-0000000000b6'),
  'open', 'apply (daily): a V8 still present stays open');

select * from finish();
rollback;
