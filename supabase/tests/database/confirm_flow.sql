-- Release cf_confirm_flow_20261205 (D-418): the Inquiries list flags (receipt_sent, receipt_at, contact_channel, order), the decline reason code and its
-- guest-messages post, the 'declined' log key, needs_reply / waiting_since, concierge_waiting_v1 and Home's inbox_open.
-- Synthetic fixtures only (public repo), on a property private to this suite (e5500000-...); rows are inserted as the table owner, the RPCs are called as
-- authenticated, and everything goes with the closing rollback.
--   F finance (a1) may decide and read payments   O owner (a2) and A admin (a3) read conversations   C cleaner (a4) is refused everywhere
--   Bookings (pending, direct), dates = today + 700 + 10 n:
--     p1 receipt image + guest-sent comparison (amount 1000)     p2 receipt image only (never read)     p3 no receipt, hold ends in 2 h
--     p4 no receipt, hold already ended                           p5 no receipt, no hold                  p6 only a paid-outside (manual) comparison
--     c1..c5 contact channel fixtures                             d1..d8 decline fixtures
-- pg_net and Vault are absent from a rehearsal copy: they are stubbed here (and rolled back) so the guest-messages post is observable.
-- Where the real pg_net exists (CI) the stub is not installed and the assertions that read the stub pass vacuously.
begin;
select plan(77);

do $$
begin
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null and to_regclass('vault.decrypted_secrets') is null then
    create schema if not exists net;
    create table net.cf_calls(url text, headers jsonb, body jsonb);
    create function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
                                  headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
      returns bigint language plpgsql as $f$
      begin
        if current_setting('cf.fail', true) = 'on' then raise exception 'synthetic pg_net failure'; end if;
        insert into net.cf_calls values (url, headers, body);
        return 1;
      end $f$;
    create schema if not exists vault;
    create table vault.decrypted_secrets(name text, decrypted_secret text);
    insert into vault.decrypted_secrets values ('cascade_cron_shared_secret', 'CF-SYNTHETIC-ONLY');
    perform set_config('cf.stub', 'on', true);
  else
    perform set_config('cf.stub', 'off', true);
  end if;
end $$;

-- shape and grants -------------------------------------------------------------------------------------------------------------------------
select has_function('public', 'staff_decline_direct_booking_v1', array['uuid', 'text', 'text', 'text'], 'the four-argument decline exists');
select has_function('public', 'staff_decline_direct_booking_v1', array['uuid', 'text', 'text'], 'the three-argument decline wrapper is kept (Staff 3.4.53)');
select has_function('public', 'concierge_waiting_v1', array[]::text[], 'concierge_waiting_v1() exists with no arguments');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'staff_decline_direct_booking_v1'), 2,
  'exactly two decline overloads (no default on the fourth argument, so the three-argument call is never ambiguous)');
select ok((select count(*) = 5 and bool_and(p.prosecdef and p.proconfig = array['search_path=""'])
             from pg_proc p where p.oid in ('public.staff_inquiry_payments_v1(uuid)'::regprocedure, 'public.staff_decline_direct_booking_v1(uuid,text,text,text)'::regprocedure,
               'public.concierge_conversations_v1(int)'::regprocedure, 'public.concierge_waiting_v1()'::regprocedure,
               'public.notices_v1(uuid)'::regprocedure)),
  'the five changed client functions are security definer with an empty search_path');
select ok(has_function_privilege('authenticated', 'public.staff_inquiry_payments_v1(uuid)', 'execute')
      and has_function_privilege('authenticated', 'public.staff_decline_direct_booking_v1(uuid,text,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.staff_decline_direct_booking_v1(uuid,text,text)', 'execute')
      and has_function_privilege('authenticated', 'public.concierge_conversations_v1(int)', 'execute')
      and has_function_privilege('authenticated', 'public.concierge_waiting_v1()', 'execute')
      and has_function_privilege('authenticated', 'public.notices_v1(uuid)', 'execute'),
  'signed-in staff may call the client functions');
