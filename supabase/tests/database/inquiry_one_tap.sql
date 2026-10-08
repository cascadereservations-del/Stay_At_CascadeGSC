-- Session 76 (SPEC-44 Revision 1): release inquiry_one_tap_20261008. One-tap confirm (receipt or paid outside), staff/Telegram gates,
-- reference-reuse refusal, decline, the income-row bypass guard, the bypass repair, Cassy hand-back and the Inquiries payment rows.
-- Synthetic fixtures only (public repo) on a property private to this suite; rows are inserted as the owner (service_role has no
-- BYPASSRLS in the rehearsal, and a --no-acl restore has no table grants), RPCs are called as authenticated / service_role, and
-- everything goes with the closing rollback.
--   F finance (tg 944000001)  C cleaner (tg 944000002)  I inspector  A admin (tg 944000004)  tg 944000099 mapped to nobody
--   b01 receipt path  b02-b06 paid outside (messenger_gcash, gcash_qr, bank, cash, other)  b07 validation  b08 reference reuse + roles
--   b09 calendar conflict  b10 Telegram  b11 guard  b12 void  b13 expiry  b14 bypass-confirmed (repair)  b15 receipt + active hold
--   b16 overlaps b15 hold (deposit 0)  b17 decline without receipt  b18 decline with receipt  b19 Telegram receipt  b20 receipt already
--   rejected  b21 receipt vs b22 hold  b23 receipt vs an Airbnb stay (re-attest)  b24 supersede
--   b25 receipt vs an Airbnb stay, eight conflicted retries each passing the previous comparison id (no attestation chain)
-- pg_net and Vault are absent from a rehearsal copy: they are stubbed here (and rolled back) so the guest-messages call is observable.
-- Where the real pg_net exists (CI) the stub is not installed and that one assertion passes vacuously.
begin;
select plan(95);

do $$
begin
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null and to_regclass('vault.decrypted_secrets') is null then
    create schema if not exists net;
    create table net.s76_calls(url text, headers jsonb, body jsonb);
    create function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
                                  headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
      returns bigint language sql as $f$ insert into net.s76_calls values (url, headers, body); select 1::bigint $f$;
    create schema if not exists vault;
    create table vault.decrypted_secrets(name text, decrypted_secret text);
    insert into vault.decrypted_secrets values ('cascade_cron_shared_secret', 'S76-SYNTHETIC-ONLY');
    perform set_config('s76.stub', 'on', true);
  else
    perform set_config('s76.stub', 'off', true);
  end if;
end $$;

-- shape and grants
select has_function('public', '_confirm_direct_booking_core', array['uuid','uuid','text','text','numeric','text','uuid','text'], 'core exists');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef and p.proconfig = array['search_path=""']
             and p.proname in ('_confirm_direct_booking_core','staff_confirm_direct_booking_v1','telegram_confirm_direct_booking_v1',
                               'staff_decline_direct_booking_v1','staff_inquiry_payments_v1','guard_direct_booking_income_confirm',
                               'fn_direct_booking_cascade','_repair_bypass_confirmed_v1','concierge_resume_cassy_v1')),
  9, 'all nine functions are security definer with an empty search_path');
select ok(has_function_privilege('authenticated', 'public.staff_confirm_direct_booking_v1(uuid,text,text,numeric,text,uuid,text)', 'execute')
      and has_function_privilege('authenticated', 'public.staff_decline_direct_booking_v1(uuid,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.staff_inquiry_payments_v1(uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.concierge_resume_cassy_v1(text)', 'execute')
      and not has_function_privilege('anon', 'public.staff_confirm_direct_booking_v1(uuid,text,text,numeric,text,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.staff_decline_direct_booking_v1(uuid,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.staff_inquiry_payments_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.concierge_resume_cassy_v1(text)', 'execute'),
  'staff RPCs: authenticated yes, anon no');
select ok(has_function_privilege('service_role', 'public.telegram_confirm_direct_booking_v1(bigint,uuid,text,text,numeric,text,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_confirm_direct_booking_v1(bigint,uuid,text,text,numeric,text,uuid,text)', 'execute')
      and not has_function_privilege('anon', 'public.telegram_confirm_direct_booking_v1(bigint,uuid,text,text,numeric,text,uuid,text)', 'execute'),
  'telegram confirm: service_role only');
select ok(not has_function_privilege('anon', 'public._confirm_direct_booking_core(uuid,uuid,text,text,numeric,text,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public._confirm_direct_booking_core(uuid,uuid,text,text,numeric,text,uuid,text)', 'execute')
      and not has_function_privilege('service_role', 'public._confirm_direct_booking_core(uuid,uuid,text,text,numeric,text,uuid,text)', 'execute')
      and not has_function_privilege('authenticated', 'public._repair_bypass_confirmed_v1()', 'execute')
      and not has_function_privilege('service_role', 'public._repair_bypass_confirmed_v1()', 'execute'),
  'core and repair: no client role may execute');
select is((select count(*)::int from pg_trigger where tgrelid = 'public.transactions'::regclass and tgname = 'trg_guard_direct_booking_income_confirm'
             and tgenabled = 'O' and pg_get_triggerdef(oid) like '%BEFORE UPDATE OF status%'), 1, 'the income-confirm guard is a BEFORE UPDATE OF status trigger');
select ok((select prosrc not like '%confirmEmail%' from pg_proc where oid = 'public.fn_direct_booking_cascade()'::regprocedure),
  'the cascade no longer sends confirmEmail');

-- fixtures
insert into public.properties(id, name, is_active) values ('e4400000-0000-4000-8000-000000000044', 'Synthetic One Tap 76', true);
insert into auth.users(id) values
  ('e4400000-0000-4000-8000-0000000000a1'), ('e4400000-0000-4000-8000-0000000000a2'),
  ('e4400000-0000-4000-8000-0000000000a3'), ('e4400000-0000-4000-8000-0000000000a4');
