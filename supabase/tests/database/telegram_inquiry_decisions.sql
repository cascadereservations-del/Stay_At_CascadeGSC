-- Session 70 (SPEC-38): release telegram_inquiry_decisions_20261005. Decide a direct request before payment from Telegram:
-- hold the dates 24 h or decline with a reason code. Also the widened telegram_pending kinds (refund_confirm, inquiry_reply,
-- lock_code) and the guest_replied lifecycle event. Synthetic fixtures only (public repo); rows are inserted as the owner because
-- service_role has no BYPASSRLS in the rehearsal, and they go with the closing rollback. Property P is private to this suite.
--   admin A (tg 907000001, note 'Admin A') admin with property access  -> may decide
--   admin B (tg 907000002) admin WITHOUT property access                -> refused
--   cleaner C (tg 907000003) role without approve_payment               -> refused
--   admin D (tg 907000004) disabled                                     -> refused
--   owner O (tg 907000005) owner, no property row (owners need none)    -> may decide
--   tg 907000099 is mapped to nobody
--   b1 pending, calendar block, pending income row.   b2 pending with a receipt.   b3 pending, overlaps a confirmed Airbnb stay.
--   b4 cancelled.   b5 pending with a 2 h hold from open_booking_hold_v1.   b6 pending, no hold.
-- submitted_at is far in the past so the fixtures sort first in telegram_inquiry_view_v1(null), whatever else a restore holds.
begin;
select plan(55);

-- shape and grants
select has_function('public', 'telegram_inquiry_view_v1', array['uuid'], 'view RPC exists');
select has_function('public', 'telegram_inquiry_decide_v1', array['bigint', 'uuid', 'text', 'text', 'integer'], 'decide RPC exists');
select has_function('public', 'telegram_inquiry_message_logged_v1', array['uuid', 'bigint', 'text', 'text', 'text', 'boolean', 'text', 'text'], 'message-logged RPC exists');
select ok(has_function_privilege('service_role', 'public.telegram_inquiry_view_v1(uuid)', 'execute')
      and has_function_privilege('service_role', 'public.telegram_inquiry_decide_v1(bigint,uuid,text,text,integer)', 'execute')
      and has_function_privilege('service_role', 'public.telegram_inquiry_message_logged_v1(uuid,bigint,text,text,text,boolean,text,text)', 'execute'),
  'service_role can execute all three');
select ok(not has_function_privilege('anon', 'public.telegram_inquiry_view_v1(uuid)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_inquiry_view_v1(uuid)', 'execute')
      and not has_function_privilege('anon', 'public.telegram_inquiry_decide_v1(bigint,uuid,text,text,integer)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_inquiry_decide_v1(bigint,uuid,text,text,integer)', 'execute')
      and not has_function_privilege('anon', 'public.telegram_inquiry_message_logged_v1(uuid,bigint,text,text,text,boolean,text,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_inquiry_message_logged_v1(uuid,bigint,text,text,text,boolean,text,text)', 'execute'),
  'anon and authenticated can execute none');
select ok((select count(*) = 3 and bool_and(p.prosecdef and p.proconfig = array['search_path=""'])
             from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('telegram_inquiry_view_v1', 'telegram_inquiry_decide_v1', 'telegram_inquiry_message_logged_v1')),
  'all three are security definer with an empty search_path');

-- the two CHECKs (the three new pending kinds, each inserted; every old kind kept; an unknown one refused)
select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload) values (-900000070,'refund_confirm','{"synthetic":true}'::jsonb)$$,
  'pending: refund_confirm is accepted (the live /refund kind)');
select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload) values (-900000070,'inquiry_reply','{"synthetic":true}'::jsonb)$$,
  'pending: inquiry_reply is accepted');
select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload) values (-900000070,'lock_code','{"synthetic":true}'::jsonb)$$,
  'pending: lock_code (reserved for wave 2) is accepted');
select lives_ok($$insert into public.telegram_pending(chat_id,kind,payload) values (-900000070,'guest_save','{"synthetic":true}'::jsonb)$$,
  'pending: an existing kind (guest_save) is still accepted');
select throws_ok($$insert into public.telegram_pending(chat_id,kind,payload) values (-900000070,'no_such_kind','{}'::jsonb)$$,
  '23514', null, 'pending: an unknown kind is still refused');