select ok(not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                       where p.oid in ('public.staff_inquiry_payments_v1(uuid)'::regprocedure, 'public.staff_decline_direct_booking_v1(uuid,text,text,text)'::regprocedure,
                                       'public.staff_decline_direct_booking_v1(uuid,text,text)'::regprocedure, 'public.concierge_conversations_v1(int)'::regprocedure,
                                       'public.concierge_waiting_v1()'::regprocedure)
                         and (a.grantee = 0 or a.grantee in (select oid from pg_roles where rolname in ('anon', 'service_role')))),
  'neither PUBLIC, anon nor service_role may execute the five changed or new client functions');
select ok(not has_function_privilege('anon', 'public.notices_v1(uuid)', 'execute') and has_function_privilege('service_role', 'public.notices_v1(uuid)', 'execute'),
  'notices_v1 keeps its grants: not anon, service_role still yes');
select ok((select bool_and(not has_function_privilege('anon', f, 'execute') and not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('service_role', f, 'execute'))
             from unnest(array['public.s_cf_ts_v1(text)', 'public.s_cf_receipt_sent_v1(uuid)', 'public.s_cf_contact_channel_v1(uuid)', 'public.s_cf_waiting_v1()']) f),
  'the four internal helpers have no client grants');
select is((select proargnames::text[] from pg_proc where oid = 'public.staff_inquiry_payments_v1(uuid)'::regprocedure),
  array['p_property_id', 'id', 'booking_ref', 'guest_name', 'checkin_date', 'checkout_date', 'pax', 'expected_amount', 'comparison_id', 'candidate_amount', 'reference',
        'receipt_image_path', 'hold_expires_at', 'receipt_sent', 'receipt_at', 'contact_channel'],
  'staff_inquiry_payments_v1: the 12 old columns first and in order, then receipt_sent, receipt_at, contact_channel');
select is((select proargnames::text[] from pg_proc where oid = 'public.concierge_conversations_v1(int)'::regprocedure),
  array['p_limit', 'psid', 'psid_short', 'guest_name', 'updated_at', 'last_role', 'last_text', 'last_guest_at', 'open_handoffs', 'human_until', 'last_risk', 'needs_reply', 'waiting_since'],
  'concierge_conversations_v1: the 10 old columns first and in order, then needs_reply, waiting_since');

-- the log key --------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e5500000-0000-4000-8000-000000000055', 'Synthetic Confirm Flow', true);
insert into auth.users(id) values
  ('e5500000-0000-4000-8000-0000000000a1'), ('e5500000-0000-4000-8000-0000000000a2'), ('e5500000-0000-4000-8000-0000000000a3'), ('e5500000-0000-4000-8000-0000000000a4');
insert into public.staff_access_profiles(user_id, role, telegram_user_id, disabled_at, note) values
  ('e5500000-0000-4000-8000-0000000000a1', 'finance', 955000001, null, 'Finance F'),
  ('e5500000-0000-4000-8000-0000000000a2', 'owner',   955000002, null, 'Owner O'),
  ('e5500000-0000-4000-8000-0000000000a3', 'admin',   955000003, null, 'Admin A'),
  ('e5500000-0000-4000-8000-0000000000a4', 'cleaner', 955000004, null, 'Cleaner C');
insert into public.staff_property_access(user_id, property_id)
select u, 'e5500000-0000-4000-8000-000000000055'::uuid from unnest(array['e5500000-0000-4000-8000-0000000000a1', 'e5500000-0000-4000-8000-0000000000a2',
  'e5500000-0000-4000-8000-0000000000a3', 'e5500000-0000-4000-8000-0000000000a4']::uuid[]) u;

-- p1-p6 inquiries, c1-c5 contact fixtures, d1-d8 decline fixtures (ids ...c000 + n)
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, status, source, receipt_image_path, total_amount, deposit_amount, submitted_at)
select ('c0de5500-0000-4000-8000-00000000' || lpad(n::text, 4, '0'))::uuid, 'e5500000-0000-4000-8000-000000000055', 'Synthetic ' || n, em, '0917550' || lpad(n::text, 4, '0'),
       current_date + 700 + 10 * n, current_date + 702 + 10 * n, 2, 'pending', 'direct', rc, 2000, dep, now() - make_interval(mins => 100 - n)
  from (values (1, null, 'receipts/cf-p1.jpg', 1000), (2, null, 'receipts/cf-p2.jpg', 1000), (3, null, null, 1000), (4, null, null, 1000), (5, null, null, 1000), (6, null, null, 1000),
               (11, null, null, 1000), (12, 'c2@example.com', null, 1000), (13, 'c3@example.com', null, 1000), (14, null, null, 1000), (15, null, null, 1000),
               (21, null, 'receipts/cf-d1.jpg', 1000), (22, null, null, 1000), (23, null, null, 1000), (24, null, null, 1000), (25, null, null, 1000), (26, null, null, 1000),
               (27, null, null, 1000), (28, null, null, 1000)) v(n, em, rc, dep);