insert into public.staff_access_profiles(user_id, role, telegram_user_id, disabled_at, note) values
  ('e4400000-0000-4000-8000-0000000000a1', 'finance',   944000001, null, 'Finance F'),
  ('e4400000-0000-4000-8000-0000000000a2', 'cleaner',   944000002, null, 'Cleaner C'),
  ('e4400000-0000-4000-8000-0000000000a3', 'inspector', null,      null, 'Inspector I'),
  ('e4400000-0000-4000-8000-0000000000a4', 'admin',     944000004, null, 'Admin A');
insert into public.staff_property_access(user_id, property_id)
select u, 'e4400000-0000-4000-8000-000000000044'::uuid from unnest(array[
  'e4400000-0000-4000-8000-0000000000a1', 'e4400000-0000-4000-8000-0000000000a2',
  'e4400000-0000-4000-8000-0000000000a3', 'e4400000-0000-4000-8000-0000000000a4']::uuid[]) u;

insert into public.booking_inquiries(id, property_id, guest_name, guest_phone, checkin_date, checkout_date, pax, status, source, receipt_image_path, total_amount, deposit_amount)
select ('c0de7644-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid, 'e4400000-0000-4000-8000-000000000044', 'Synthetic ' || n, '0917000' || lpad(n::text, 4, '0'),
       current_date + d, current_date + d + 2, 2, st, 'direct', rc, tot, dep
  from (values (1, 500, 'pending', 'receipts/s76-b01.jpg', 3560, 1780), (2, 505, 'pending', null, 2000, 1000), (3, 510, 'pending', null, 2000, 1000),
               (4, 515, 'pending', null, 2000, 1000), (5, 520, 'pending', null, 2000, 1000), (6, 525, 'pending', null, 2000, 1000),
               (7, 530, 'pending', null, 2000, 1000), (8, 535, 'pending', null, 2000, 1000), (9, 540, 'pending', null, 2000, 1000),
               (10, 545, 'pending', null, 2000, 1000), (11, 550, 'pending', null, 2000, 1000), (12, 555, 'pending', null, 2000, 1000),
               (13, 560, 'pending', null, 2000, 1000), (14, 565, 'confirmed', null, 2000, 1000), (15, 570, 'pending', 'receipts/s76-b15.jpg', 3000, 1500),
               (16, 571, 'pending', null, 2500, 0), (17, 580, 'pending', null, 2000, 1000), (18, 585, 'pending', 'receipts/s76-b18.jpg', 2000, 1000),
               (19, 590, 'pending', 'receipts/s76-b19.jpg', 2000, 1000), (20, 595, 'pending', 'receipts/s76-b20.jpg', 2000, 1000),
               (21, 600, 'pending', 'receipts/s76-b21.jpg', 2000, 1000), (22, 600, 'pending', null, 2000, 1000),
               (23, 610, 'pending', 'receipts/s76-b23.jpg', 2000, 1000), (25, 640, 'pending', 'receipts/s76-b25.jpg', 2000, 1000)
       ) v(n, d, st, rc, tot, dep);
-- b24: the same guest (phone AND e-mail) about to re-book other dates, for supersede_pending_direct_requests_v1
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, status, source, total_amount, deposit_amount)
values ('c0de7644-0000-4000-8000-000000000024', 'e4400000-0000-4000-8000-000000000044', 'Synthetic 24', 'b24@example.com', '09170000024',
        current_date + 620, current_date + 622, 2, 'pending', 'direct', 2000, 1000);
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, guest_name)
select 'e4400000-0000-4000-8000-000000000044', 'direct:c0de7644-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'), 'direct', st, current_date + d, current_date + d + 2, 'Synthetic ' || n
  from (values (1, 500, 'blocked'), (11, 550, 'blocked'), (12, 555, 'blocked'), (13, 560, 'blocked'), (14, 565, 'confirmed'), (24, 620, 'blocked')) v(n, d, st);
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, guest_name) values
  ('e4400000-0000-4000-8000-000000000044', 'synthetic-s76-09@airbnb.com', 'airbnb', 'confirmed', current_date + 539, current_date + 543, 'Synthetic Airbnb'),
  ('e4400000-0000-4000-8000-000000000044', 'synthetic-s76-23@airbnb.com', 'airbnb', 'confirmed', current_date + 609, current_date + 613, 'Synthetic Airbnb 23'),
  ('e4400000-0000-4000-8000-000000000044', 'synthetic-s76-25@airbnb.com', 'airbnb', 'confirmed', current_date + 639, current_date + 643, 'Synthetic Airbnb 25');
