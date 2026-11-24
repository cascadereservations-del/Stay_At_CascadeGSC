-- Session 136: release s136_followups_20261206.
--   a. staff_decline_direct_booking_v1(uuid,text,text,text) also accepts a booking the hold sweep expired, when a reason_code event is already on file for it; no second guest notice then.
--   b. inventory_purchases.purchased_at defaults to public.manila_today() (was CURRENT_DATE, the UTC day).
-- Plus the per-property boundary of the admin helper (admin_require / current_staff_authorized) and anon's column-level privileges on the tables this release touches.
-- Synthetic fixtures only (uuids e1360000-...); rows are inserted as the table owner, the RPCs run as authenticated, everything rolls back.
--   F finance (a1) decides   C cleaner (a4) is refused   A admin (a3) of property P only; property Q (b2) belongs to nobody in this suite
--   Bookings (direct, property P, dates = today + 800 + 10 n):
--     1 pending, declined, then expired, then declined again   2 expired, no event   3 expired, only a hold_expired event   4 cancelled with a reason_code event
--     5 expired with a (Telegram-style) reason_code event, declined through the three-argument wrapper   6 pending control   8 expired with a reason_code event, a cleaner tries
-- pg_net and Vault are absent from a rehearsal copy: they are stubbed here (rolled back) so the guest-messages post is observable. Where the real pg_net exists (CI) the stub is not
-- installed and the assertions that read the stub are skipped with a reason (they used to pass vacuously).
begin;
select plan(41);

create temp table s136_calls(url text, headers jsonb, body jsonb);
create temp table _t(k text primary key, v jsonb);
grant all on _t to public;

do $$
begin
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null and to_regclass('vault.decrypted_secrets') is null then
    create schema if not exists net;
    create function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
                                  headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
      returns bigint language plpgsql as $f$
      begin
        insert into pg_temp.s136_calls values (url, headers, body);
        return 1;
      end $f$;
    create schema if not exists vault;
    create table vault.decrypted_secrets(name text, decrypted_secret text);
    insert into vault.decrypted_secrets values ('cascade_cron_shared_secret', 'S136-SYNTHETIC-ONLY');
    perform set_config('s136.stub', 'on', true);
  else
    perform set_config('s136.stub', 'off', true);
  end if;
end $$;

-- baseline grants for a --no-acl rehearsal restore (idempotent, rolled back with the suite)
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;
do $sr$ begin if not (select rolbypassrls from pg_roles where rolname = 'service_role') then alter role service_role bypassrls; end if; end $sr$;

-- 1-5 shape and grants ------------------------------------------------------------------------------------------------------------------------
select has_function('public', 'staff_decline_direct_booking_v1', array['uuid', 'text', 'text', 'text'], 'the four-argument decline exists');
select ok((select p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c in ('search_path=""', 'search_path='))
             and position('v_redecline' in p.prosrc) > 0 and position('e.after_state ? ''reason_code''' in p.prosrc) > 0
             from pg_proc p where p.oid = 'public.staff_decline_direct_booking_v1(uuid,text,text,text)'::regprocedure),
  'the four-argument decline is the s136 body: security definer, empty search_path, v_redecline and the reason_code event test');
select ok(has_function_privilege('authenticated', 'public.staff_decline_direct_booking_v1(uuid,text,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.staff_decline_direct_booking_v1(uuid,text,text,text)', 'execute')
      and not has_function_privilege('service_role', 'public.staff_decline_direct_booking_v1(uuid,text,text,text)', 'execute'),
  'grants restated: authenticated only (not anon, not service_role)');
select ok(has_function_privilege('authenticated', 'public.staff_decline_direct_booking_v1(uuid,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.staff_decline_direct_booking_v1(uuid,text,text)', 'execute')
      and not (select p.prosecdef from pg_proc p where p.oid = 'public.staff_decline_direct_booking_v1(uuid,text,text)'::regprocedure),
  'the three-argument wrapper keeps its grants and stays security invoker');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'staff_decline_direct_booking_v1'), 2,
  'still exactly two decline overloads');