insert into public.booking_holds(property_id, booking_id, checkin_date, checkout_date, expires_at, status, idempotency_key)
select 'e5500000-0000-4000-8000-000000000055', b, current_date + 700 + 10 * n, current_date + 702 + 10 * n, exp, 'active', 'hold:' || b::text
  from (values (3, now() + interval '2 hours'), (4, now() - interval '1 hour'), (1, now() + interval '1 day')) v(n, exp),
       lateral (select ('c0de5500-0000-4000-8000-00000000' || lpad(n::text, 4, '0'))::uuid as b) x;
-- guest-sent evidence for p1 (read: amount 1000) and d1; a paid-outside (manual) comparison alone for p6
select set_config('cf.cmp' || n, public.compare_booking_payment_evidence(b, array[public.record_payment_evidence_candidate(
         b, 'receipt_ocr', 'receipt:cf-' || n || '-0000', encode(extensions.digest('cf-receipt-' || n, 'sha256'), 'hex'), 'cf-receipt-candidate-' || n,
         'ocr-v1', now(), 1000, 'PHP', 'R' || n || 'ABCDEF')])::text, true)
  from (values (1, 'c0de5500-0000-4000-8000-000000000001'::uuid), (21, 'c0de5500-0000-4000-8000-000000000021'::uuid)) v(n, b);
select set_config('cf.cmp6', public.compare_booking_payment_evidence('c0de5500-0000-4000-8000-000000000006', array[public.record_payment_evidence_candidate(
         'c0de5500-0000-4000-8000-000000000006', 'manual_evidence', 'manual:' || md5('cf-manual-6')::uuid::text, encode(extensions.digest('cf-manual-6', 'sha256'), 'hex'),
         'cf-manual-candidate-6', 'onetap-v1', now(), 1000, 'PHP', 'CASH6', null, array['paid_outside', 'cash'], 'not_applicable', null)])::text, true);
-- chat threads for the contact fixtures (window = 167 h, one hour of it must be left)
insert into public.concierge_threads(psid, guest_name, booking_flow, history, updated_at) values
  ('zz-cf-c1', 'Zz C1', jsonb_build_object('booking_id', 'c0de5500-0000-4000-8000-000000000011'),
     jsonb_build_array(jsonb_build_object('role', 'guest', 'text', 'hi', 'at', to_char((now() - interval '165 hours') at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))), now()),
  ('zz-cf-c2', 'Zz C2', jsonb_build_object('booking_id', 'c0de5500-0000-4000-8000-000000000012'),
     jsonb_build_array(jsonb_build_object('role', 'guest', 'text', 'hi', 'at', to_char((now() - interval '166 hours 30 minutes') at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))), now()),
  ('zz-cf-c5', 'Zz C5', jsonb_build_object('booking_id', 'c0de5500-0000-4000-8000-000000000015'),
     '[{"role":"guest","text":"odd","at":"not-a-date"},{"role":"guest","text":"worse","at":"2026-13-45T99:99:99Z"}]'::jsonb, now());