insert into public.transactions(id, property_id, txn_type, category, source, status, transaction_date, gross_amount, currency, booking_id, external_ref)
select ('e4400000-0000-4000-8000-0000000007' || lpad(n::text, 2, '0'))::uuid, 'e4400000-0000-4000-8000-000000000044', 'income', 'direct_booking', 'direct_booking', st,
       current_date + 500, 1000, 'PHP', ('c0de7644-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid, 'c0de7644-0000-4000-8000-0000000000' || lpad(n::text, 2, '0')
  from (values (1, 'pending_review'), (9, 'pending_review'), (11, 'pending_review'), (12, 'pending_review'), (13, 'pending_review'), (14, 'confirmed'), (24, 'pending_review')) v(n, st);
insert into public.booking_holds(property_id, booking_id, checkin_date, checkout_date, expires_at, status, idempotency_key)
values ('e4400000-0000-4000-8000-000000000044', 'c0de7644-0000-4000-8000-000000000013', current_date + 560, current_date + 562, now() - interval '1 hour', 'active',
        'hold:c0de7644-0000-4000-8000-000000000013');
select public.open_booking_hold_v1('c0de7644-0000-4000-8000-000000000015', 24);
select public.open_booking_hold_v1('c0de7644-0000-4000-8000-000000000022', 24);
-- guest-sent receipts for b01, b15, b18, b19, b20, b21, b23
select set_config('s76.cmp' || n, public.compare_booking_payment_evidence(b, array[public.record_payment_evidence_candidate(
         b, 'receipt_ocr', 'receipt:s76-' || n || '-0000', encode(extensions.digest('s76-receipt-' || n, 'sha256'), 'hex'), 's76-receipt-candidate-' || n,
         'ocr-v1', now(), amt, 'PHP', rf)])::text, true)
  from (values ('01', 'c0de7644-0000-4000-8000-000000000001'::uuid, 1780, '7001234567890'),
               ('15', 'c0de7644-0000-4000-8000-000000000015'::uuid, 1500, 'R15ABCDEF'),
               ('18', 'c0de7644-0000-4000-8000-000000000018'::uuid, 1000, 'R18ABCDEF'),
               ('19', 'c0de7644-0000-4000-8000-000000000019'::uuid, 1000, 'R19ABCDEF'),
               ('20', 'c0de7644-0000-4000-8000-000000000020'::uuid, 1000, 'R20ABCDEF'),
               ('21', 'c0de7644-0000-4000-8000-000000000021'::uuid, 1000, 'R21ABCDEF'),
               ('23', 'c0de7644-0000-4000-8000-000000000023'::uuid, 1000, 'R23ABCDEF'),
               ('25', 'c0de7644-0000-4000-8000-000000000025'::uuid, 1000, 'R25ABCDEF')) v(n, b, amt, rf);
-- b20's receipt was already rejected in the Finance queue
insert into public.payment_finance_reviews(property_id, booking_id, comparison_id, reviewer_user_id, outcome, reason)
values ('e4400000-0000-4000-8000-000000000044', 'c0de7644-0000-4000-8000-000000000020', current_setting('s76.cmp20')::uuid,
        'e4400000-0000-4000-8000-0000000000a1', 'rejected', 'synthetic: amount not received');
insert into public.concierge_threads(psid, guest_name, human_until) values ('synthetic-psid-s76-0001', 'Synthetic Guest', now() + interval '1 day');

-- receipt path, as Finance F
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select set_config('s76.r01', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000001', null, null, 1780, null,
  current_setting('s76.cmp01')::uuid, 's76-onetap-key-b01-receipt')::text, true);
-- paid outside, one booking per method
select set_config('s76.r0' || n, public.staff_confirm_direct_booking_v1(('c0de7644-0000-4000-8000-00000000000' || n)::uuid, m, rf, 1000, nt, null, 's76-onetap-key-b0' || n || '-outside')::text, true)
  from (values (2, 'messenger_gcash', '1001234567890', null), (3, 'gcash_qr', '1002234567890', null), (4, 'bank', 'BPI-55501234', null),
               (5, 'cash', null, 'Paid at the door, counted by F'), (6, 'other', 'PAYMAYA9988', null)) v(n, m, rf, nt);
reset role;

select is(current_setting('s76.r01')::jsonb ->> 'outcome', 'confirmed', 'receipt: F confirms b01 with the comparison id');
select is(current_setting('s76.r01')::jsonb ->> 'comparison_id', current_setting('s76.cmp01'), 'receipt: the result names the receipt comparison');
select ok((select b.status = 'confirmed' from public.booking_inquiries b where b.id = 'c0de7644-0000-4000-8000-000000000001')
      and exists (select 1 from public.airbnb_reservations r where r.confirmation_code = 'DIRECT:c0de7644-0000-4000-8000-000000000001' and r.status = 'confirmed')
      and exists (select 1 from public.calendar_events c where c.uid = 'cascade-direct-c0de7644-0000-4000-8000-000000000001' and c.status = 'confirmed'
                    and c.linked_reservation_id is not null and c.recon_status = 'matched')
      and (select t.status = 'confirmed' from public.transactions t where t.id = 'e4400000-0000-4000-8000-000000000701'),
  'receipt: booking, DIRECT: reservation, renamed calendar row and income row all confirmed together');
select ok(exists (select 1 from public.booking_decisions d join public.payment_finance_reviews r on r.id = d.finance_review_id
                   where d.idempotency_key = 'onetap:s76-onetap-key-b01-receipt' and d.outcome = 'confirmed'
                     and r.comparison_id = current_setting('s76.cmp01')::uuid and r.outcome = 'approved'
                     and r.reviewer_user_id = 'e4400000-0000-4000-8000-0000000000a1'),
  'receipt: one approved review by F, linked to the confirmed decision');
select ok(case when current_setting('s76.stub') = 'on' then
            (select count(*) = 1 from net.s76_calls where url like '%/functions/v1/guest-messages' and body = '{"booking_id": "c0de7644-0000-4000-8000-000000000001", "tapped": true}'::jsonb
                and headers ->> 'x-cascade-cron-secret' = 'S76-SYNTHETIC-ONLY')
          else true end,
  'receipt: guest-messages is queued once with {booking_id, tapped: true} and the Vault secret header');
select is(current_setting('s76.r0' || n)::jsonb ->> 'outcome', 'confirmed', 'paid outside: ' || m || ' confirms')
  from (values (2, 'messenger_gcash'), (3, 'gcash_qr'), (4, 'bank'), (5, 'cash'), (6, 'other')) v(n, m) order by n;
select is((select count(*)::int from public.booking_inquiries b
            where b.id in ('c0de7644-0000-4000-8000-000000000002', 'c0de7644-0000-4000-8000-000000000003', 'c0de7644-0000-4000-8000-000000000004',
                           'c0de7644-0000-4000-8000-000000000005', 'c0de7644-0000-4000-8000-000000000006')
              and b.status = 'confirmed'
              and (select count(*) from public.payment_evidence_candidates e where e.booking_id = b.id and e.source_type = 'manual_evidence'
                     and e.normalized_amount = 1000 and 'paid_outside' = any(e.advisory_labels)) = 1
              and (select count(*) from public.payment_finance_reviews r where r.booking_id = b.id and r.outcome = 'approved'
                     and r.reviewer_user_id = 'e4400000-0000-4000-8000-0000000000a1') = 1
              and (select count(*) from public.booking_decisions d where d.booking_id = b.id and d.outcome = 'confirmed' and d.finance_review_id is not null) = 1),
  5, 'paid outside: each method left one manual_evidence candidate, one approved review by F and one reviewed decision');