-- fixtures ----------------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values ('e1360000-0000-4000-8000-0000000000b1', 'Synthetic S136 P', true), ('e1360000-0000-4000-8000-0000000000b2', 'Synthetic S136 Q', true);
insert into auth.users(id) values ('e1360000-0000-4000-8000-0000000000a1'), ('e1360000-0000-4000-8000-0000000000a3'), ('e1360000-0000-4000-8000-0000000000a4');
insert into public.staff_access_profiles(user_id, role, telegram_user_id, disabled_at, note) values
  ('e1360000-0000-4000-8000-0000000000a1', 'finance', 936000001, null, 'Finance F'),
  ('e1360000-0000-4000-8000-0000000000a3', 'admin',   936000003, null, 'Admin A'),
  ('e1360000-0000-4000-8000-0000000000a4', 'cleaner', 936000004, null, 'Cleaner C');
insert into public.staff_property_access(user_id, property_id) values
  ('e1360000-0000-4000-8000-0000000000a1', 'e1360000-0000-4000-8000-0000000000b1'),
  ('e1360000-0000-4000-8000-0000000000a3', 'e1360000-0000-4000-8000-0000000000b1'),
  ('e1360000-0000-4000-8000-0000000000a4', 'e1360000-0000-4000-8000-0000000000b1');
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, status, source, receipt_image_path, total_amount, deposit_amount, submitted_at)
select ('e1360000-0000-4000-8000-00000000' || lpad(n::text, 4, '0'))::uuid, 'e1360000-0000-4000-8000-0000000000b1', 'Synthetic ' || n, null, '0917360' || lpad(n::text, 4, '0'),
       current_date + 800 + 10 * n, current_date + 802 + 10 * n, 2, 'pending', 'direct', null, 2000, 1000, now() - make_interval(mins => 100 - n)
  from generate_series(1, 8) n;
insert into public.inventory_items(id, property_id, name, category, unit, qty_on_hand, is_consumable, is_active, units_per_purchase, unit_cost, purchase_unit) values
  ('e1360000-0000-4000-8000-0000000000c1', 'e1360000-0000-4000-8000-0000000000b1', 'Zz S136 Soap P', 'Toiletries', 'pc', 10, true, true, 1, 20, null),
  ('e1360000-0000-4000-8000-0000000000c2', 'e1360000-0000-4000-8000-0000000000b2', 'Zz S136 Soap Q', 'Toiletries', 'pc', 10, true, true, 1, 20, null);

-- the reason_code events and the expiries, as the sweep and the Telegram decline leave them
update public.booking_inquiries set status = 'expired' where id in ('e1360000-0000-4000-8000-000000000002', 'e1360000-0000-4000-8000-000000000003',
  'e1360000-0000-4000-8000-000000000005', 'e1360000-0000-4000-8000-000000000008');
update public.booking_inquiries set status = 'cancelled' where id = 'e1360000-0000-4000-8000-000000000004';
insert into public.booking_lifecycle_events(property_id, booking_id, event_type, reason, idempotency_key, after_state) values
  ('e1360000-0000-4000-8000-0000000000b1', 'e1360000-0000-4000-8000-000000000003', 'hold_expired', 'Automated hold expiry', 'zz-s136-expire-0000000003', '{"status":"expired"}'),
  ('e1360000-0000-4000-8000-0000000000b1', 'e1360000-0000-4000-8000-000000000004', 'cancelled', 'Declined in Telegram: dup', 'zz-s136-telegram-00000004', '{"reason_code":"dup","telegram_user_id":936000001}'),
  ('e1360000-0000-4000-8000-0000000000b1', 'e1360000-0000-4000-8000-000000000005', 'cancelled', 'Declined in Telegram: house', 'zz-s136-telegram-00000005', '{"reason_code":"house","telegram_user_id":936000001}'),
  ('e1360000-0000-4000-8000-0000000000b1', 'e1360000-0000-4000-8000-000000000008', 'cancelled', 'Declined in Telegram: other', 'zz-s136-telegram-00000008', '{"reason_code":"other","telegram_user_id":936000001}');

