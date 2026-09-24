-- Session 49: release verifier_v7_20260925 (D-225, D-227, D-232, D-235, D-236).
-- One pair per rule: the case that must fire, and the neighbouring case that must stay silent.
-- Every fixture lives inside this transaction and goes with the closing rollback.

begin;
select plan(31);

insert into public.properties(id, name, is_active) values ('e1000000-0000-4000-8000-000000000049', 'Synthetic Verifier 49', true);
-- verifier_findings keys carry no property; clear the checks this suite asserts on (a production restore).
delete from public.verifier_findings where check_id in ('V7', 'V7b', 'V13');

-- Reservations (the e-mail side) and calendar rows (the Airbnb side). "Now" is 10 Oct 10:00 Manila.
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_name, checkin_date, checkout_date, payout_amount)
values
  ('e7000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000049', 'HMSYNTH701', 'confirmed', 'Synthetic One',   '2026-10-12', '2026-10-13', 1929),
  ('e7000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000049', 'HMSYNTH702', 'completed', 'Synthetic Two',   '2026-10-08', '2026-10-09', null),
  ('e7000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000049', 'HMSYNTH703', 'cancelled', 'Synthetic Three', '2026-10-20', '2026-10-21', null),
  ('e7000000-0000-4000-8000-000000000006', 'e1000000-0000-4000-8000-000000000049', 'HMSYNTH706', 'confirmed', 'Synthetic Six',   '2026-10-15', '2026-10-16', null);

insert into public.calendar_events(id, property_id, uid, source, status, checkin_date, checkout_date, linked_reservation_id, raw_description, created_at)
values
  -- linked, one night apart, both confirmed: V7, auto-corrected
  ('e8000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000049', 'synth-v7-1@airbnb.com', 'airbnb', 'confirmed', '2026-10-12', '2026-10-14',
   'e7000000-0000-4000-8000-000000000001', 'Reservation URL: https://www.airbnb.com/hosting/reservations/details/HMSYNTH701', '2026-10-01T00:00:00Z'),
  -- linked to a completed reservation, dates differ: V7 stays open, nothing is written
  ('e8000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000049', 'synth-v7-2@airbnb.com', 'airbnb', 'confirmed', '2026-10-08', '2026-10-10',
   'e7000000-0000-4000-8000-000000000002', 'Reservation URL: https://www.airbnb.com/hosting/reservations/details/HMSYNTH702', '2026-10-01T00:00:00Z'),
  -- linked to a cancelled reservation: silent
  ('e8000000-0000-4000-8000-000000000003', 'e1000000-0000-4000-8000-000000000049', 'synth-v7-3@airbnb.com', 'airbnb', 'confirmed', '2026-10-20', '2026-10-23',
   'e7000000-0000-4000-8000-000000000003', 'Reservation URL: https://www.airbnb.com/hosting/reservations/details/HMSYNTH703', '2026-10-01T00:00:00Z'),
  -- unlinked, with a code, two days old: V7b
  ('e8000000-0000-4000-8000-000000000004', 'e1000000-0000-4000-8000-000000000049', 'synth-v7-4@airbnb.com', 'airbnb', 'confirmed', '2026-10-25', '2026-10-26',
   null, 'Reservation URL: https://www.airbnb.com/hosting/reservations/details/HMSYNTH704', '2026-10-08T00:00:00Z'),
  -- unlinked, with a code, two hours old: not yet
  ('e8000000-0000-4000-8000-000000000005', 'e1000000-0000-4000-8000-000000000049', 'synth-v7-5@airbnb.com', 'airbnb', 'confirmed', '2026-10-27', '2026-10-28',
   null, 'Reservation URL: https://www.airbnb.com/hosting/reservations/details/HMSYNTH705', '2026-10-10T00:00:00Z'),
  -- linked, same dates: silent
  ('e8000000-0000-4000-8000-000000000006', 'e1000000-0000-4000-8000-000000000049', 'synth-v7-6@airbnb.com', 'airbnb', 'confirmed', '2026-10-15', '2026-10-16',
   'e7000000-0000-4000-8000-000000000006', 'Reservation URL: https://www.airbnb.com/hosting/reservations/details/HMSYNTH706', '2026-10-01T00:00:00Z'),
  -- unlinked, old, but the description carries no code (the truncated shape): silent
  ('e8000000-0000-4000-8000-000000000007', 'e1000000-0000-4000-8000-000000000049', 'synth-v7-7@airbnb.com', 'airbnb', 'confirmed', '2026-10-29', '2026-10-30',
   null, 'Reservation URL: https://www.airbnb.com/hosting/reservations/de', '2026-10-01T00:00:00Z'),
  -- Airbnb blocks with nothing behind them (D-236)
  ('e8000000-0000-4000-8000-000000000008', 'e1000000-0000-4000-8000-000000000049', 'synth-block-1@airbnb.com', 'airbnb', 'blocked', '2026-11-01', '2026-11-03',
   null, null, '2026-10-01T00:00:00Z'),
  ('e8000000-0000-4000-8000-000000000009', 'e1000000-0000-4000-8000-000000000049', 'synth-block-2@airbnb.com', 'airbnb', 'blocked', '2026-11-05', '2026-11-06',
   null, null, '2026-10-01T00:00:00Z');