-- the helpers, directly (table owner) ----------------------------------------------------------------------------------------------------
select is(public.s_cf_ts_v1('not-a-date'), null, 's_cf_ts_v1: not a date is null');
select is(public.s_cf_ts_v1('2026-13-45T99:99:99Z'), null, 's_cf_ts_v1: a date-shaped but impossible value is null, not an error');
select is(public.s_cf_ts_v1('2026-10-02T03:04:05Z'), '2026-10-02T03:04:05Z'::timestamptz, 's_cf_ts_v1: an ISO timestamp is read');
select is(public.s_cf_receipt_sent_v1('c0de5500-0000-4000-8000-000000000001'), true, 'receipt_sent: an image and a guest-sent comparison');
select is(public.s_cf_receipt_sent_v1('c0de5500-0000-4000-8000-000000000002'), true, 'receipt_sent: an image that was never read still counts');
select is(public.s_cf_receipt_sent_v1('c0de5500-0000-4000-8000-000000000005'), false, 'receipt_sent: nothing sent is false');
select is(public.s_cf_receipt_sent_v1('c0de5500-0000-4000-8000-000000000006'), false, 'receipt_sent: a paid-outside (manual) comparison is not a guest receipt');
select is(public.s_cf_receipt_sent_v1('c0de5500-0000-4000-8000-0000000000ff'), false, 'receipt_sent: an unknown booking is false, not null');
select is(public.s_cf_contact_channel_v1('c0de5500-0000-4000-8000-000000000011'), 'messenger', 'contact: 2 h of the window left is Messenger');
select is(public.s_cf_contact_channel_v1('c0de5500-0000-4000-8000-000000000012'), 'email', 'contact: 30 min left and an e-mail on file is e-mail');
select is(public.s_cf_contact_channel_v1('c0de5500-0000-4000-8000-000000000013'), 'email', 'contact: no chat, an e-mail on file is e-mail');
select is(public.s_cf_contact_channel_v1('c0de5500-0000-4000-8000-000000000014'), 'none', 'contact: no chat and no e-mail is none');
select is(public.s_cf_contact_channel_v1('c0de5500-0000-4000-8000-000000000015'), 'none', 'contact: a chat whose timestamps are unusable and no e-mail is none, and raises nothing');

