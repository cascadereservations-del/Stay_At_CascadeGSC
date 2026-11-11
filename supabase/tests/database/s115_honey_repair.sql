begin;
select plan(11);
insert into auth.users(id, email) values ('50ccca5a-3e59-4299-9680-837fd8d88ac4', 'zz-honey@example.com'), ('fea44ac5-61b0-41a6-8616-d7823e99151b', 'zz-lloyd@example.com') on conflict do nothing;
insert into public.staff_access_profiles(user_id, role) values ('50ccca5a-3e59-4299-9680-837fd8d88ac4', 'cleaner'), ('fea44ac5-61b0-41a6-8616-d7823e99151b', 'owner') on conflict do nothing;
insert into public.staff_property_access(user_id, property_id) values ('50ccca5a-3e59-4299-9680-837fd8d88ac4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd') on conflict do nothing;
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
update public.cleaning_sessions set pay_request_id = null where pay_request_id is not null;
delete from public.staff_pay_requests where id in ('6ff96a06-9276-4a18-8c10-61a7c60823cb', 'bcd28f42-6874-43ac-9ab2-b36ed0505303');
update public.staff_pay_requests set status = 'cancelled', cancelled_at = now() where status <> 'cancelled';
update public.calendar_events set status = 'cancelled' where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-h-aleisha', 'airbnb', 'confirmed', 'Aleisha Falgui', date '2026-11-07', date '2026-11-08'),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'zz-h-jasmin', 'airbnb', 'blocked', 'Jasmin', date '2026-11-06', date '2026-11-07');
insert into public.cleaning_sessions(id, submission_id, property_id, cleaner_name, checkout_date, checkin_date, cleaning_type, cleaned_at, issue_count, submitted_by_user_id, notes) values
  ('ad4f5e36-3d9f-40b5-9ea7-73ea7e829190', 'zz-h-s', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Honey', date '2026-11-08', date '2026-11-07', 'turnover', timestamptz '2026-11-08 06:28:48.193+00', 1, '50ccca5a-3e59-4299-9680-837fd8d88ac4', E'[Pre-Clean Condition]: [URGENT] Ga leak ang faucet');
insert into public.staff_pay_requests(id, property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount, paid_at, proof_file_unique_id, proof_sha256, proof_amount, proof_verdict, paid_by_name, sent_said_at, created_at) values
  ('6ff96a06-9276-4a18-8c10-61a7c60823cb', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '50ccca5a-3e59-4299-9680-837fd8d88ac4', 'Honey', 'zz-h-paid-key', 'paid',
   '[{"base": 500, "date": "2026-11-07", "kind": "advance", "type": "turnover", "guest": "Jasmin", "amount": 650.00, "transport": 150.00, "checkout_date": "2026-11-07"}]', 650,
   timestamptz '2026-11-09 13:46:06.656149+00', 'zz-h-f', 'zz-h-sha', 650, 'match', 'Lloyd', timestamptz '2026-11-09 13:45:45+00', timestamptz '2026-11-08 02:15:00+00');
insert into public.staff_pay_requests(id, property_id, payee_user_id, payee_name, idempotency_key, status, lines, total_amount, paying_at, paying_by_name, sent_said_at, created_at) values
  ('bcd28f42-6874-43ac-9ab2-b36ed0505303', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', '50ccca5a-3e59-4299-9680-837fd8d88ac4', 'Honey', 'zz-h-dup-key', 'paying',
   '[{"base": 500, "date": "2026-11-08", "kind": "clean", "type": "turnover", "guest": "Aleisha", "amount": 650.00, "transport": 150.00, "session_id": "ad4f5e36-3d9f-40b5-9ea7-73ea7e829190"}]', 650,
   timestamptz '2026-11-09 13:46:56+00', 'Finance', timestamptz '2026-11-09 13:47:39+00', timestamptz '2026-11-09 13:46:55+00');
update public.cleaning_sessions set pay_request_id = 'bcd28f42-6874-43ac-9ab2-b36ed0505303' where id = 'ad4f5e36-3d9f-40b5-9ea7-73ea7e829190';
insert into public.transactions(id, property_id, txn_type, category, status, source, transaction_date, gross_amount, logged_by, notes, external_ref) values
  ('f46e7a34-9ffa-4428-85b3-cd1e29fea946', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'expense', 'cleaning', 'confirmed', 'cleaner_fee', date '2026-11-07', 650, 'Lloyd via Staff app',
   'Cleaning fee paid ahead, report owed -- Honey, 2026-11-07, Turnover + transport. Pay request 6FF96A06.', 'cleanadv:6ff96a06-9276-4a18-8c10-61a7c60823cb:2026-11-07');

select is((select public.s_advance_session_v1('6ff96a06-9276-4a18-8c10-61a7c60823cb', date '2026-11-07')), null, 'before: no report is linked to the paid line');
select is((select count(*)::int from jsonb_array_elements(public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'hourly', now()) -> 'found') e where e ->> 'key' = 'V20:advance_no_stay:6FF96A06:2026-11-07'), 1, 'before: the verifier flags the line (live proof of V20)');
do $$
declare
  c_lloyd constant uuid := 'fea44ac5-61b0-41a6-8616-d7823e99151b';
  c_prop  constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  c_paid  constant uuid := '6ff96a06-9276-4a18-8c10-61a7c60823cb';
  c_dup   constant uuid := 'bcd28f42-6874-43ac-9ab2-b36ed0505303';
  c_sess  constant uuid := 'ad4f5e36-3d9f-40b5-9ea7-73ea7e829190';
  c_txn   constant uuid := 'f46e7a34-9ffa-4428-85b3-cd1e29fea946';
  c_old   constant date := date '2026-11-07';
  c_new   constant date := date '2026-11-08';
  v_p public.staff_pay_requests%rowtype; v_d public.staff_pay_requests%rowtype; v_s public.cleaning_sessions%rowtype; v_t public.transactions%rowtype;
  v_res jsonb; v_owed jsonb; v_kpi jsonb; n integer;