select ok((select e.normalized_reference is null and 'cash' = any(e.advisory_labels) from public.payment_evidence_candidates e
            where e.booking_id = 'c0de7644-0000-4000-8000-000000000005'), 'paid outside: cash carries no reference and the cash label');

-- validation (b07), retry, reference reuse (b08), roles
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select is(public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000007', 'messenger_gcash', '1007234567890', null, null, null, 's76-onetap-key-b07-a') ->> 'outcome',
  'amount_required', 'validation: no amount -> amount_required');
select is(public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000007', 'messenger_gcash', null, 1000, null, null, 's76-onetap-key-b07-b') ->> 'outcome',
  'reference_required', 'validation: GCash without a reference -> reference_required');
select is(public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000007', 'bank', '12', 1000, null, null, 's76-onetap-key-b07-c') ->> 'outcome',
  'reference_required', 'validation: a two-character reference -> reference_required');
select is(public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000007', 'cash', null, 1000, ' ', null, 's76-onetap-key-b07-d') ->> 'outcome',
  'note_required', 'validation: cash without a note -> note_required');
select throws_ok($$select public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000007', 'paypal', 'X1234567', 1000, null, null, 's76-onetap-key-b07-e')$$,
  '22023', null, 'validation: an unknown method is refused');
select set_config('s76.r02b', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000002', 'messenger_gcash', '1001234567890', 1000, null, null, 's76-onetap-key-b02-outside')::text, true);
select set_config('s76.r01b', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000001', null, null, 1780, null, current_setting('s76.cmp01')::uuid, 's76-onetap-key-b01-receipt')::text, true);
select set_config('s76.r08', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000008', 'messenger_gcash', '1001-2345-67890', 1000, null, null, 's76-onetap-key-b08-reuse')::text, true);
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a2', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select is(public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000008', 'messenger_gcash', '1008234567890', 1000, null, null, 's76-onetap-key-b08-cleaner') ->> 'outcome',
  'denied', 'roles: a cleaner is denied');
select is(public.staff_decline_direct_booking_v1('c0de7644-0000-4000-8000-000000000008', 'not available', 's76-onetap-key-b08-cleaner-decline') ->> 'outcome',
  'denied', 'roles: a cleaner cannot decline either');
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a3', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select is(public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000008', 'messenger_gcash', '1008234567890', 1000, null, null, 's76-onetap-key-b08-inspector') ->> 'outcome',
  'denied', 'roles: an inspector is denied');
reset role;

select ok((select count(*) = 0 from public.payment_evidence_candidates where booking_id = 'c0de7644-0000-4000-8000-000000000007')
      and (select count(*) = 0 from public.booking_decisions where booking_id = 'c0de7644-0000-4000-8000-000000000007')
      and (select status = 'pending' from public.booking_inquiries where id = 'c0de7644-0000-4000-8000-000000000007'),
  'validation: the refusals wrote nothing');
select is(current_setting('s76.r02b')::jsonb - 'finance_review_id' - 'booking_id' - 'guest_name' - 'checkin' - 'checkout',
  '{"ok": true, "outcome": "confirmed", "booking_ref": "C0DE7644", "already_processed": true}'::jsonb, 'retry: the same key answers confirmed, already processed');
select ok((select count(*) = 1 from public.payment_evidence_candidates where booking_id = 'c0de7644-0000-4000-8000-000000000002')
      and (select count(*) = 1 from public.payment_finance_reviews where booking_id = 'c0de7644-0000-4000-8000-000000000002')
      and (select count(*) = 1 from public.booking_decisions where booking_id = 'c0de7644-0000-4000-8000-000000000002')
      and (select (current_setting('s76.r02b')::jsonb ->> 'finance_review_id')::uuid = r.id from public.payment_finance_reviews r
            where r.booking_id = 'c0de7644-0000-4000-8000-000000000002'),
  'retry: no second candidate, review or decision, and the same review is reported');
select is(current_setting('s76.r01b')::jsonb ->> 'already_processed', 'true', 'retry: the receipt path is idempotent too');
select ok(case when current_setting('s76.stub') = 'on' then
            (select count(*) = 1 from net.s76_calls where body ->> 'booking_id' = 'c0de7644-0000-4000-8000-000000000001')
            and (select count(*) = 1 from net.s76_calls where body ->> 'booking_id' = 'c0de7644-0000-4000-8000-000000000002')
          else true end,
  'retry: a replay with the same key does not queue guest-messages a second time');
select is(current_setting('s76.r08')::jsonb - 'booking_id' - 'guest_name' - 'checkin' - 'checkout',
  '{"ok": false, "outcome": "reference_reused", "booking_ref": "C0DE7644", "prior_ref": "C0DE7644"}'::jsonb,
  'reference reuse: b02''s GCash reference (typed with dashes) on b08 is refused');
select ok((select count(*) = 0 from public.payment_evidence_candidates where booking_id = 'c0de7644-0000-4000-8000-000000000008')
      and (select count(*) = 0 from public.payment_finance_reviews where booking_id = 'c0de7644-0000-4000-8000-000000000008')
      and (select count(*) = 0 from public.booking_decisions where booking_id = 'c0de7644-0000-4000-8000-000000000008')
      and (select status = 'pending' from public.booking_inquiries where id = 'c0de7644-0000-4000-8000-000000000008'),
  'reference reuse and the denied roles wrote nothing on b08');