-- 6-26 the decline gate, as F -----------------------------------------------------------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', 'e1360000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
insert into _t select 'r1', public.staff_decline_direct_booking_v1('e1360000-0000-4000-8000-000000000001', 'Payment did not arrive', 'zz-s136-decline-key-001', 'payment');
reset role;
-- booking 1 is now cancelled with a reason_code event; the sweep later marks it expired (expire_booking_holds_v1 does: status in pending, cancelled)
update public.booking_inquiries set status = 'expired' where id = 'e1360000-0000-4000-8000-000000000001';
select set_config('request.jwt.claims', json_build_object('sub', 'e1360000-0000-4000-8000-0000000000a1', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
insert into _t select 'r1b', public.staff_decline_direct_booking_v1('e1360000-0000-4000-8000-000000000001', 'Retried after the hold expired', 'zz-s136-decline-key-002', 'other');
insert into _t select 'r1c', public.staff_decline_direct_booking_v1('e1360000-0000-4000-8000-000000000001', 'Retried after the hold expired', 'zz-s136-decline-key-002', 'other');
insert into _t select 'r2', public.staff_decline_direct_booking_v1('e1360000-0000-4000-8000-000000000002', 'Expired, no decline on file', 'zz-s136-decline-key-003', 'other');
insert into _t select 'r3', public.staff_decline_direct_booking_v1('e1360000-0000-4000-8000-000000000003', 'Expired by the sweep only', 'zz-s136-decline-key-004', 'other');
insert into _t select 'r4', public.staff_decline_direct_booking_v1('e1360000-0000-4000-8000-000000000004', 'Already cancelled', 'zz-s136-decline-key-005', 'other');
insert into _t select 'r5', public.staff_decline_direct_booking_v1('e1360000-0000-4000-8000-000000000005', 'Telegram decline, retried in the app', 'zz-s136-decline-key-006');
insert into _t select 'r6', public.staff_decline_direct_booking_v1('e1360000-0000-4000-8000-000000000006', 'Control: a pending request', 'zz-s136-decline-key-007', 'dates');
select set_config('request.jwt.claims', json_build_object('sub', 'e1360000-0000-4000-8000-0000000000a4', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
insert into _t select 'r8', public.staff_decline_direct_booking_v1('e1360000-0000-4000-8000-000000000008', 'A cleaner tries', 'zz-s136-decline-key-008', 'other');
reset role;

select is((select v ->> 'outcome' from _t where k = 'r1'), 'declined', 'booking 1: the first decline (pending) declines');
select is((select status from public.booking_inquiries where id = 'e1360000-0000-4000-8000-000000000001'), 'cancelled', 'booking 1: cancelled after the retry on the expired row (the retry put it back)');
select ok((select (v ->> 'ok')::boolean and v ->> 'outcome' = 'declined' and coalesce(v ->> 'already_processed', 'false') = 'false' from _t where k = 'r1b'),
  'booking 1: the retry on the expired booking (reason_code event on file) is declined, not refused as not_pending');
select is((select count(*)::int from public.booking_decisions d where d.booking_id = 'e1360000-0000-4000-8000-000000000001' and d.outcome = 'declined'), 2,
  'booking 1: two declined decision rows (the first, and the retry under its own key)');
select is((select count(*)::int from public.booking_lifecycle_events e where e.booking_id = 'e1360000-0000-4000-8000-000000000001' and e.after_state ? 'reason_code'), 2,
  'booking 1: two reason_code audit events');
select is((select e.after_state ->> 'reason_code' from public.booking_lifecycle_events e where e.idempotency_key = 'onetap-decline-audit:zz-s136-decline-key-002'), 'other',
  'booking 1: the retry''s audit event records its own reason code');
select is((select v ->> 'already_processed' from _t where k = 'r1c'), 'true', 'booking 1: the retry repeated with the same key is already processed');
select is((select count(*)::int from public.booking_decisions d where d.booking_id = 'e1360000-0000-4000-8000-000000000001' and d.outcome = 'declined'), 2,
  'booking 1: the repeat wrote no third decision row');

select is((select v ->> 'outcome' || '/' || (v ->> 'reason') || '/' || (v ->> 'status') from _t where k = 'r2'), 'invalid_state/not_pending/expired',
  'booking 2: expired with no reason_code event is still refused as not_pending');
select is((select status from public.booking_inquiries where id = 'e1360000-0000-4000-8000-000000000002'), 'expired', 'booking 2: still expired');
select is((select count(*)::int from public.booking_decisions d where d.booking_id = 'e1360000-0000-4000-8000-000000000002'), 0, 'booking 2: no decision row written');
select is((select v ->> 'outcome' || '/' || (v ->> 'reason') from _t where k = 'r3'), 'invalid_state/not_pending',
  'booking 3: expired with only a hold_expired event (after_state without reason_code) is refused');
select is((select v ->> 'outcome' || '/' || (v ->> 'status') from _t where k = 'r4'), 'invalid_state/cancelled',
  'booking 4: a cancelled booking with a reason_code event is refused (the allowance is for expired only)');
select ok((select v ->> 'outcome' = 'declined' from _t where k = 'r5')
      and (select status from public.booking_inquiries where id = 'e1360000-0000-4000-8000-000000000005') = 'cancelled'
      and (select count(*)::int from public.booking_decisions d where d.booking_id = 'e1360000-0000-4000-8000-000000000005' and d.outcome = 'declined') = 1,
  'booking 5: the three-argument wrapper declines an expired booking with a Telegram reason_code event (cancelled, one decision)');
select is((select v ->> 'outcome' from _t where k = 'r6'), 'declined', 'booking 6: the pending control declines as before');
select is((select v ->> 'outcome' from _t where k = 'r8'), 'denied', 'booking 8: a cleaner is denied on an expired booking too');
select is((select status from public.booking_inquiries where id = 'e1360000-0000-4000-8000-000000000008'), 'expired', 'booking 8: the denied call left it expired');

select case when current_setting('s136.stub') = 'on' then
         ok((select count(*) = 1 from pg_temp.s136_calls where body ->> 'booking_id' = 'e1360000-0000-4000-8000-000000000001' and body ->> 'reason_code' = 'payment' and body ->> 'key' = 'declined'
             and headers ->> 'x-cascade-cron-secret' = 'S136-SYNTHETIC-ONLY'),
            'booking 1: the first decline posted one guest notice (reason payment)')
       else skip('pg_net is real here (CI), the stub is not installed: the post cannot be read', 1) end;
select case when current_setting('s136.stub') = 'on' then
         ok((select count(*) = 1 from pg_temp.s136_calls where body ->> 'booking_id' = 'e1360000-0000-4000-8000-000000000001'),
            'booking 1: the retry on the expired booking posted nothing (the guest was told by the first decline), still one post')
       else skip('pg_net is real here (CI), the stub is not installed: the post cannot be read', 1) end;
select case when current_setting('s136.stub') = 'on' then
         ok((select count(*) = 0 from pg_temp.s136_calls where body ->> 'booking_id' in ('e1360000-0000-4000-8000-000000000005', 'e1360000-0000-4000-8000-000000000002')),
            'booking 5: the wrapper decline of an expired booking posted nothing')
       else skip('pg_net is real here (CI), the stub is not installed: the post cannot be read', 1) end;
select case when current_setting('s136.stub') = 'on' then
         ok((select count(*) = 1 from pg_temp.s136_calls where body = '{"booking_id": "e1360000-0000-4000-8000-000000000006", "key": "declined", "reason_code": "dates", "receipt_sent": false, "tapped": true}'::jsonb)
            and (select count(*) = 2 from pg_temp.s136_calls),
            'booking 6: the pending control still posts its notice, two posts in all')
       else skip('pg_net is real here (CI), the stub is not installed: the post cannot be read', 1) end;

-- 27-32 purchases are dated by the Manila day ---------------------------------------------------------------------------------------------------
select ok((select pg_get_expr(ad.adbin, ad.adrelid) ~* 'manila_today' from pg_attrdef ad join pg_attribute a on a.attrelid = ad.adrelid and a.attnum = ad.adnum
            where ad.adrelid = 'public.inventory_purchases'::regclass and a.attname = 'purchased_at'),
  'inventory_purchases.purchased_at defaults to manila_today()');
select ok((select pg_get_expr(ad.adbin, ad.adrelid) !~* 'current_date' from pg_attrdef ad join pg_attribute a on a.attrelid = ad.adrelid and a.attnum = ad.adnum
            where ad.adrelid = 'public.inventory_purchases'::regclass and a.attname = 'purchased_at'),
  'and no longer to current_date (the UTC day)');
insert into public.inventory_purchases(id, item_id, qty) values ('e1360000-0000-4000-8000-0000000000d1', 'e1360000-0000-4000-8000-0000000000c1', 3);
select is((select purchased_at from public.inventory_purchases where id = 'e1360000-0000-4000-8000-0000000000d1'), public.manila_today(),
  'a purchase inserted without a date is dated by the Manila day');
select is((select purchased_at from public.inventory_purchases where id = 'e1360000-0000-4000-8000-0000000000d1'), (now() at time zone 'Asia/Manila')::date,
  'which is the Manila date of now(), whatever the UTC date is');
insert into public.inventory_purchases(id, item_id, qty, purchased_at) values ('e1360000-0000-4000-8000-0000000000d2', 'e1360000-0000-4000-8000-0000000000c1', 1, date '2026-01-15');
select is((select purchased_at from public.inventory_purchases where id = 'e1360000-0000-4000-8000-0000000000d2'), date '2026-01-15', 'a date typed by hand is kept');
select is((select qty from public.inventory_purchases where id = 'e1360000-0000-4000-8000-0000000000d1'), 3::numeric, 'the default change touches nothing else on the row (qty 3)');

-- 33-38 the admin helper keeps one property apart from another (A is admin of P only) -------------------------------------------------------------
select set_config('request.jwt.claims', json_build_object('sub', 'e1360000-0000-4000-8000-0000000000a3', 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true);
set local role authenticated;
select lives_ok($$select public.admin_require('manage_inventory', 'e1360000-0000-4000-8000-0000000000b1')$$, 'admin of P passes admin_require on P');
select throws_ok($$select public.admin_require('manage_inventory', 'e1360000-0000-4000-8000-0000000000b2')$$, '42501', 'manage_inventory denied',
  'admin of P is refused by admin_require on Q (42501)');
select ok(public.current_staff_authorized('manage_inventory', 'e1360000-0000-4000-8000-0000000000b1')
      and not public.current_staff_authorized('manage_inventory', 'e1360000-0000-4000-8000-0000000000b2'),
  'current_staff_authorized: P yes, Q no');
select throws_ok($$select public.record_inventory_receipt_v1('e1360000-0000-4000-8000-0000000000c2'::uuid, 1, 10, 'zz', null, null, null, 'zz-s136-receipt-key-q1')$$, '42501', null,
  'admin of P cannot receive stock onto an item of Q through the admin helper (42501)');
select lives_ok($$select public.record_inventory_receipt_v1('e1360000-0000-4000-8000-0000000000c1'::uuid, 1, 10, 'zz', null, null, null, 'zz-s136-receipt-key-p1')$$,
  'the same call on an item of P works');
reset role;
select is((select count(*)::int from public.inventory_purchases where item_id = 'e1360000-0000-4000-8000-0000000000c2'), 0, 'and nothing was written for Q');

-- 39-41 anon has no privilege at all (table level and column level) on what this release touches ----------------------------------------------------------
select ok((select bool_and(not has_table_privilege('anon', t, p) and not has_any_column_privilege('anon', t, p))
             from unnest(array['public.inventory_purchases', 'public.booking_lifecycle_events', 'public.booking_decisions']) t, unnest(array['select', 'insert', 'update']) p),
  'anon: no select, insert or update on inventory_purchases, booking_lifecycle_events or booking_decisions, by table or by column');
select ok((select bool_and(not has_table_privilege('anon', t, 'delete') and not has_table_privilege('anon', t, 'truncate'))
             from unnest(array['public.inventory_purchases', 'public.booking_lifecycle_events', 'public.booking_decisions']) t),
  'anon: no delete or truncate either');
select ok(not has_function_privilege('anon', 'public.admin_require(text, uuid)', 'execute'), 'anon cannot call admin_require');

select * from finish();
rollback;