begin
  select * into v_p from public.staff_pay_requests where id = c_paid and property_id = c_prop;
  select * into v_d from public.staff_pay_requests where id = c_dup  and property_id = c_prop;
  select * into v_s from public.cleaning_sessions  where id = c_sess and property_id = c_prop;
  select * into v_t from public.transactions       where id = c_txn  and property_id = c_prop;
  if v_p.id is null or v_d.id is null or v_s.id is null or v_t.id is null then raise exception 'one of 6FF96A06, BCD28F42, session ad4f5e36 or transaction f46e7a34 is missing; nothing changed'; end if;

  -- a second run is a no-op
  if v_p.lines -> 0 ->> 'checkout_date' = c_new::text and v_s.pay_request_id = c_paid and v_s.fee_txn_id = c_txn and v_d.status = 'cancelled' then
    raise notice 'already repaired: 6FF96A06 holds 2026-11-08, session ad4f5e36 is linked to it, BCD28F42 is cancelled; nothing changed';
    return;
  end if;

  ---------------------------------------------------------------- guards (before anything is written)
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = to_regprocedure('public.get_missed_cleanings(uuid,integer)')) is distinct from '825eceefccf49f1dcca58fee4eda5664' then
    raise exception 'release s115_integrity_20261114 is not applied (get_missed_cleanings is not the s115 body); nothing changed';
  end if;
  if v_p.payee_user_id <> v_d.payee_user_id or v_p.payee_name not ilike 'honey%' then raise exception '6FF96A06 and BCD28F42 are not both Honey''s; nothing changed'; end if;
  if v_p.status <> 'paid' or v_p.total_amount <> 650 or v_p.proof_verdict is distinct from 'match' or v_p.proof_amount is distinct from 650 or v_p.paid_at is null then
    raise exception '6FF96A06 is not a paid PHP 650 request with a matching proof (status %, total %, verdict %); nothing changed', v_p.status, v_p.total_amount, v_p.proof_verdict;
  end if;
  if jsonb_array_length(v_p.lines) <> 1 or v_p.lines -> 0 ->> 'kind' <> 'advance' or v_p.lines -> 0 ->> 'checkout_date' <> c_old::text or (v_p.lines -> 0 ->> 'amount')::numeric <> 650 then
    raise exception '6FF96A06 is not exactly one PHP 650 advance line for 2026-11-07; nothing changed';
  end if;
  if public.s_advance_session_v1(c_paid, c_old) is not null then raise exception '2026-11-07 already has a report on 6FF96A06; nothing changed'; end if;

  if v_d.status not in ('requested', 'paying') or v_d.proof_file_unique_id is not null or v_d.proof_sha256 is not null or v_d.paid_at is not null then
    raise exception 'BCD28F42 is not an open request without a payment proof (status %); nothing changed', v_d.status;
  end if;
  if jsonb_array_length(v_d.lines) <> 1 or v_d.lines -> 0 ->> 'kind' <> 'clean' or v_d.lines -> 0 ->> 'session_id' <> c_sess::text then
    raise exception 'BCD28F42 is not exactly one clean line for session ad4f5e36; nothing changed';
  end if;
  if v_s.checkout_date is distinct from c_new or v_s.submitted_by_user_id <> v_p.payee_user_id or v_s.pay_request_id is distinct from c_dup or v_s.fee_paid_at is not null or v_s.fee_txn_id is not null then
    raise exception 'session ad4f5e36 is not Honey''s unpaid report for 2026-11-08 on BCD28F42; nothing changed';
  end if;
  if exists (select 1 from public.transactions t where t.external_ref in ('cleanfee:' || c_sess, 'cleanadv:' || c_paid || ':' || c_new) and t.status <> 'void') then
    raise exception 'the 2026-11-08 turnover already has a fee transaction; nothing changed';
  end if;
  if v_t.status <> 'confirmed' or v_t.gross_amount <> 650 or v_t.external_ref <> 'cleanadv:' || c_paid || ':' || c_old then
    raise exception 'transaction f46e7a34 is not the confirmed PHP 650 cleanadv row for 6FF96A06 / 2026-11-07; nothing changed';
  end if;
  if not exists (select 1 from public.calendar_events ce where ce.property_id = c_prop and ce.status = 'confirmed' and ce.checkout_date = c_new) then
    raise exception 'no confirmed calendar checkout on 2026-11-08; nothing changed';
  end if;
  if exists (select 1 from public.staff_pay_requests q, jsonb_array_elements(q.lines) l
              where q.property_id = c_prop and q.status <> 'cancelled' and l ->> 'kind' = 'advance' and l ->> 'checkout_date' = c_new::text) then
    raise exception 'a live advance line already holds 2026-11-08; nothing changed';
  end if;

  ---------------------------------------------------------------- act as Lloyd
  perform set_config('request.jwt.claims', json_build_object('sub', c_lloyd, 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
  perform public.admin_audit_context_v1('s115: advance was Aleisha 11-08 under the wrong date');

  -- 1. cancel the duplicate (the Finance buttons: "Not sent", then "Cancel"). Releases session ad4f5e36.
  if v_d.status = 'paying' then
    v_res := public.telegram_staff_pay_step_v1(c_dup, 'not_sent', null, 'Lloyd', null);
    if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'not_sent step refused: %; nothing changed', v_res; end if;
  end if;
  v_res := public.telegram_staff_pay_step_v1(c_dup, 'cancel', null, 'Lloyd', null);
  if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'cancel step refused: %; nothing changed', v_res; end if;

  -- 2. the paid line becomes Aleisha's 11-08
  update public.staff_pay_requests
     set lines = (select jsonb_agg(case when l.value ->> 'kind' = 'advance' and l.value ->> 'checkout_date' = c_old::text
                                        then l.value || jsonb_build_object('date', c_new::text, 'checkout_date', c_new::text, 'guest', 'Aleisha') else l.value end order by l.ord)
                    from jsonb_array_elements(lines) with ordinality l(value, ord))
   where id = c_paid;

  -- 3. its transaction follows the date
  update public.transactions
     set external_ref = 'cleanadv:' || c_paid || ':' || c_new, transaction_date = c_new, notes = replace(notes, c_old::text, c_new::text)
   where id = c_txn;

  -- 4. link the report as the link trigger does for a paid request
  update public.cleaning_sessions
     set pay_request_id = c_paid, fee_amount = 650, fee_paid_at = v_p.paid_at, fee_txn_id = c_txn
   where id = c_sess;

  ---------------------------------------------------------------- checks after
  if public.s_advance_session_v1(c_paid, c_new) is distinct from c_sess then raise exception 'after: s_advance_session_v1(6FF96A06, 2026-11-08) is not session ad4f5e36'; end if;
  if not exists (select 1 from public.staff_pay_requests where id = c_paid and status = 'paid' and total_amount = 650 and lines -> 0 ->> 'checkout_date' = c_new::text and lines -> 0 ->> 'date' = c_new::text and lines -> 0 ->> 'guest' = 'Aleisha') then
    raise exception 'after: 6FF96A06 does not hold the relabelled line';
  end if;
  if not exists (select 1 from public.staff_pay_requests where id = c_dup and status = 'cancelled') then raise exception 'after: BCD28F42 is not cancelled'; end if;
  select count(*) into n from public.cleaning_sessions where pay_request_id = c_dup;
  if n <> 0 then raise exception 'after: % session(s) still on BCD28F42', n; end if;
  if not exists (select 1 from public.transactions where id = c_txn and external_ref = 'cleanadv:' || c_paid || ':' || c_new and transaction_date = c_new and status = 'confirmed' and gross_amount = 650) then
    raise exception 'after: transaction f46e7a34 was not relabelled';
  end if;
  if not exists (select 1 from public.cleaning_sessions where id = c_sess and pay_request_id = c_paid and fee_amount = 650 and fee_paid_at = v_p.paid_at and fee_txn_id = c_txn) then
    raise exception 'after: session ad4f5e36 is not linked and stamped paid';
  end if;
  -- Honey's own Pay screen: no report owed
  perform set_config('request.jwt.claims', json_build_object('sub', v_p.payee_user_id, 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
  v_owed := public.staff_pay_candidates_v1() -> 'reports_owed';
  perform set_config('request.jwt.claims', json_build_object('sub', c_lloyd, 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
  if v_owed is distinct from '[]'::jsonb then raise exception 'after: Honey''s reports_owed is not empty: %', v_owed; end if;
  -- the November cleaner-fee drift should be gone (V19:2026-11:cleaner_fee); another fee row drifting is reported, not rolled back
  v_kpi := public.kpi_reconcile_v1(c_prop, date '2026-11-01');
  if exists (select 1 from jsonb_array_elements(v_kpi) f where f -> 'detail' ->> 'metric' = 'cleaner_fee') then
    raise warning 'after: kpi_reconcile_v1 still reports a cleaner_fee difference for 2026-11: %', v_kpi;
  end if;
  raise notice 'Honey repaired: 6FF96A06 now holds Aleisha 2026-11-08 and is linked to session ad4f5e36; BCD28F42 cancelled; transaction f46e7a34 relabelled; reports_owed []';
end $$;
select is(public.s_advance_session_v1('6ff96a06-9276-4a18-8c10-61a7c60823cb', date '2026-11-08'), 'ad4f5e36-3d9f-40b5-9ea7-73ea7e829190'::uuid, 'after: the report is found for 11-08');
select is((select status from public.staff_pay_requests where id = 'bcd28f42-6874-43ac-9ab2-b36ed0505303'), 'cancelled', 'BCD28F42 cancelled');
select is((select lines -> 0 ->> 'guest' from public.staff_pay_requests where id = '6ff96a06-9276-4a18-8c10-61a7c60823cb'), 'Aleisha', 'line relabelled');
select is((select external_ref from public.transactions where id = 'f46e7a34-9ffa-4428-85b3-cd1e29fea946'), 'cleanadv:6ff96a06-9276-4a18-8c10-61a7c60823cb:2026-11-08', 'txn external_ref');
select is((select notes from public.transactions where id = 'f46e7a34-9ffa-4428-85b3-cd1e29fea946'), 'Cleaning fee paid ahead, report owed -- Honey, 2026-11-08, Turnover + transport. Pay request 6FF96A06.', 'txn notes');
select is((select count(*)::int from public.admin_audit_log where reason = 's115: advance was Aleisha 11-08 under the wrong date'), 4, 'audit rows: the cancelled request (not_sent + cancel), the paid request line and the transaction carry the reason');
select is((select fee_txn_id from public.cleaning_sessions where id = 'ad4f5e36-3d9f-40b5-9ea7-73ea7e829190'), 'f46e7a34-9ffa-4428-85b3-cd1e29fea946'::uuid, 'session linked');
-- a second run changes nothing
select set_config('s115.before', (select md5(string_agg(x::text, '' order by id)) from public.staff_pay_requests x where id in ('6ff96a06-9276-4a18-8c10-61a7c60823cb', 'bcd28f42-6874-43ac-9ab2-b36ed0505303')), false);
do $$
declare
  c_lloyd constant uuid := 'fea44ac5-61b0-41a6-8616-d7823e99151b';
  c_prop  constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  c_paid  constant uuid := '6ff96a06-9276-4a18-8c10-61a7c60823cb';
  c_dup   constant uuid := 'bcd28f42-6874-43ac-9ab2-b36ed0505303';
  c_sess  constant uuid := 'ad4f5e36-3d9f-40b5-9ea7-73ea7e829190';
  c_txn   constant uuid := 'f46e7a34-9ffa-4428-85b3-cd1e29fea946';
  c_old   constant date := date '2026-11-07';
  c_new   constant date := date '2026-11-08';
  v_p public.staff_pay_requests%rowtype; v_d public.staff_pay_requests%rowtype; v_s public.cleaning_sessions%rowtype; v_t public.transactions%rowtype;
  v_res jsonb; v_owed jsonb; v_kpi jsonb; n integer;
begin
  select * into v_p from public.staff_pay_requests where id = c_paid and property_id = c_prop;
  select * into v_d from public.staff_pay_requests where id = c_dup  and property_id = c_prop;
  select * into v_s from public.cleaning_sessions  where id = c_sess and property_id = c_prop;
  select * into v_t from public.transactions       where id = c_txn  and property_id = c_prop;
  if v_p.id is null or v_d.id is null or v_s.id is null or v_t.id is null then raise exception 'one of 6FF96A06, BCD28F42, session ad4f5e36 or transaction f46e7a34 is missing; nothing changed'; end if;

  -- a second run is a no-op
  if v_p.lines -> 0 ->> 'checkout_date' = c_new::text and v_s.pay_request_id = c_paid and v_s.fee_txn_id = c_txn and v_d.status = 'cancelled' then
    raise notice 'already repaired: 6FF96A06 holds 2026-11-08, session ad4f5e36 is linked to it, BCD28F42 is cancelled; nothing changed';
    return;
  end if;

  ---------------------------------------------------------------- guards (before anything is written)
  if (select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = to_regprocedure('public.get_missed_cleanings(uuid,integer)')) is distinct from '825eceefccf49f1dcca58fee4eda5664' then
    raise exception 'release s115_integrity_20261114 is not applied (get_missed_cleanings is not the s115 body); nothing changed';
  end if;
  if v_p.payee_user_id <> v_d.payee_user_id or v_p.payee_name not ilike 'honey%' then raise exception '6FF96A06 and BCD28F42 are not both Honey''s; nothing changed'; end if;
  if v_p.status <> 'paid' or v_p.total_amount <> 650 or v_p.proof_verdict is distinct from 'match' or v_p.proof_amount is distinct from 650 or v_p.paid_at is null then
    raise exception '6FF96A06 is not a paid PHP 650 request with a matching proof (status %, total %, verdict %); nothing changed', v_p.status, v_p.total_amount, v_p.proof_verdict;
  end if;
  if jsonb_array_length(v_p.lines) <> 1 or v_p.lines -> 0 ->> 'kind' <> 'advance' or v_p.lines -> 0 ->> 'checkout_date' <> c_old::text or (v_p.lines -> 0 ->> 'amount')::numeric <> 650 then
    raise exception '6FF96A06 is not exactly one PHP 650 advance line for 2026-11-07; nothing changed';
  end if;
  if public.s_advance_session_v1(c_paid, c_old) is not null then raise exception '2026-11-07 already has a report on 6FF96A06; nothing changed'; end if;

  if v_d.status not in ('requested', 'paying') or v_d.proof_file_unique_id is not null or v_d.proof_sha256 is not null or v_d.paid_at is not null then
    raise exception 'BCD28F42 is not an open request without a payment proof (status %); nothing changed', v_d.status;
  end if;
  if jsonb_array_length(v_d.lines) <> 1 or v_d.lines -> 0 ->> 'kind' <> 'clean' or v_d.lines -> 0 ->> 'session_id' <> c_sess::text then
    raise exception 'BCD28F42 is not exactly one clean line for session ad4f5e36; nothing changed';
  end if;
  if v_s.checkout_date is distinct from c_new or v_s.submitted_by_user_id <> v_p.payee_user_id or v_s.pay_request_id is distinct from c_dup or v_s.fee_paid_at is not null or v_s.fee_txn_id is not null then
    raise exception 'session ad4f5e36 is not Honey''s unpaid report for 2026-11-08 on BCD28F42; nothing changed';
  end if;
  if exists (select 1 from public.transactions t where t.external_ref in ('cleanfee:' || c_sess, 'cleanadv:' || c_paid || ':' || c_new) and t.status <> 'void') then
    raise exception 'the 2026-11-08 turnover already has a fee transaction; nothing changed';
  end if;
  if v_t.status <> 'confirmed' or v_t.gross_amount <> 650 or v_t.external_ref <> 'cleanadv:' || c_paid || ':' || c_old then
    raise exception 'transaction f46e7a34 is not the confirmed PHP 650 cleanadv row for 6FF96A06 / 2026-11-07; nothing changed';
  end if;
  if not exists (select 1 from public.calendar_events ce where ce.property_id = c_prop and ce.status = 'confirmed' and ce.checkout_date = c_new) then
    raise exception 'no confirmed calendar checkout on 2026-11-08; nothing changed';
  end if;
  if exists (select 1 from public.staff_pay_requests q, jsonb_array_elements(q.lines) l
              where q.property_id = c_prop and q.status <> 'cancelled' and l ->> 'kind' = 'advance' and l ->> 'checkout_date' = c_new::text) then
    raise exception 'a live advance line already holds 2026-11-08; nothing changed';
  end if;

  ---------------------------------------------------------------- act as Lloyd
  perform set_config('request.jwt.claims', json_build_object('sub', c_lloyd, 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
  perform public.admin_audit_context_v1('s115: advance was Aleisha 11-08 under the wrong date');

  -- 1. cancel the duplicate (the Finance buttons: "Not sent", then "Cancel"). Releases session ad4f5e36.
  if v_d.status = 'paying' then
    v_res := public.telegram_staff_pay_step_v1(c_dup, 'not_sent', null, 'Lloyd', null);
    if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'not_sent step refused: %; nothing changed', v_res; end if;
  end if;
  v_res := public.telegram_staff_pay_step_v1(c_dup, 'cancel', null, 'Lloyd', null);
  if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'cancel step refused: %; nothing changed', v_res; end if;

  -- 2. the paid line becomes Aleisha's 11-08
  update public.staff_pay_requests
     set lines = (select jsonb_agg(case when l.value ->> 'kind' = 'advance' and l.value ->> 'checkout_date' = c_old::text
                                        then l.value || jsonb_build_object('date', c_new::text, 'checkout_date', c_new::text, 'guest', 'Aleisha') else l.value end order by l.ord)
                    from jsonb_array_elements(lines) with ordinality l(value, ord))
   where id = c_paid;

  -- 3. its transaction follows the date
  update public.transactions
     set external_ref = 'cleanadv:' || c_paid || ':' || c_new, transaction_date = c_new, notes = replace(notes, c_old::text, c_new::text)
   where id = c_txn;

  -- 4. link the report as the link trigger does for a paid request
  update public.cleaning_sessions
     set pay_request_id = c_paid, fee_amount = 650, fee_paid_at = v_p.paid_at, fee_txn_id = c_txn
   where id = c_sess;

  ---------------------------------------------------------------- checks after
  if public.s_advance_session_v1(c_paid, c_new) is distinct from c_sess then raise exception 'after: s_advance_session_v1(6FF96A06, 2026-11-08) is not session ad4f5e36'; end if;
  if not exists (select 1 from public.staff_pay_requests where id = c_paid and status = 'paid' and total_amount = 650 and lines -> 0 ->> 'checkout_date' = c_new::text and lines -> 0 ->> 'date' = c_new::text and lines -> 0 ->> 'guest' = 'Aleisha') then
    raise exception 'after: 6FF96A06 does not hold the relabelled line';
  end if;
  if not exists (select 1 from public.staff_pay_requests where id = c_dup and status = 'cancelled') then raise exception 'after: BCD28F42 is not cancelled'; end if;
  select count(*) into n from public.cleaning_sessions where pay_request_id = c_dup;
  if n <> 0 then raise exception 'after: % session(s) still on BCD28F42', n; end if;
  if not exists (select 1 from public.transactions where id = c_txn and external_ref = 'cleanadv:' || c_paid || ':' || c_new and transaction_date = c_new and status = 'confirmed' and gross_amount = 650) then
    raise exception 'after: transaction f46e7a34 was not relabelled';
  end if;
  if not exists (select 1 from public.cleaning_sessions where id = c_sess and pay_request_id = c_paid and fee_amount = 650 and fee_paid_at = v_p.paid_at and fee_txn_id = c_txn) then
    raise exception 'after: session ad4f5e36 is not linked and stamped paid';
  end if;
  -- Honey's own Pay screen: no report owed
  perform set_config('request.jwt.claims', json_build_object('sub', v_p.payee_user_id, 'role', 'authenticated', 'aal', 'aal1', 'iat', extract(epoch from now())::bigint)::text, true);
  v_owed := public.staff_pay_candidates_v1() -> 'reports_owed';
  perform set_config('request.jwt.claims', json_build_object('sub', c_lloyd, 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
  if v_owed is distinct from '[]'::jsonb then raise exception 'after: Honey''s reports_owed is not empty: %', v_owed; end if;
  -- the November cleaner-fee drift should be gone (V19:2026-11:cleaner_fee); another fee row drifting is reported, not rolled back
  v_kpi := public.kpi_reconcile_v1(c_prop, date '2026-11-01');
  if exists (select 1 from jsonb_array_elements(v_kpi) f where f -> 'detail' ->> 'metric' = 'cleaner_fee') then
    raise warning 'after: kpi_reconcile_v1 still reports a cleaner_fee difference for 2026-11: %', v_kpi;
  end if;
  raise notice 'Honey repaired: 6FF96A06 now holds Aleisha 2026-11-08 and is linked to session ad4f5e36; BCD28F42 cancelled; transaction f46e7a34 relabelled; reports_owed []';
end $$;
select is((select md5(string_agg(x::text, '' order by id)) from public.staff_pay_requests x where id in ('6ff96a06-9276-4a18-8c10-61a7c60823cb', 'bcd28f42-6874-43ac-9ab2-b36ed0505303')), current_setting('s115.before'), 'a second run writes nothing');
-- the verifier no longer flags the relabelled line
select is((select count(*)::int from jsonb_array_elements(public.run_system_verifier_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'hourly', now()) -> 'found') e where e ->> 'check_id' = 'V20' and e ->> 'key' like 'V20:advance_no_stay:6FF96A06%'), 0, 'V20:advance_no_stay is gone after the repair');
select * from finish();
rollback;