-- conflicts never confirm
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select set_config('s76.r09', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000009', 'bank', 'BDO77712345', 1000, null, null, 's76-onetap-key-b09-conflict')::text, true);
select set_config('s76.r16', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000016', 'messenger_gcash', '1016234567890', 2500, null, null, 's76-onetap-key-b16-hold')::text, true);
reset role;
select is(current_setting('s76.r09')::jsonb ->> 'outcome', 'conflict', 'conflict: a calendar overlap answers conflict');
select ok((select status = 'pending' from public.booking_inquiries where id = 'c0de7644-0000-4000-8000-000000000009')
      and not exists (select 1 from public.airbnb_reservations where confirmation_code = 'DIRECT:c0de7644-0000-4000-8000-000000000009')
      and (select outcome = 'conflict' from public.booking_decisions where idempotency_key = 'onetap:s76-onetap-key-b09-conflict')
      and (select status = 'pending_review' from public.transactions where id = 'e4400000-0000-4000-8000-000000000709'),
  'conflict: b09 stays pending with no reservation and an untouched income row');
select is(current_setting('s76.r16')::jsonb ->> 'outcome' || '/' || (current_setting('s76.r16')::jsonb ->> 'reason'), 'conflict/active_hold',
  'conflict: another request''s active hold answers conflict (active_hold)');
select ok((select status = 'pending' from public.booking_inquiries where id = 'c0de7644-0000-4000-8000-000000000016')
      and not exists (select 1 from public.booking_decisions where booking_id = 'c0de7644-0000-4000-8000-000000000016')
      and not exists (select 1 from public.payment_finance_reviews where booking_id = 'c0de7644-0000-4000-8000-000000000016'),
  'conflict: nothing of the b16 decision persisted, not even its review');

-- receipt conflicts, then the same receipt confirms with a new key
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select set_config('s76.r21a', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000021', null, null, 1000, null,
  current_setting('s76.cmp21')::uuid, 's76-onetap-key-b21-hold-a')::text, true);
select set_config('s76.r23a', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000023', null, null, 1000, null,
  current_setting('s76.cmp23')::uuid, 's76-onetap-key-b23-cal-a')::text, true);
reset role;
select is(current_setting('s76.r21a')::jsonb ->> 'outcome' || '/' || (current_setting('s76.r21a')::jsonb ->> 'reason'), 'conflict/active_hold',
  'receipt + hold: b21 overlaps b22''s active hold -> conflict (active_hold)');
select ok(not exists (select 1 from public.payment_finance_reviews where booking_id = 'c0de7644-0000-4000-8000-000000000021')
      and not exists (select 1 from public.booking_decisions where booking_id = 'c0de7644-0000-4000-8000-000000000021'),
  'receipt + hold: no orphan review and no decision are left');
select is(current_setting('s76.r23a')::jsonb ->> 'outcome', 'conflict', 'receipt + calendar: b23 overlaps an Airbnb stay -> conflict');
update public.booking_holds set status = 'released', updated_at = now() where booking_id = 'c0de7644-0000-4000-8000-000000000022' and status = 'active';
update public.calendar_events set status = 'cancelled' where uid = 'synthetic-s76-23@airbnb.com';
set local role authenticated;
select set_config('s76.r21b', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000021', null, null, 1000, null,
  current_setting('s76.cmp21')::uuid, 's76-onetap-key-b21-hold-b')::text, true);
select set_config('s76.r23b', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000023', null, null, 1000, null,
  current_setting('s76.cmp23')::uuid, 's76-onetap-key-b23-cal-b')::text, true);
reset role;
select is(current_setting('s76.r21b')::jsonb ->> 'outcome' || '/' || (current_setting('s76.r21b')::jsonb ->> 'comparison_id') || '/' || (current_setting('s76.r21b')::jsonb ->> 'reattested'),
  'confirmed/' || current_setting('s76.cmp21') || '/false', 'receipt + hold: once the hold is released the SAME comparison confirms with a new key');
select is((select count(*)::int from public.payment_finance_reviews where booking_id = 'c0de7644-0000-4000-8000-000000000021' and outcome = 'approved'), 1,
  'receipt + hold: exactly one approved review, on the receipt comparison');
select is(current_setting('s76.r23b')::jsonb ->> 'outcome' || '/' || (current_setting('s76.r23b')::jsonb ->> 'reattested'), 'confirmed/true',
  'receipt + calendar: once the stay is gone the same receipt confirms with a new key (re-attested)');
select ok((select count(*) = 2 and count(distinct comparison_id) = 2 and bool_and(reviewer_user_id = 'e4400000-0000-4000-8000-0000000000a1')
             from public.payment_finance_reviews where booking_id = 'c0de7644-0000-4000-8000-000000000023' and outcome = 'approved')
      and (select count(*) = 2 and count(distinct finance_review_id) = 2 and bool_and(finance_review_id is not null)
             and bool_or(outcome = 'conflict') and bool_or(outcome = 'confirmed')
             from public.booking_decisions where booking_id = 'c0de7644-0000-4000-8000-000000000023')
      and (select current_setting('s76.cmp23')::uuid <> c.id
                  and (select evidence_candidate_ids from public.payment_evidence_comparisons where id = current_setting('s76.cmp23')::uuid) <@ c.evidence_candidate_ids
             from public.payment_evidence_comparisons c where c.id = (current_setting('s76.r23b')::jsonb ->> 'comparison_id')::uuid),
  'receipt + calendar: a fresh review on a new comparison over the receipt; one decision per review, the conflict row kept');

-- eight conflicted retries, each passing the comparison id the previous one returned (what a refreshed Inquiries card holds)
set local role authenticated;
do $$
declare v_cmp uuid := current_setting('s76.cmp25')::uuid; r jsonb; n int := 0;
begin
  for i in 1..8 loop
    r := public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000025', null, null, 1000, null, v_cmp, 's76-onetap-key-b25-conflict-' || i);
    if r ->> 'outcome' = 'conflict' then n := n + 1; end if;
    v_cmp := (r ->> 'comparison_id')::uuid;
  end loop;
  perform set_config('s76.c25n', n::text, true);
  perform set_config('s76.c25last', v_cmp::text, true);
end $$;
reset role;
select is(current_setting('s76.c25n'), '8', 'repeated conflicts: eight retries against the Airbnb stay all answer conflict');
select ok((select count(*) = 8 and bool_and(c.evidence_candidate_ids @> array[x.receipt]) and max(cardinality(c.evidence_candidate_ids)) <= 2
             from public.payment_evidence_comparisons c,
                  (select e.id as receipt from public.payment_evidence_candidates e
                    where e.booking_id = 'c0de7644-0000-4000-8000-000000000025' and e.source_type = 'receipt_ocr') x
            where c.booking_id = 'c0de7644-0000-4000-8000-000000000025'),
  'repeated conflicts: every comparison holds the receipt plus at most one attestation (no chain)');