select ok((select bool_and(pg_get_constraintdef(c.oid) like '%''' || k || '''%')
             from pg_constraint c,
                  unnest(array['duplicate','large_amount','photo_dup','inventory_sync','advisory_notice','advisory_scan','llm_expense','llm_notice',
                               'llm_void_notice','llm_void_txn','llm_void_txns','llm_edit_notice','inventory_count','awaiting_reply','llm_house',
                               'guest_pick','guest_save','refund_confirm','inquiry_reply','lock_code']) k
            where c.conrelid = 'public.telegram_pending'::regclass and c.conname = 'telegram_pending_kind_check'),
  'pending: the CHECK names all 17 old kinds plus refund_confirm, inquiry_reply and lock_code');

insert into public.properties(id, name, is_active) values ('e3000000-0000-4000-8000-000000000070', 'Synthetic Inquiry Decisions 70', true);

select lives_ok($$insert into public.booking_lifecycle_events(property_id,booking_id,event_type,reason,idempotency_key)
  values ('e3000000-0000-4000-8000-000000000070', null, 'guest_replied', 'synthetic check', 'synthetic-s70-guest-replied-ok')$$,
  'lifecycle: guest_replied is accepted');
select lives_ok($$insert into public.booking_lifecycle_events(property_id,booking_id,event_type,reason,idempotency_key)
  values ('e3000000-0000-4000-8000-000000000070', null, 'rate_promotion_ended', 'synthetic check', 'synthetic-s70-promotion-ended-ok')$$,
  'lifecycle: an existing event type (rate_promotion_ended) is still accepted');
select throws_ok($$insert into public.booking_lifecycle_events(property_id,booking_id,event_type,reason,idempotency_key)
  values ('e3000000-0000-4000-8000-000000000070', null, 'no_such_event', 'synthetic check', 'synthetic-s70-no-such-event')$$,
  '23514', null, 'lifecycle: an unknown event type is still refused');

-- fixtures
insert into auth.users(id) values
  ('e3000000-0000-4000-8000-0000000000a1'), ('e3000000-0000-4000-8000-0000000000a2'), ('e3000000-0000-4000-8000-0000000000a3'),
  ('e3000000-0000-4000-8000-0000000000a4'), ('e3000000-0000-4000-8000-0000000000a5');
insert into public.staff_access_profiles(user_id, role, telegram_user_id, disabled_at, note) values
  ('e3000000-0000-4000-8000-0000000000a1', 'admin',   907000001, null, 'Admin A'),
  ('e3000000-0000-4000-8000-0000000000a2', 'admin',   907000002, null, 'Admin B'),
  ('e3000000-0000-4000-8000-0000000000a3', 'cleaner', 907000003, null, 'Cleaner C'),
  ('e3000000-0000-4000-8000-0000000000a4', 'admin',   907000004, now(), 'Admin D'),
  ('e3000000-0000-4000-8000-0000000000a5', 'owner',   907000005, null, 'Owner O');
insert into public.staff_property_access(user_id, property_id) values
  ('e3000000-0000-4000-8000-0000000000a1', 'e3000000-0000-4000-8000-000000000070'),
  ('e3000000-0000-4000-8000-0000000000a3', 'e3000000-0000-4000-8000-000000000070'),
  ('e3000000-0000-4000-8000-0000000000a4', 'e3000000-0000-4000-8000-000000000070');

insert into public.booking_inquiries(id, property_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax, status, source, submitted_at, receipt_image_path, total_amount, deposit_amount, notes) values
  ('c0de7001-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000070', 'Synthetic One',   'one@example.com',   '09170000701', current_date + 40, current_date + 42, 2, 'pending',   'direct', '2000-01-01 00:00+00', null, 3560, 1780, 'is early check-in possible?'),
  ('c0de7001-0000-4000-8000-000000000002', 'e3000000-0000-4000-8000-000000000070', 'Synthetic Two',   'two@example.com',   '09170000702', current_date + 45, current_date + 47, 2, 'pending',   'direct', '2000-01-02 00:00+00', 'receipts/synthetic-70-b2.jpg', 3560, 1780, null),
  ('c0de7001-0000-4000-8000-000000000003', 'e3000000-0000-4000-8000-000000000070', 'Synthetic Three', 'three@example.com', '09170000703', current_date + 50, current_date + 52, 2, 'pending',   'direct', '2000-01-03 00:00+00', null, 3560, 1780, null),
  ('c0de7001-0000-4000-8000-000000000004', 'e3000000-0000-4000-8000-000000000070', 'Synthetic Four',  'four@example.com',  '09170000704', current_date + 60, current_date + 62, 2, 'cancelled', 'direct', '2000-01-04 00:00+00', null, 3560, 1780, null),
  ('c0de7001-0000-4000-8000-000000000005', 'e3000000-0000-4000-8000-000000000070', 'Synthetic Five',  'five@example.com',  '09170000705', current_date + 70, current_date + 72, 2, 'pending',   'direct', '2000-01-05 00:00+00', null, 3560, 1780, null),
  ('c0de7001-0000-4000-8000-000000000006', 'e3000000-0000-4000-8000-000000000070', 'Synthetic Six',   'six@example.com',   '09170000706', current_date + 80, current_date + 82, 2, 'pending',   'direct', '2000-01-06 00:00+00', null, 3560, 1780, null);
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, guest_name) values
  ('e3000000-0000-4000-8000-000000000070', 'direct:c0de7001-0000-4000-8000-000000000001', 'direct', 'blocked', current_date + 40, current_date + 42, 'Synthetic One'),
  ('e3000000-0000-4000-8000-000000000070', 'synthetic-s70-3@airbnb.com', 'airbnb', 'confirmed', current_date + 49, current_date + 53, 'Synthetic Airbnb');
insert into public.transactions(property_id, txn_type, category, source, status, transaction_date, gross_amount, currency, booking_id, external_ref)
values ('e3000000-0000-4000-8000-000000000070', 'income', 'direct_booking', 'direct_booking', 'pending_review', current_date + 40, 1780, 'PHP',
        'c0de7001-0000-4000-8000-000000000001', 'c0de7001-0000-4000-8000-000000000001');
select public.open_booking_hold_v1('c0de7001-0000-4000-8000-000000000005', 2);

-- who may hold: nobody who is unmapped, not an approver, disabled, or without the property; and nothing is written
select is(public.telegram_inquiry_decide_v1(907000099, 'c0de7001-0000-4000-8000-000000000001', 'hold'),
  '{"ok": false, "reason": "unmapped_telegram_user"}'::jsonb, 'hold: an unmapped Telegram user is refused');
select is(public.telegram_inquiry_decide_v1(907000003, 'c0de7001-0000-4000-8000-000000000001', 'hold'),
  '{"ok": false, "reason": "not_authorized"}'::jsonb, 'hold: a cleaner (no approve_payment) is refused');
select is(public.telegram_inquiry_decide_v1(907000004, 'c0de7001-0000-4000-8000-000000000001', 'hold'),
  '{"ok": false, "reason": "not_authorized"}'::jsonb, 'hold: a disabled admin is refused');
select is(public.telegram_inquiry_decide_v1(907000002, 'c0de7001-0000-4000-8000-000000000001', 'hold'),
  '{"ok": false, "reason": "not_authorized"}'::jsonb, 'hold: an admin without the property is refused');
select is((select (select count(*) from public.booking_holds where booking_id = 'c0de7001-0000-4000-8000-000000000001')
                + (select count(*) from public.booking_lifecycle_events where idempotency_key = 'tg-inquiry-hold:c0de7001-0000-4000-8000-000000000001'))::int,
  0, 'hold: the refusals left no hold and no hold audit row');

-- hold b1 by admin A
select set_config('cascade.s70_hold1', public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000001', 'hold')::text, true);
select is(current_setting('cascade.s70_hold1')::jsonb - 'expires_at' - 'actor_user_id',
  '{"ok": true, "outcome": "held", "already_processed": false, "extended": false, "actor_role": "admin"}'::jsonb,
  'hold: admin A holds b1 (one named actor, not a repeat)');
select ok((select count(*) = 1 and bool_and(expires_at between now() + interval '23 hours 59 minutes' and now() + interval '24 hours 1 minute')
             from public.booking_holds where booking_id = 'c0de7001-0000-4000-8000-000000000001' and status = 'active'),
  'hold: exactly one active hold, expiring in 24 h');
select is((select count(*)::int from public.booking_lifecycle_events
            where booking_id = 'c0de7001-0000-4000-8000-000000000001' and event_type = 'hold_created'
              and actor_user_id = 'e3000000-0000-4000-8000-0000000000a1' and idempotency_key = 'tg-inquiry-hold:c0de7001-0000-4000-8000-000000000001'),
  1, 'hold: one hold_created row with admin A as actor');
select is((select b.status || '/' || c.status from public.booking_inquiries b
             join public.calendar_events c on c.uid = 'direct:' || b.id::text where b.id = 'c0de7001-0000-4000-8000-000000000001'),
  'pending/blocked', 'hold: the request stays pending and its calendar block stays');
select is((public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000001', 'hold')) ->> 'already_processed', 'true',
  'hold: a second tap reports already_processed');
select is((select (select count(*) from public.booking_holds where booking_id = 'c0de7001-0000-4000-8000-000000000001')
                + (select count(*) from public.booking_lifecycle_events where booking_id = 'c0de7001-0000-4000-8000-000000000001' and event_type = 'hold_created'))::int,
  2, 'hold: still one hold and one lifecycle row after the second tap');

-- extend, conflict, receipt, not pending, clamp, owner
select is((public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000005', 'hold')) ->> 'extended', 'true',
  'hold: b5 already had a 2 h hold, so it is extended');
select ok((select count(*) = 1 and bool_and(expires_at >= now() + interval '23 hours 59 minutes')
             from public.booking_holds where booking_id = 'c0de7001-0000-4000-8000-000000000005' and status = 'active'),
  'hold: b5 still has exactly one active hold, now about 24 h');
select is(public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000003', 'hold') ->> 'reason', 'conflict',
  'hold: b3 overlaps a confirmed Airbnb stay -> conflict');
select is((select count(*)::int from public.booking_holds where booking_id = 'c0de7001-0000-4000-8000-000000000003'), 0, 'hold: the conflict wrote no hold');
select is(public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000002', 'hold') ->> 'reason', 'receipt_arrived',
  'hold: b2 already has a receipt -> receipt_arrived (decide on the receipt card)');
select is(public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000004', 'hold') ->> 'reason', 'not_pending',
  'hold: b4 is cancelled -> not_pending');
select ok((select (r ->> 'ok')::boolean and (r ->> 'expires_at')::timestamptz <= now() + interval '48 hours 1 minute' and (r ->> 'actor_role') = 'owner'
             from (select public.telegram_inquiry_decide_v1(907000005, 'c0de7001-0000-4000-8000-000000000006', 'hold', null, 500) as r) q),
  'hold: an owner needs no property row, and 500 h is clamped to 48 h');

-- decline
select is(public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000001', 'decline', 'zzz') ->> 'reason', 'bad_reason',
  'decline: an unknown reason code is refused');
select is((select status from public.booking_inquiries where id = 'c0de7001-0000-4000-8000-000000000001'), 'pending', 'decline: a refused code leaves b1 pending');
select is(public.telegram_inquiry_decide_v1(907000003, 'c0de7001-0000-4000-8000-000000000001', 'decline', 'taken') ->> 'reason', 'not_authorized',
  'decline: a cleaner cannot decline');
select is(public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000001', 'cancel_it') ->> 'reason', 'bad_action',
  'decline: an unknown action is refused');
select is(public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000002', 'decline', 'taken') ->> 'reason', 'receipt_arrived',
  'decline: b2 has a receipt -> receipt_arrived');
select set_config('cascade.s70_dec1', public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000001', 'decline', 'taken')::text, true);
select is(current_setting('cascade.s70_dec1')::jsonb ->> 'outcome' || '/' || (current_setting('cascade.s70_dec1')::jsonb ->> 'ok')
          || '/' || (current_setting('cascade.s70_dec1')::jsonb ->> 'already_processed') || '/' || (current_setting('cascade.s70_dec1')::jsonb ->> 'reason_code'),
  'declined/true/false/taken', 'decline: admin A declines b1 with reason taken');
select is((select b.status || '/' || c.status from public.booking_inquiries b
             join public.calendar_events c on c.uid = 'direct:' || b.id::text where b.id = 'c0de7001-0000-4000-8000-000000000001'),
  'cancelled/cancelled', 'decline: the request and its calendar row are cancelled');
select is((select status from public.transactions where external_ref = 'c0de7001-0000-4000-8000-000000000001'), 'void', 'decline: the pending income row is void');
select is((select status from public.booking_holds where booking_id = 'c0de7001-0000-4000-8000-000000000001'), 'released',
  'decline: the guard trigger released the hold');
select is((select count(*)::int from public.booking_decisions
            where booking_id = 'c0de7001-0000-4000-8000-000000000001' and outcome = 'declined' and idempotency_key = 'tg-inquiry-decline:c0de7001-0000-4000-8000-000000000001'),
  1, 'decline: one booking_decisions row, declined, under the telegram key');
select is((select count(*)::int from public.booking_lifecycle_events
            where booking_id = 'c0de7001-0000-4000-8000-000000000001' and event_type = 'cancelled'
              and actor_user_id = 'e3000000-0000-4000-8000-0000000000a1' and reason like '%taken%'),
  1, 'decline: one cancelled lifecycle row, actor A, naming the reason');
select is((public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000001', 'decline', 'taken')) ->> 'already_processed', 'true',
  'decline: a second tap reports already_processed');
select is((select count(*)::int from public.booking_decisions where booking_id = 'c0de7001-0000-4000-8000-000000000001'), 1,
  'decline: still one booking_decisions row after the second tap');
select is(public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000001', 'hold') ->> 'reason', 'not_pending',
  'decline then hold: a declined request cannot be held');
select is(public.telegram_inquiry_decide_v1(907000001, 'c0de7001-0000-4000-8000-000000000004', 'decline', 'dup') ->> 'reason', 'not_pending',
  'decline: b4 was cancelled elsewhere -> not_pending, no decision row written');

-- the view
select ok((select bool_or(e ->> 'id' = 'c0de7001-0000-4000-8000-000000000005') and bool_or(e ->> 'id' = 'c0de7001-0000-4000-8000-000000000006')
              and not bool_or(e ->> 'id' in ('c0de7001-0000-4000-8000-000000000001', 'c0de7001-0000-4000-8000-000000000002', 'c0de7001-0000-4000-8000-000000000004'))
             from jsonb_array_elements(public.telegram_inquiry_view_v1(null)) e),
  'view: the open list holds b5 and b6, and not b1 (declined), b2 (receipt) or b4 (cancelled)');
select is(public.telegram_inquiry_view_v1('c0de7001-0000-4000-8000-000000000001') -> 0 ->> 'status', 'cancelled', 'view: one request by id shows its status whatever it is');
select is(public.telegram_inquiry_view_v1('c0de7001-0000-4000-8000-000000000003') -> 0 ->> 'conflict', 'true', 'view: b3 reports conflict');
select is((public.telegram_inquiry_view_v1('c0de7001-0000-4000-8000-000000000006') -> 0 ->> 'held_by')
          || '/' || ((public.telegram_inquiry_view_v1('c0de7001-0000-4000-8000-000000000006') -> 0 ->> 'hold_expires_at') is not null)::text,
  'Owner O/true', 'view: b6 shows who held it and when the hold ends');

-- the message audit row
select is(public.telegram_inquiry_message_logged_v1('c0de7001-0000-4000-8000-000000000005', 907000001, 'Lloyd', 'reply', 'messenger', true, 'synthetic reply text', 'tg-inquiry-msg:synthetic-s70-key-1'),
  '{"ok": true, "inserted": true}'::jsonb, 'message: a first log inserts');
select is(public.telegram_inquiry_message_logged_v1('c0de7001-0000-4000-8000-000000000005', 907000001, 'Lloyd', 'reply', 'messenger', true, 'synthetic reply text', 'tg-inquiry-msg:synthetic-s70-key-1'),
  '{"ok": true, "inserted": false}'::jsonb, 'message: the same key again inserts nothing');
select is(public.telegram_inquiry_message_logged_v1('c0de7001-0000-4000-8000-000000000005', 907000001, 'Lloyd', 'zzz', 'messenger', true, 'x', 'tg-inquiry-msg:synthetic-s70-key-2') ->> 'reason',
  'bad_input', 'message: an unknown purpose is refused');

select * from finish();
rollback;