create temp table run49 as
  select e from jsonb_array_elements(
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000049', 'hourly', '2026-10-10T02:00:00Z')->'found') e
   where e->>'check_id' in ('V7', 'V7b');

-- V7 ---------------------------------------------------------------------------------
select is((select count(*) from run49 where e->>'key' = 'V7:HMSYNTH701'), 1::bigint,
  'a linked pair one night apart is one V7 finding');
select is((select e->>'severity' from run49 where e->>'key' = 'V7:HMSYNTH701'), 'yellow',
  'V7 is yellow: the calendar is primary and the fix is automatic (D-235)');
select ok((select e->'detail' @> '{"email_from": "2026-10-12", "email_to": "2026-10-13", "calendar_from": "2026-10-12", "calendar_to": "2026-10-14", "auto_safe": true}'::jsonb
             from run49 where e->>'key' = 'V7:HMSYNTH701'),
  'both date pairs are in the detail, and both-confirmed is auto_safe');
select ok(not exists (select 1 from run49 e0, jsonb_object_keys(e0.e->'detail') k where e0.e->>'key' = 'V7:HMSYNTH701' and k in ('ran_at', 'synced_at', 'updated_at')),
  'the detail carries no timestamp, so an acknowledgement holds');
select is((select e->'detail'->>'auto_safe' from run49 where e->>'key' = 'V7:HMSYNTH702'), 'false',
  'a completed reservation is found but never auto-corrected');
select is((select count(*) from run49 where e->>'key' = 'V7:HMSYNTH703'), 0::bigint,
  'a cancelled reservation raises nothing');
select is((select count(*) from run49 where e->>'key' = 'V7:HMSYNTH706'), 0::bigint,
  'a linked pair with the same dates raises nothing');
select is((select count(*) from run49 where e->>'check_id' = 'V7' and e->'detail'->>'event' in
             ('e8000000-0000-4000-8000-000000000004', 'e8000000-0000-4000-8000-000000000005', 'e8000000-0000-4000-8000-000000000007')), 0::bigint,
  'an unlinked row is never a V7: the link is the gate');

-- V7b --------------------------------------------------------------------------------
select is((select count(*) from run49 where e->>'key' = 'V7b:synth-v7-4@airbnb.com'), 1::bigint,
  'a coded Airbnb stay with no reservation after 24 hours is V7b');
select is((select e->'detail'->>'code' from run49 where e->>'key' = 'V7b:synth-v7-4@airbnb.com'), 'HMSYNTH704',
  'V7b names the confirmation code from the feed');
select is((select count(*) from run49 where e->>'key' in ('V7b:synth-v7-5@airbnb.com', 'V7b:synth-v7-7@airbnb.com')), 0::bigint,
  'not before 24 hours, and not without a code');

-- Auto-resolution 3 --------------------------------------------------------------------
select set_config('cascade.v7_apply1',
  public.apply_verifier_run_v1('hourly',
    (select coalesce(jsonb_agg(e), '[]'::jsonb) from run49),
    '2026-10-10T02:00:00Z')::text, true);

select is((select checkin_date::text || ' ' || checkout_date::text || ' ' || nights::text
             from public.airbnb_reservations where id = 'e7000000-0000-4000-8000-000000000001'),
  '2026-10-12 2026-10-14 2', 'the reservation takes the calendar''s dates, and its generated nights follow');
select is((select payout_amount from public.airbnb_reservations where id = 'e7000000-0000-4000-8000-000000000001'), 1929::numeric,
  'money is never rewritten from the calendar');
select is((select status || ' ' || resolved_by from public.verifier_findings where key = 'V7:HMSYNTH701'), 'resolved auto',
  'the finding closes itself');
select ok((select detail->>'auto' like '%Oct 12 to Oct 13 became Oct 12 to Oct 14%' from public.verifier_findings where key = 'V7:HMSYNTH701'),
  'and says what it changed, in dates a person reads');
select ok((select current_setting('cascade.v7_apply1')::jsonb->'resolved' @> '[{"key": "V7:HMSYNTH701", "title": "Reservation dates corrected from the Airbnb calendar", "auto": true}]'::jsonb),
  'the card footer gets a sentence: dates corrected, closed itself');
select ok(not (current_setting('cascade.v7_apply1')::jsonb->'new' @> '[{"key": "V7:HMSYNTH701"}]'::jsonb),
  'a corrected mismatch is never announced as new');
select is((select status from public.verifier_findings where key = 'V7:HMSYNTH702'), 'open',
  'the completed pair stays open');
select is((select checkout_date from public.airbnb_reservations where id = 'e7000000-0000-4000-8000-000000000002'), '2026-10-09'::date,
  'and its reservation is untouched');

-- V7b task opens once, and closes when the link appears ------------------------------------
select is((select count(*) from public.follow_up_tasks where idempotency_key = 'system:airbnb_unmatched:synth-v7-4@airbnb.com' and status = 'open'), 1::bigint,
  'V7b opens one Follow-ups task');
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, checkin_date, checkout_date)
values ('e7000000-0000-4000-8000-000000000004', 'e1000000-0000-4000-8000-000000000049', 'HMSYNTH704', 'confirmed', '2026-10-25', '2026-10-26');
update public.calendar_events set linked_reservation_id = 'e7000000-0000-4000-8000-000000000004', recon_status = 'matched'
 where id = 'e8000000-0000-4000-8000-000000000004';