select ok((select count(*) = 8 and count(distinct r.comparison_id) = 8 and bool_and(d.outcome = 'conflict')
             from public.payment_finance_reviews r join public.booking_decisions d on d.finance_review_id = r.id
            where r.booking_id = 'c0de7644-0000-4000-8000-000000000025' and r.outcome = 'approved'),
  'repeated conflicts: eight reviews on eight comparisons, each spent on one conflict decision');
update public.calendar_events set status = 'cancelled' where uid = 'synthetic-s76-25@airbnb.com';
set local role authenticated;
select set_config('s76.r25', public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000025', null, null, 1000, null,
  current_setting('s76.c25last')::uuid, 's76-onetap-key-b25-final')::text, true);
reset role;
select ok(current_setting('s76.r25')::jsonb ->> 'outcome' = 'confirmed'
      and (select c.evidence_candidate_ids @> array[(select e.id from public.payment_evidence_candidates e
                                                      where e.booking_id = 'c0de7644-0000-4000-8000-000000000025' and e.source_type = 'receipt_ocr')]
                  and cardinality(c.evidence_candidate_ids) = 2
             from public.payment_evidence_comparisons c where c.id = (current_setting('s76.r25')::jsonb ->> 'comparison_id')::uuid),
  'repeated conflicts: once the stay is gone the ninth try confirms on receipt + one attestation');

-- Telegram
set local role service_role;
select is(public.telegram_confirm_direct_booking_v1(944000099, 'c0de7644-0000-4000-8000-000000000010', 'messenger_gcash', '1010234567890', 1000, null, null, 's76-onetap-key-b10-tg-unmapped'),
  '{"ok": false, "outcome": "not_linked"}'::jsonb, 'telegram: an unmapped Telegram id -> not_linked');
select is(public.telegram_confirm_direct_booking_v1(944000002, 'c0de7644-0000-4000-8000-000000000010', 'messenger_gcash', '1010234567890', 1000, null, null, 's76-onetap-key-b10-tg-cleaner') ->> 'outcome',
  'denied', 'telegram: a mapped cleaner is denied');
select set_config('s76.r10', public.telegram_confirm_direct_booking_v1(944000001, 'c0de7644-0000-4000-8000-000000000010', 'messenger_gcash', '1010234567890', 1000, null, null, 's76-onetap-key-b10-tg-finance')::text, true);
select set_config('s76.r19', public.telegram_confirm_direct_booking_v1(944000004, 'c0de7644-0000-4000-8000-000000000019', null, null, 1000, null,
  current_setting('s76.cmp19')::uuid, 's76-onetap-key-b19-tg-receipt')::text, true);
reset role;
select is(current_setting('s76.r19')::jsonb ->> 'outcome' || '/' || (current_setting('s76.r19')::jsonb ->> 'comparison_id') || '/' || (current_setting('s76.r19')::jsonb ->> 'reviewer_role'),
  'confirmed/' || current_setting('s76.cmp19') || '/admin', 'telegram: admin A''s receipt-card tap confirms b19 on the receipt comparison');
select ok(exists (select 1 from public.payment_finance_reviews r join public.booking_decisions d on d.finance_review_id = r.id
                   where r.comparison_id = current_setting('s76.cmp19')::uuid and r.outcome = 'approved'
                     and r.reviewer_user_id = 'e4400000-0000-4000-8000-0000000000a4' and d.outcome = 'confirmed'),
  'telegram: the receipt review names A and authorizes the confirmed decision');
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select is(public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000020', null, null, 1000, null,
  current_setting('s76.cmp20')::uuid, 's76-onetap-key-b20-rejected') ->> 'reason', 'already_rejected',
  'receipt: a comparison already rejected in Finance refuses (already_rejected)');
select is(public.staff_confirm_direct_booking_v1('c0de7644-0000-4000-8000-000000000001', null, null, null, null, null, 's76-onetap-key-b01-again') ->> 'reason',
  'not_pending', 'state first: a confirmed booking answers not_pending even with no amount and no method');
reset role;
select ok((select status = 'pending' from public.booking_inquiries where id = 'c0de7644-0000-4000-8000-000000000020')
      and not exists (select 1 from public.booking_decisions where booking_id = 'c0de7644-0000-4000-8000-000000000020'),
  'receipt: the rejected b20 stays pending with no decision');
select is(current_setting('s76.r10')::jsonb ->> 'outcome' || '/' || (current_setting('s76.r10')::jsonb ->> 'reviewer_user_id') || '/' || (current_setting('s76.r10')::jsonb ->> 'reviewer_role'),
  'confirmed/e4400000-0000-4000-8000-0000000000a1/finance', 'telegram: Finance F''s tap confirms b10 as F');

-- the bypass guard
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select throws_ok($$select public.admin_save_transaction_v1('e4400000-0000-4000-8000-000000000044',
    '{"id": "e4400000-0000-4000-8000-000000000711", "status": "confirmed", "reason": "synthetic bypass attempt"}'::jsonb, null)$$,
  '55000', 'Confirm the booking from Inquiries; it records the payment and the booking together.',
  'guard: admin_save_transaction_v1 confirming a pending booking''s income row raises confirm_from_inquiries');
select lives_ok($$select public.admin_soft_delete_v1('transactions', 'e4400000-0000-4000-8000-000000000712', 'synthetic guest cancelled')$$,
  'guard: a staff void of b12''s income row still goes through');
reset role;
select throws_ok($$update public.transactions set status = 'confirmed' where id = 'e4400000-0000-4000-8000-000000000711'$$,
  '55000', 'Confirm the booking from Inquiries; it records the payment and the booking together.',
  'guard: a direct table update (the Finance queue route) raises too');