-- the Inquiries list, as F ------------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', 'e5500000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select is((select receipt_sent from public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055') where id = 'c0de5500-0000-4000-8000-000000000001'), true,
  'payments: p1 (image and comparison) is receipt_sent');
select ok((select r.receipt_sent and r.receipt_image_path = 'receipts/cf-p2.jpg' and r.receipt_at is null and r.comparison_id is null
             from public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055') r where r.id = 'c0de5500-0000-4000-8000-000000000002'),
  'payments: p2 (image never read) is receipt_sent with no receipt_at and no comparison');
select ok((select not r.receipt_sent and r.receipt_at is null and r.comparison_id is null and r.candidate_amount is null
             from public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055') r where r.id = 'c0de5500-0000-4000-8000-000000000006'),
  'payments: p6 (paid outside only) is not receipt_sent and shows no receipt amount');
select ok((select r.receipt_at is not null and r.receipt_at <= now() and r.candidate_amount = 1000 and r.reference = 'R1ABCDEF' and r.comparison_id = current_setting('cf.cmp1')::uuid
             from public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055') r where r.id = 'c0de5500-0000-4000-8000-000000000001'),
  'payments: p1 carries its receipt time, read amount, reference and comparison');
select is((select array_agg(r.id::text order by o.n) from public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055') with ordinality as o(id, booking_ref, guest_name, checkin_date, checkout_date, pax, expected_amount, comparison_id, candidate_amount, reference, receipt_image_path, hold_expires_at, receipt_sent, receipt_at, contact_channel, n)
            join public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055') r on r.id = o.id
            where r.id in ('c0de5500-0000-4000-8000-000000000001', 'c0de5500-0000-4000-8000-000000000002', 'c0de5500-0000-4000-8000-000000000003',
                           'c0de5500-0000-4000-8000-000000000004', 'c0de5500-0000-4000-8000-000000000005', 'c0de5500-0000-4000-8000-000000000006')),
  array['c0de5500-0000-4000-8000-000000000001', 'c0de5500-0000-4000-8000-000000000002', 'c0de5500-0000-4000-8000-000000000004',
        'c0de5500-0000-4000-8000-000000000003', 'c0de5500-0000-4000-8000-000000000005', 'c0de5500-0000-4000-8000-000000000006'],
  'payments order: receipt sent first (read receipt before the unread one), then the soonest hold end (ended p4, p3), then no hold by check-in (p5, p6)');
select is((select array_agg(r.contact_channel order by r.id) from public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055') r
            where r.id in ('c0de5500-0000-4000-8000-000000000011', 'c0de5500-0000-4000-8000-000000000012', 'c0de5500-0000-4000-8000-000000000013',
                           'c0de5500-0000-4000-8000-000000000014', 'c0de5500-0000-4000-8000-000000000015')),
  array['messenger', 'email', 'email', 'none', 'none'],
  'payments: contact_channel for the five fixtures (2 h left, 30 min left plus e-mail, e-mail only, neither, unusable chat)');
select ok(not exists (select 1 from public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055') r where r.contact_channel is null or r.receipt_sent is null),
  'payments: receipt_sent and contact_channel are never null');
select ok(not (to_jsonb((select r from public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055') r limit 1)) ?| array['guest_email', 'guest_phone', 'psid']),
  'payments: no contact (e-mail, phone, chat id) is in the row');
select set_config('request.jwt.claims', json_build_object('sub', 'e5500000-0000-4000-8000-0000000000a4', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select throws_ok($$select * from public.staff_inquiry_payments_v1('e5500000-0000-4000-8000-000000000055')$$, '42501', null, 'payments: a cleaner is refused');
reset role;

-- decline, as F -----------------------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', 'e5500000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select set_config('cf.r21', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000021', 'Payment did not arrive', 'cf-decline-key-d1-payment', 'payment')::text, true);
select set_config('cf.r21b', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000021', 'Payment did not arrive', 'cf-decline-key-d1-payment', 'payment')::text, true);
select set_config('cf.r22', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000022', 'Dates are taken', 'cf-decline-key-d2-dates', 'dates')::text, true);
select set_config('cf.r23', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000023', 'Same guest asked twice', 'cf-decline-key-d3-duplicate', 'duplicate')::text, true);
select set_config('cf.r24', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000024', 'Called to cancel', 'cf-decline-key-d4-wrapper')::text, true);
select set_config('cf.r25', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000025', 'Unknown code from an old app', 'cf-decline-key-d5-unknown', 'zzz')::text, true);
select set_config('cf.r26', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000026', 'Guest asked us to cancel', 'cf-decline-key-d6-cancel', 'guest_cancel')::text, true);
select set_config('cf.r27', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000027', 'A reason with no code at all', 'cf-decline-key-d7-null', null)::text, true);
select set_config('cf.fail', 'on', true);
select set_config('cf.r28', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000028', 'pg_net is down', 'cf-decline-key-d8-fail', 'dates')::text, true);
select set_config('cf.fail', 'off', true);
select set_config('cf.rnote', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000011', ' ', 'cf-decline-key-c1-blank', 'dates')::text, true);
select set_config('request.jwt.claims', json_build_object('sub', 'e5500000-0000-4000-8000-0000000000a4', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select set_config('cf.rdenied', public.staff_decline_direct_booking_v1('c0de5500-0000-4000-8000-000000000012', 'cleaner tries', 'cf-decline-key-c2-cleaner', 'dates')::text, true);
reset role;

select is(current_setting('cf.r21')::jsonb ->> 'outcome', 'declined', 'decline d1 (receipt sent, payment): declined');
select is(current_setting('cf.r21b')::jsonb ->> 'already_processed', 'true', 'decline d1 repeated with the same key: already processed');
select is((select status from public.booking_inquiries where id = 'c0de5500-0000-4000-8000-000000000021'), 'cancelled', 'decline d1: the request is cancelled');
select is((select array_agg(outcome order by n) from (values (1, current_setting('cf.r22')::jsonb ->> 'outcome'), (2, current_setting('cf.r23')::jsonb ->> 'outcome'),
            (3, current_setting('cf.r24')::jsonb ->> 'outcome'), (4, current_setting('cf.r25')::jsonb ->> 'outcome'), (5, current_setting('cf.r26')::jsonb ->> 'outcome'),
            (6, current_setting('cf.r27')::jsonb ->> 'outcome'), (7, current_setting('cf.r28')::jsonb ->> 'outcome')) v(n, outcome)),
  array['declined', 'declined', 'declined', 'declined', 'declined', 'declined', 'declined'],
  'every decline path declines: each code, the three-argument wrapper, an unknown code, no code, and a pg_net failure');
select is(current_setting('cf.rnote')::jsonb ->> 'outcome', 'note_required', 'decline: a blank note is still refused');
select is(current_setting('cf.rdenied')::jsonb ->> 'outcome', 'denied', 'decline: a cleaner is denied');
select is((select status from public.booking_inquiries where id = 'c0de5500-0000-4000-8000-000000000012'), 'pending', 'decline: the denied call left the request pending');
select is((select count(*)::int from public.booking_decisions d where d.booking_id = 'c0de5500-0000-4000-8000-000000000021' and d.outcome = 'declined'), 1,
  'decline d1: one decision row, the repeat did not write another');
select ok((select status = 'cancelled' from public.booking_inquiries where id = 'c0de5500-0000-4000-8000-000000000028')
      and exists (select 1 from public.booking_lifecycle_events e where e.booking_id = 'c0de5500-0000-4000-8000-000000000028' and e.event_type = 'cancelled'),
  'decline d8: pg_net failed and the decline still committed (a warning, never a block)');
select is((select e.after_state ->> 'reason_code' from public.booking_lifecycle_events e where e.idempotency_key = 'onetap-decline-audit:cf-decline-key-d2-dates'), 'dates',
  'decline d2: the audit row records the reason code');
select ok(case when current_setting('cf.stub') = 'on' then
            (select count(*) = 1 from net.cf_calls where url like '%/functions/v1/guest-messages'
               and body = '{"booking_id": "c0de5500-0000-4000-8000-000000000021", "key": "declined", "reason_code": "payment", "receipt_sent": true, "tapped": true}'::jsonb
               and headers ->> 'x-cascade-cron-secret' = 'CF-SYNTHETIC-ONLY')
          else true end,
  'decline d1: one post, key declined, reason payment, receipt_sent true, tapped, the cron secret header (and the repeat posted nothing)');
select ok(case when current_setting('cf.stub') = 'on' then
            (select count(*) = 1 from net.cf_calls where body = '{"booking_id": "c0de5500-0000-4000-8000-000000000022", "key": "declined", "reason_code": "dates", "receipt_sent": false, "tapped": true}'::jsonb)
          else true end,
  'decline d2: dates, no receipt');
select ok(case when current_setting('cf.stub') = 'on' then (select count(*) = 0 from net.cf_calls where body ->> 'booking_id' = 'c0de5500-0000-4000-8000-000000000023') else true end,
  'decline d3: a duplicate request queues no message at all');
select ok(case when current_setting('cf.stub') = 'on' then
            (select count(*) = 1 from net.cf_calls where body = '{"booking_id": "c0de5500-0000-4000-8000-000000000024", "key": "declined", "reason_code": "other", "receipt_sent": false, "tapped": true}'::jsonb)
          else true end,
  'decline d4: the three-argument wrapper declines as other');
select ok(case when current_setting('cf.stub') = 'on' then
            (select count(*) = 1 from net.cf_calls where body = '{"booking_id": "c0de5500-0000-4000-8000-000000000025", "key": "declined", "reason_code": "other", "receipt_sent": false, "tapped": true}'::jsonb)
          else true end,
  'decline d5: an unknown code reads as other');
select ok(case when current_setting('cf.stub') = 'on' then
            (select count(*) = 1 from net.cf_calls where body = '{"booking_id": "c0de5500-0000-4000-8000-000000000026", "key": "declined", "reason_code": "guest_cancel", "receipt_sent": false, "tapped": true}'::jsonb)
          else true end,
  'decline d6: guest_cancel is passed through');
select ok(case when current_setting('cf.stub') = 'on' then
            (select count(*) = 1 from net.cf_calls where body = '{"booking_id": "c0de5500-0000-4000-8000-000000000027", "key": "declined", "reason_code": "other", "receipt_sent": false, "tapped": true}'::jsonb)
          else true end,
  'decline d7: a null code reads as other');
select ok(case when current_setting('cf.stub') = 'on' then (select count(*) = 0 from net.cf_calls where body ->> 'booking_id' = 'c0de5500-0000-4000-8000-000000000028') else true end,
  'decline d8: the failed enqueue left no call behind');
select ok(case when current_setting('cf.stub') = 'on' then (select count(*) = 6 from net.cf_calls) else true end, 'six posts in all (d1, d2, d4, d5, d6, d7)');
select ok(case when current_setting('cf.stub') = 'on' then
            (select not exists (select 1 from net.cf_calls where body::text ~* '(phone|e-?mail|0917|@example|psid|Synthetic)') ) else true end,
  'the post carries no contact and no name');
select ok(not exists (select 1 from public.due_guest_messages_v1() where message_key = 'declined'), 'due_guest_messages_v1 never offers declined');

-- the CHECK -----------------------------------------------------------------------------------------------------------------------------------
select lives_ok($$insert into public.guest_message_log(booking_id, message_key, channel, status) values ('c0de5500-0000-4000-8000-000000000021', 'declined', 'email', 'sent')$$,
  'guest_message_log accepts the declined key');
select throws_ok($$insert into public.guest_message_log(booking_id, message_key, channel, status) values ('c0de5500-0000-4000-8000-000000000021', 'declined', 'email', 'sent')$$,
  '23505', null, 'a second declined row for the same booking is the once-only lock (23505)');
select throws_ok($$insert into public.guest_message_log(booking_id, message_key, channel, status) values ('c0de5500-0000-4000-8000-000000000022', 'zz_unknown', 'email', 'sent')$$,
  '23514', null, 'a key that is not on the list is still refused');
select lives_ok($$insert into public.guest_message_log(booking_id, message_key, channel, status) values ('c0de5500-0000-4000-8000-000000000022', 'confirmation', 'email', 'sent')$$,
  'the six scheduled keys are still accepted');

-- conversations: needs_reply, waiting_since ----------------------------------------------------------------------------------------------------
insert into public.concierge_threads(psid, guest_name, history, human_until, updated_at) values
  -- t1: an open hand-off (two of them: the older sets the wait), the bot spoke last
  ('zz-cf-t1', 'Zz T1', jsonb_build_array(jsonb_build_object('role', 'guest', 'text', 'q', 'at', '2026-11-20T01:00:00Z'), jsonb_build_object('role', 'bot', 'text', 'a', 'at', '2026-11-20T01:00:05Z')), null, '2026-11-20T01:00:05Z'),
  -- t2: the host holds the chat and the guest wrote last
  ('zz-cf-t2', 'Zz T2', jsonb_build_array(jsonb_build_object('role', 'host', 'text', 'hi', 'at', '2026-11-21T01:00:00Z'), jsonb_build_object('role', 'guest', 'text', 'when?', 'at', '2026-11-21T02:00:00Z')), now() + interval '1 day', '2026-11-21T02:00:00Z'),
  -- t3: the host holds the chat and the host wrote last
  ('zz-cf-t3', 'Zz T3', jsonb_build_array(jsonb_build_object('role', 'guest', 'text', 'when?', 'at', '2026-11-22T01:00:00Z'), jsonb_build_object('role', 'host', 'text', 'soon', 'at', '2026-11-22T02:00:00Z')), now() + interval '1 day', '2026-11-22T02:00:00Z'),
  -- t4: the bot answered, nobody holds the chat, no hand-off
  ('zz-cf-t4', 'Zz T4', jsonb_build_array(jsonb_build_object('role', 'guest', 'text', 'q', 'at', '2026-11-23T01:00:00Z'), jsonb_build_object('role', 'bot', 'text', 'a', 'at', '2026-11-23T01:00:05Z')), null, '2026-11-23T01:00:05Z'),
  -- t5: the host's hold has ended and the guest wrote last
  ('zz-cf-t5', 'Zz T5', jsonb_build_array(jsonb_build_object('role', 'guest', 'text', 'hello?', 'at', '2026-11-19T01:00:00Z')), now() - interval '1 hour', '2026-11-19T01:00:00Z');
insert into public.concierge_handoffs(psid, guest_name, guest_text, risk, status, created_at) values
  ('zz-cf-t1', 'Zz T1', 'newer ask', 'priority', 'open', '2026-11-20T03:00:00Z'),
  ('zz-cf-t1', 'Zz T1', 'older ask', 'priority', 'open', '2026-11-20T01:00:01Z'),
  ('zz-cf-t1', 'Zz T1', 'closed ask', 'priority', 'sent', '2026-11-19T01:00:01Z'),
  ('zz-cf-t4', 'Zz T4', 'dismissed ask', 'low', 'dismissed', '2026-11-23T01:00:01Z');
-- an open hand-off whose thread does not exist (the list never showed it)
insert into public.concierge_handoffs(psid, guest_name, guest_text, risk, status) values ('zz-cf-no-thread', 'Zz Orphan', 'orphan', 'low', 'open');

select set_config('request.jwt.claims', json_build_object('sub', 'e5500000-0000-4000-8000-0000000000a4', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select throws_ok($$select * from public.concierge_conversations_v1(100)$$, '42501', null, 'conversations: a cleaner is refused');
select throws_ok($$select * from public.concierge_waiting_v1()$$, '42501', null, 'concierge_waiting_v1: a cleaner is refused');
select set_config('request.jwt.claims', json_build_object('sub', 'e5500000-0000-4000-8000-0000000000a2', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
select is((select array_agg(c.psid || ':' || c.needs_reply::text order by c.psid) from public.concierge_conversations_v1(100) c where c.psid like 'zz-cf-t%'),
  array['zz-cf-t1:true', 'zz-cf-t2:true', 'zz-cf-t3:false', 'zz-cf-t4:false', 'zz-cf-t5:false'],
  'needs_reply for five threads: open hand-off, host holds + guest last, host holds + host last, bot last, hold ended + guest last');
select is((select waiting_since from public.concierge_conversations_v1(100) where psid = 'zz-cf-t1'), '2026-11-20T01:00:01Z'::timestamptz, 'waiting_since: the oldest open hand-off (not the newer, not the closed)');
select is((select waiting_since from public.concierge_conversations_v1(100) where psid = 'zz-cf-t2'), '2026-11-21T02:00:00Z'::timestamptz, 'waiting_since: the guest''s last turn when the host holds the chat');
select is((select count(*)::int from public.concierge_conversations_v1(100) where psid in ('zz-cf-t3', 'zz-cf-t4', 'zz-cf-t5') and waiting_since is null), 3, 'waiting_since is null when no reply is needed');
select is((select open_handoffs from public.concierge_conversations_v1(100) where psid = 'zz-cf-t1'), 2, 'open_handoffs still counts only the open ones');
select is((select array_agg(c.psid order by n) from public.concierge_conversations_v1(100) with ordinality as c(psid, psid_short, guest_name, updated_at, last_role, last_text, last_guest_at, open_handoffs, human_until, last_risk, needs_reply, waiting_since, n)
            where c.psid like 'zz-cf-t%'),
  array['zz-cf-t1', 'zz-cf-t4', 'zz-cf-t3', 'zz-cf-t2', 'zz-cf-t5'], 'the list order is unchanged: open hand-offs first, then newest update first');
select ok((select w.waiting >= 2 and w.oldest_at <= '2026-11-20T01:00:01Z'::timestamptz from public.concierge_waiting_v1() w),
  'concierge_waiting_v1: counts at least the two synthetic threads and the oldest wait reaches back to t1');
reset role;
select is((select waiting from public.concierge_waiting_v1()), (select count(*)::int from public.s_cf_waiting_v1() where needs_reply),
  'concierge_waiting_v1 counts exactly the threads the rule marks (one rule, written once)');
select is((select count(*)::int from public.s_cf_waiting_v1() where psid = 'zz-cf-no-thread'), 0, 'an open hand-off with no thread is not a waiting guest (the list never showed it)');

-- Home's inbox_open follows the same rule --------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', 'e5500000-0000-4000-8000-0000000000a3', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select is((public.notices_v1('e5500000-0000-4000-8000-000000000055') ->> 'inbox_open')::int, (select count(*)::int from public.s_cf_waiting_v1() where needs_reply),
  'notices_v1: inbox_open is the number of guests waiting for a reply');
select ok((public.notices_v1('e5500000-0000-4000-8000-000000000055') ->> 'inbox_open')::int >= 2, 'notices_v1: and it includes the synthetic t1 and t2');
reset role;
select ok((select prosrc like '%public.s_cf_waiting_v1() w where w.needs_reply%' and prosrc not like '%from public.concierge_handoffs h where h.status = ''open'';%'
             from pg_proc where oid = 'public.notices_v1(uuid)'::regprocedure), 'notices_v1: the anchored replace is in the live body and the old count is gone');
select is((select md5(replace(prosrc, chr(13), '')) from pg_proc where oid = 'public.notices_v1(uuid)'::regprocedure), '06204588643539a7a6b0e01df58a1d2a',
  'notices_v1: the body is the s91 body with that one line replaced (md5 pinned)');

select * from finish();
rollback;