select public.apply_verifier_run_v1('hourly',
  public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000049', 'hourly', '2026-10-10T03:00:00Z')->'found',
  '2026-10-10T03:00:00Z');
select is((select status from public.verifier_findings where key = 'V7b:synth-v7-4@airbnb.com'), 'resolved',
  'once linked, V7b resolves');
select is((select status from public.follow_up_tasks where idempotency_key = 'system:airbnb_unmatched:synth-v7-4@airbnb.com'), 'done',
  'and its task closes itself');
select is((select status from public.verifier_findings where key = 'V7:HMSYNTH701'), 'resolved',
  'the corrected pair does not come back the next hour');

-- checkouts_cleaned is yellow again (D-232) ------------------------------------------------
insert into public.admin_health_check_runs(property_id, check_key, label, status, count, detail, ran_at)
values ('e1000000-0000-4000-8000-000000000049', 'checkouts_cleaned', 'Checkouts (90 days) followed by a cleaning', 'warn', 1,
        '[{"code": "HMSYNTH701", "guest": "Synthetic One", "checkout": "2026-10-09"}]'::jsonb, '2026-10-10T01:00:00Z');
select is((select e->>'severity' from jsonb_array_elements(
    public.run_system_verifier_v1('e1000000-0000-4000-8000-000000000049', 'daily', '2026-10-10T02:00:00Z')->'found') e
   where e->>'key' = 'V10:checkouts_cleaned'), 'yellow',
  'a checkout yesterday with no cleaning is yellow: missed-cleaning-alert owns it in OPS');

-- V13 resolves in either scope when the Edge Function stops raising it ------------------------
select public.apply_verifier_run_v1('hourly',
  '[{"key": "V13", "check_id": "V13", "severity": "red", "title": "Model budget nearly used up", "detail": {"left_pct": 15}}]'::jsonb,
  '2026-10-10T04:00:00Z');
select public.apply_verifier_run_v1('daily', '[]'::jsonb, '2026-10-10T05:00:00Z');
select is((select status from public.verifier_findings where key = 'V13'), 'resolved',
  'V13 is in the scope arrays, so it closes when it is no longer seen');

-- telegram_answer_calendar_block_v1 (D-236) ------------------------------------------------
insert into auth.users(id) values ('e2000000-0000-4000-8000-000000000491'), ('e2000000-0000-4000-8000-000000000492') on conflict(id) do nothing;
insert into public.staff_access_profiles(user_id, role, telegram_user_id) values
  ('e2000000-0000-4000-8000-000000000491', 'owner', 994901),
  ('e2000000-0000-4000-8000-000000000492', 'finance', 994902)
on conflict(user_id) do update set role = excluded.role, telegram_user_id = excluded.telegram_user_id, disabled_at = null;

select is(public.telegram_answer_calendar_block_v1(994902, 'synth-block-1@airbnb.com', 'maint')->>'reason', 'not_authorized',
  'finance cannot answer for the owner''s calendar');
select is(public.telegram_answer_calendar_block_v1(4242424242, 'synth-block-1@airbnb.com', 'maint')->>'reason', 'unmapped_telegram_user',
  'a stranger changes nothing');
select is(public.telegram_answer_calendar_block_v1(994901, 'synth-block-1@airbnb.com', 'maint')->>'recon_status', 'admin_block',
  'maintenance or owner use is stored as admin_block');
select is(public.telegram_answer_calendar_block_v1(994901, 'synth-block-2@airbnb.com', 'direct')->>'recon_status', 'skipped',
  'a direct booking to come is stored as skipped');
select is(public.telegram_answer_calendar_block_v1(994901, 'synth-block-1@airbnb.com', 'unblock')->>'reason', 'not_pending',
  'an answered block is never answered twice');
select throws_ok($$select public.telegram_answer_calendar_block_v1(994901, 'synth-block-2@airbnb.com', 'whatever')$$, '22023', null,
  'an unknown answer is refused');

select * from finish();
rollback;