select ok((select status = 'pending' from public.booking_inquiries where id = 'c0de7644-0000-4000-8000-000000000011')
      and (select status = 'pending_review' from public.transactions where id = 'e4400000-0000-4000-8000-000000000711'),
  'guard: b11 and its income row are untouched');
insert into public.transactions(id, property_id, txn_type, category, source, status, transaction_date, gross_amount, currency, booking_id, external_ref)
values ('e4400000-0000-4000-8000-000000000799', 'e4400000-0000-4000-8000-000000000044', 'income', 'direct_booking', 'direct_booking', 'pending_review',
        current_date + 500, 1780, 'PHP', 'c0de7644-0000-4000-8000-000000000001', 'balance:c0de7644-0000-4000-8000-000000000001');
select lives_ok($$update public.transactions set status = 'confirmed' where id = 'e4400000-0000-4000-8000-000000000799'$$,
  'guard: a second income row for an already-confirmed booking may confirm');
select is((select status from public.transactions where id = 'e4400000-0000-4000-8000-000000000799'), 'confirmed', 'guard: the balance row is confirmed');
select is((select b.status || '/' || c.status from public.booking_inquiries b join public.calendar_events c on c.uid = 'direct:' || b.id::text
            where b.id = 'c0de7644-0000-4000-8000-000000000012'), 'cancelled/cancelled', 'void: b12 and its calendar block are cancelled');
select lives_ok($$select public.expire_booking_holds_v1()$$, 'expiry: expire_booking_holds_v1 runs');
select is((select b.status || '/' || t.status || '/' || h.status from public.booking_inquiries b
             join public.transactions t on t.id = 'e4400000-0000-4000-8000-000000000713'
             join public.booking_holds h on h.booking_id = b.id
            where b.id = 'c0de7644-0000-4000-8000-000000000013'), 'expired/void/expired', 'expiry: the lapsed b13 expires as before');
select ok((select status = 'pending' from public.booking_inquiries where id = 'c0de7644-0000-4000-8000-000000000015')
      and exists (select 1 from public.booking_holds where booking_id = 'c0de7644-0000-4000-8000-000000000015' and status = 'active'),
  'expiry: b15''s live hold is left alone');
select is(public.supersede_pending_direct_requests_v1('e4400000-0000-4000-8000-000000000044', 'b24@example.com', '09170000024', current_date + 630, current_date + 632),
  '{"superseded": ["c0de7644-0000-4000-8000-000000000024"], "reason": "released"}'::jsonb, 'supersede: the guest''s earlier request is released');
select is((select b.status || '/' || t.status || '/' || c.status from public.booking_inquiries b
             join public.transactions t on t.id = 'e4400000-0000-4000-8000-000000000724'
             join public.calendar_events c on c.uid = 'direct:' || b.id::text
            where b.id = 'c0de7644-0000-4000-8000-000000000024'), 'cancelled/void/cancelled', 'supersede: request, income row and calendar block cancelled as before');
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select is(public.admin_transactions_bulk_v1('e4400000-0000-4000-8000-000000000044', array['e4400000-0000-4000-8000-000000000711']::uuid[], 'hide') ->> 'changed',
  '1', 'bulk: hiding a pending booking''s income row still works');
select throws_ok($$select public.admin_transactions_bulk_v1('e4400000-0000-4000-8000-000000000044', array['e4400000-0000-4000-8000-000000000711']::uuid[], 'archive', 'synthetic archive')$$,
  '22023', 'a direct booking payment cannot be archived while the booking is live; cancel the booking instead', 'bulk: archiving a live booking''s row is refused as before');
select is(public.admin_transactions_bulk_v1('e4400000-0000-4000-8000-000000000044', array['e4400000-0000-4000-8000-000000000712']::uuid[], 'archive', 'synthetic archive') ->> 'changed',
  '1', 'bulk: archiving the voided b12 row works');
select is(public.admin_transactions_bulk_v1('e4400000-0000-4000-8000-000000000044', array['e4400000-0000-4000-8000-000000000712']::uuid[], 'restore', 'synthetic restore') ->> 'changed',
  '1', 'bulk: restoring it works');
reset role;
select is((select status || '/' || coalesce(archived_at::text, 'live') from public.transactions where id = 'e4400000-0000-4000-8000-000000000712'), 'void/live',
  'bulk: the restored row is back to void');

-- decline
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select is(public.staff_decline_direct_booking_v1('c0de7644-0000-4000-8000-000000000008', ' ', 's76-onetap-key-b08-decline-blank') ->> 'outcome',
  'note_required', 'decline: a blank reason -> note_required');
select set_config('s76.d17', public.staff_decline_direct_booking_v1('c0de7644-0000-4000-8000-000000000017', 'Dates are taken', 's76-onetap-key-b17-decline')::text, true);
select set_config('s76.d17b', public.staff_decline_direct_booking_v1('c0de7644-0000-4000-8000-000000000017', 'Dates are taken', 's76-onetap-key-b17-decline')::text, true);
select set_config('s76.d18', public.staff_decline_direct_booking_v1('c0de7644-0000-4000-8000-000000000018', 'Receipt is not ours', 's76-onetap-key-b18-decline')::text, true);
reset role;
select is(current_setting('s76.d17')::jsonb ->> 'outcome', 'declined', 'decline: b17 without a receipt is declined');
select ok((select status = 'cancelled' from public.booking_inquiries where id = 'c0de7644-0000-4000-8000-000000000017')
      and (select finance_review_id is null and outcome = 'declined' from public.booking_decisions where idempotency_key = 'onetap-decline:s76-onetap-key-b17-decline')
      and exists (select 1 from public.booking_lifecycle_events where idempotency_key = 'onetap-decline-audit:s76-onetap-key-b17-decline'
                    and event_type = 'cancelled' and actor_user_id = 'e4400000-0000-4000-8000-0000000000a1'),
  'decline: no-review engine, one decision, one audit row naming F');
select is(current_setting('s76.d17b')::jsonb ->> 'already_processed', 'true', 'decline: a retry with the same key changes nothing');
select is(current_setting('s76.d18')::jsonb ->> 'outcome', 'declined', 'decline: b18 with a receipt is declined');
select ok(exists (select 1 from public.booking_decisions d join public.payment_finance_reviews r on r.id = d.finance_review_id
                   where d.idempotency_key = 'onetap-decline:s76-onetap-key-b18-decline' and r.outcome = 'rejected'
                     and r.comparison_id = current_setting('s76.cmp18')::uuid and r.reviewer_user_id = 'e4400000-0000-4000-8000-0000000000a1'),
  'decline: b18 carries a rejected review by F linked to the decision');

-- repair (the migration already ran it once against whatever the restore held)
select is(public._repair_bypass_confirmed_v1(), 1, 'repair: the bypass-confirmed b14 is repaired');
select ok(exists (select 1 from public.airbnb_reservations r where r.confirmation_code = 'DIRECT:c0de7644-0000-4000-8000-000000000014' and r.status = 'confirmed' and r.guest_paid = 2000)
      and exists (select 1 from public.calendar_events c join public.airbnb_reservations r on r.id = c.linked_reservation_id
                   where c.uid = 'cascade-direct-c0de7644-0000-4000-8000-000000000014' and c.recon_status = 'matched' and c.status = 'confirmed'
                     and r.confirmation_code = 'DIRECT:c0de7644-0000-4000-8000-000000000014')
      and not exists (select 1 from public.calendar_events where uid = 'direct:c0de7644-0000-4000-8000-000000000014'),
  'repair: DIRECT: reservation, calendar row renamed and linked');
select ok((select count(*) = 1 from public.booking_decisions where booking_id = 'c0de7644-0000-4000-8000-000000000014'
             and idempotency_key = 'repair:bypass:c0de7644-0000-4000-8000-000000000014' and outcome = 'confirmed' and finance_review_id is null)
      and (select count(*) = 0 from public.payment_finance_reviews where booking_id = 'c0de7644-0000-4000-8000-000000000014')
      and (select count(*) = 1 from public.transactions where booking_id = 'c0de7644-0000-4000-8000-000000000014' and status = 'confirmed'),
  'repair: one repair decision, no review invented, the ledger untouched');
select is(public._repair_bypass_confirmed_v1(), 0, 'repair: a second run repairs nothing');
select ok(not exists (select 1 from public.booking_inquiries x where x.source = 'direct' and x.status = 'confirmed'
                       and (not exists (select 1 from public.airbnb_reservations r where r.confirmation_code = 'DIRECT:' || x.id::text)
                            or not exists (select 1 from public.booking_decisions d where d.booking_id = x.id and d.outcome = 'confirmed'))),
  'repair: no confirmed direct booking anywhere lacks its DIRECT: row or confirmed decision');

-- Cassy hand-back
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a2', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select is(public.concierge_resume_cassy_v1('synthetic-psid-s76-0001'), '{"ok": false, "outcome": "denied"}'::jsonb, 'resume: a cleaner is denied');
reset role;
select ok((select human_until is not null from public.concierge_threads where psid = 'synthetic-psid-s76-0001'), 'resume: the denied call left the pause in place');
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a4', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select is(public.concierge_resume_cassy_v1('synthetic-psid-s76-0001') - 'was_paused_until',
  jsonb_build_object('ok', true, 'outcome', 'resumed', 'already', false, 'psid_short', left(md5('synthetic-psid-s76-0001'), 8)), 'resume: admin A lets Cassy answer again');
select is(public.concierge_resume_cassy_v1('synthetic-psid-s76-0001') ->> 'already', 'true', 'resume: a second tap reports already');
reset role;
select ok((select human_until is null from public.concierge_threads where psid = 'synthetic-psid-s76-0001')
      and (select count(*) = 1 from public.admin_audit_log where entity_table = 'concierge_threads' and entity_id = md5('synthetic-psid-s76-0001')::uuid
             and actor_user_id = 'e4400000-0000-4000-8000-0000000000a4' and after_state ->> 'human_until' is null),
  'resume: human_until cleared, one audit row by A');

-- the Inquiries payment rows
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select ok(exists (select 1 from public.staff_inquiry_payments_v1('e4400000-0000-4000-8000-000000000044') r
                   where r.id = 'c0de7644-0000-4000-8000-000000000015' and r.booking_ref = 'C0DE7644' and r.expected_amount = 1500
                     and r.comparison_id = current_setting('s76.cmp15')::uuid and r.candidate_amount = 1500 and r.reference = 'R15ABCDEF'
                     and r.receipt_image_path = 'receipts/s76-b15.jpg' and r.hold_expires_at > now() and r.pax = 2),
  'payments: b15 shows its receipt (amount, reference, comparison), the deposit as expected and the live hold');
select ok(exists (select 1 from public.staff_inquiry_payments_v1('e4400000-0000-4000-8000-000000000044') r
                   where r.id = 'c0de7644-0000-4000-8000-000000000016' and r.expected_amount = 2500 and r.comparison_id is null),
  'payments: deposit 0 -> expected is the total; a paid-outside attempt is not a receipt');
select ok(exists (select 1 from public.staff_inquiry_payments_v1('e4400000-0000-4000-8000-000000000044') r
                   where r.id = 'c0de7644-0000-4000-8000-000000000009' and r.comparison_id is null and r.candidate_amount is null),
  'payments: b09''s conflicted paid-outside candidate does not show as a receipt');
select is((select count(*)::int from public.staff_inquiry_payments_v1('e4400000-0000-4000-8000-000000000044')), 8,
  'payments: only the eight pending requests (b07, b08, b09, b11, b15, b16, b20, b22) are listed');
select set_config('request.jwt.claims', json_build_object('sub', 'e4400000-0000-4000-8000-0000000000a2', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select throws_ok($$select * from public.staff_inquiry_payments_v1('e4400000-0000-4000-8000-000000000044')$$, '42501', null, 'payments: a cleaner is refused');
reset role;

select * from finish();
rollback;
