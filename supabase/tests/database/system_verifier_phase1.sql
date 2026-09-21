-- SPEC-11 phase 1: the checks, and the thing that decides what to say about them.
--
-- Behavioural, not a catalogue check. A verifier that returns nothing would
-- pass every catalogue assertion ever written and would also be completely
-- useless, so the important half of this file is: a real overlap is found once,
-- is not announced twice, IS announced again after a day, announces its own
-- resolution when it goes away, and an hourly run never resolves a finding that
-- only the daily run looks for.
--
-- Every fixture is created inside this transaction and disappears with the
-- closing rollback, so CI's empty baseline database (B103) is enough and no
-- production row is read.
--
-- The clock is passed in rather than waited for: p_now is a parameter of both
-- functions precisely so a 25-hour reminder can be tested in a millisecond.
begin;
select plan(32);

-- Catalogue -------------------------------------------------------------------
select has_table('public', 'verifier_findings', 'the findings table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.verifier_findings'::regclass),
  'RLS is on: findings name guests and are not world-readable');
select has_function('public', 'run_system_verifier_v1', array['uuid','text','timestamptz'], 'the checks function exists');
select has_function('public', 'apply_verifier_run_v1', array['text','jsonb','timestamptz'], 'the apply function exists');
select has_function('public', 'telegram_ack_verifier_finding_v1', array['bigint','text'], 'the ack function exists');
select is_definer('public', 'run_system_verifier_v1', array['uuid','text','timestamptz'], 'the checks function is security definer');
select ok(has_function_privilege('service_role', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute')
      and not has_function_privilege('anon', 'public.run_system_verifier_v1(uuid,text,timestamptz)', 'execute'),
  'only service_role may run the checks');
select ok(has_function_privilege('service_role', 'public.apply_verifier_run_v1(text,jsonb,timestamptz)', 'execute')
      and not has_function_privilege('authenticated', 'public.apply_verifier_run_v1(text,jsonb,timestamptz)', 'execute'),
  'only service_role may record a run');
select is((select count(*) from public.job_heartbeats where job_name in ('system-verifier-hourly','system-verifier-daily')),
  2::bigint, 'both heartbeat rows are seeded, because record_job_heartbeat refuses an unseeded name');
select throws_ok(
  $$select public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001','weekly')$$,
  '22023', null, 'an unknown scope is refused rather than quietly treated as hourly');

-- Fixtures --------------------------------------------------------------------
insert into public.properties(id, name, is_active)
values ('d1000000-0000-4000-8000-000000000001', 'Synthetic Verifier Property', true) on conflict(id) do nothing;

-- A Concierge on auto, so V11 is quiet for most of this file. Migration
-- 20260911000000 seeds concierge_mode as "suggest", which is exactly why the
-- first CI run of this file failed: V11 fired on every assertion that counted
-- findings. app_settings.value is JSONB, so the value really is the quoted
-- string - that is what the check had to learn to unwrap.
insert into public.app_settings(key, value) values ('concierge_mode', '"auto"'::jsonb)
on conflict (key) do update set value = '"auto"'::jsonb;

-- A healthy Airbnb feed, so V12 is quiet for most of this file. Without this
-- row every single run below would carry an extra red finding.
insert into public.calendar_sync_log(property_id, source, status, event_count, synced_at)
values ('d1000000-0000-4000-8000-000000000001', 'airbnb', 'ok', 11, '2026-10-01T09:00:00Z');

-- Two stays that overlap on 2026-10-21. This is V1.
insert into public.calendar_events(id, property_id, uid, source, status, guest_name, checkin_date, checkout_date)
values ('d2000000-0000-4000-8000-00000000000a', 'd1000000-0000-4000-8000-000000000001', 'airbnb:HMTEST1', 'airbnb', 'confirmed', 'Ana R.', '2026-10-20', '2026-10-22'),
       ('d2000000-0000-4000-8000-00000000000b', 'd1000000-0000-4000-8000-000000000001', 'airbnb:HMTEST2', 'airbnb', 'confirmed', 'Ben C.', '2026-10-21', '2026-10-24');

-- Run 1: the overlap is found, once, with both guests named.
select set_config('cascade.v_run1',
  public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-01T10:00:00Z')::text, true);
select is(
  (select count(*) from jsonb_array_elements(current_setting('cascade.v_run1')::jsonb->'found') e
    where e->>'check_id' = 'V1'),
  1::bigint, 'the overlapping pair is one finding, not two');
select is(
  (select e->>'severity' from jsonb_array_elements(current_setting('cascade.v_run1')::jsonb->'found') e where e->>'check_id' = 'V1'),
  'red', 'an overlap is red: a guest is at the door');
select is(
  (select count(*) from jsonb_array_elements(current_setting('cascade.v_run1')::jsonb->'found') e),
  1::bigint, 'and nothing else fires on an otherwise clean property');

-- Applying it announces it exactly once.
select set_config('cascade.v_apply1',
  public.apply_verifier_run_v1('hourly', current_setting('cascade.v_run1')::jsonb->'found', '2026-10-01T10:00:00Z')::text, true);
select is((select jsonb_array_length(current_setting('cascade.v_apply1')::jsonb->'new')), 1,
  'the first run announces it');
select is((select jsonb_array_length(current_setting('cascade.v_apply1')::jsonb->'remind')), 0,
  'and does not also call it a reminder');

-- An hour later, the same overlap is still there and nobody is told again.
select set_config('cascade.v_apply2',
  public.apply_verifier_run_v1('hourly',
    public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-01T11:00:00Z')->'found',
    '2026-10-01T11:00:00Z')::text, true);
select is((select jsonb_array_length(current_setting('cascade.v_apply2')::jsonb->'new')
        + jsonb_array_length(current_setting('cascade.v_apply2')::jsonb->'remind')
        + jsonb_array_length(current_setting('cascade.v_apply2')::jsonb->'resolved')), 0,
  'an hour later it says nothing at all: alert once, not every hour');

-- A day later it is worth repeating, because a red finding nobody has fixed in
-- 24 hours needs saying again.
select set_config('cascade.v_apply3',
  public.apply_verifier_run_v1('hourly',
    public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-02T11:00:00Z')->'found',
    '2026-10-02T11:00:00Z')::text, true);
select is((select jsonb_array_length(current_setting('cascade.v_apply3')::jsonb->'remind')), 1,
  'after 25 hours the red finding is reminded about');
select is((select jsonb_array_length(current_setting('cascade.v_apply3')::jsonb->'new')), 0,
  'and it is a reminder, not a new alert');

-- The ack stops the reminding without resolving anything.
insert into auth.users(id) values ('d3000000-0000-4000-8000-000000000001') on conflict(id) do nothing;
insert into public.staff_access_profiles(user_id, role, telegram_user_id)
values ('d3000000-0000-4000-8000-000000000001', 'owner', 991001)
on conflict(user_id) do update set role = 'owner', telegram_user_id = 991001, disabled_at = null;

select is(public.telegram_ack_verifier_finding_v1(991001,
    (select key from public.verifier_findings where check_id = 'V1'))->>'ok',
  'true', 'the owner can say it is known');
select is(public.telegram_ack_verifier_finding_v1(4242424242, 'V1:whatever')->>'reason',
  'unmapped_telegram_user', 'a stranger tapping the button changes nothing');
select set_config('cascade.v_apply4',
  public.apply_verifier_run_v1('hourly',
    public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-05T11:00:00Z')->'found',
    '2026-10-05T11:00:00Z')::text, true);
select is((select jsonb_array_length(current_setting('cascade.v_apply4')::jsonb->'remind')), 0,
  'once acknowledged it stops reminding, even days later');

-- Fixed: the finding announces its own resolution.
delete from public.calendar_events where id = 'd2000000-0000-4000-8000-00000000000b';
select set_config('cascade.v_apply5',
  public.apply_verifier_run_v1('hourly',
    public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-06T11:00:00Z')->'found',
    '2026-10-06T11:00:00Z')::text, true);
select is((select jsonb_array_length(current_setting('cascade.v_apply5')::jsonb->'resolved')), 1,
  'when the overlap goes, it says so - an acknowledged finding still resolves');
select is((select status from public.verifier_findings where check_id = 'V1'), 'resolved',
  'and the row says resolved');

-- The scope rule: an HOURLY run must never resolve a DAILY finding.
insert into public.guests(id, property_id, name)
values ('d4000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Carla D.') on conflict(id) do nothing;
insert into public.booking_inquiries(id, property_id, guest_id, guest_name, guest_email, checkin_date, checkout_date, status)
values ('d5000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'd4000000-0000-4000-8000-000000000001',
        'Carla D.', 'carla@example.com', '2026-10-08', '2026-10-10', 'confirmed');
-- It also needs its calendar block, or V2 (red) fires alongside V6 and muddies
-- the assertion. That is the check doing its job, not a test artefact.
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date)
values ('d1000000-0000-4000-8000-000000000001', 'direct:d5000000-0000-4000-8000-000000000001', 'direct', 'confirmed', 'Carla D.', '2026-10-08', '2026-10-10');

select set_config('cascade.v_daily',
  public.apply_verifier_run_v1('daily',
    public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'daily', '2026-10-06T23:45:00Z')->'found',
    '2026-10-06T23:45:00Z')::text, true);
select is((select count(*) from public.verifier_findings where check_id = 'V6' and status = 'open'),
  1::bigint, 'the daily run raises the missing-ID finding');

select set_config('cascade.v_hourly_after',
  public.apply_verifier_run_v1('hourly',
    public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-07T00:35:00Z')->'found',
    '2026-10-07T00:35:00Z')::text, true);
select is((select status from public.verifier_findings where check_id = 'V6'), 'open',
  'an hourly run does NOT resolve it: it never looked for it');

-- Auto-resolution: a ghost hold whose booking already expired is cancelled the
-- same way expire_booking_holds_v1 would have, and says so.
insert into public.booking_inquiries(id, property_id, guest_name, guest_email, checkin_date, checkout_date, status)
values ('d5000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001',
        'Dead Booking', 'dead@example.com', '2026-11-01', '2026-11-03', 'expired');
insert into public.calendar_events(id, property_id, uid, source, status, guest_name, checkin_date, checkout_date)
values ('d2000000-0000-4000-8000-00000000000c', 'd1000000-0000-4000-8000-000000000001',
        'direct:d5000000-0000-4000-8000-000000000002', 'direct', 'blocked', 'Dead Booking', '2026-11-01', '2026-11-03');

select set_config('cascade.v_auto',
  public.apply_verifier_run_v1('hourly',
    public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-08T10:00:00Z')->'found',
    '2026-10-08T10:00:00Z')::text, true);
select is((select status from public.calendar_events where id = 'd2000000-0000-4000-8000-00000000000c'),
  'cancelled', 'the ghost hold is released, freeing the nights');
select is((select resolved_by from public.verifier_findings where check_id = 'V3'), 'auto',
  'and the finding records that a machine did it, not a person');
select ok((select detail ? 'auto' from public.verifier_findings where check_id = 'V3'),
  'the card has a sentence explaining what was done');

-- A hold with NO booking behind it at all is never touched: somebody may have
-- blocked that date by hand.
insert into public.calendar_events(id, property_id, uid, source, status, guest_name, checkin_date, checkout_date)
values ('d2000000-0000-4000-8000-00000000000d', 'd1000000-0000-4000-8000-000000000001',
        'direct:00000000-0000-4000-8000-00000000dead', 'direct', 'blocked', 'Hand-blocked', '2026-12-01', '2026-12-03');
select set_config('cascade.v_manual',
  public.apply_verifier_run_v1('hourly',
    public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-09T10:00:00Z')->'found',
    '2026-10-09T10:00:00Z')::text, true);
select is((select status from public.calendar_events where id = 'd2000000-0000-4000-8000-00000000000d'),
  'blocked', 'a hold with no booking behind it is left alone for a person to judge');

-- V12: the feed going quiet is red.
delete from public.calendar_sync_log where property_id = 'd1000000-0000-4000-8000-000000000001';
select is(
  (select e->>'severity' from jsonb_array_elements(
      public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-10T10:00:00Z')->'found') e
    where e->>'check_id' = 'V12'),
  'red', 'a silent Airbnb feed is red');

-- V11, both ways. This pair exists because the check was WRONG the first time:
-- app_settings.value is jsonb, so a Concierge on auto read as the quoted string
-- "auto", never equalled 'auto', and would have raised a permanent yellow that
-- nothing could ever clear. Asserting only that it fires would not have caught
-- that; asserting that it stays quiet on a healthy setting is the half that did.
select is(
  (select count(*) from jsonb_array_elements(
      public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-10T10:00:00Z')->'found') e
    where e->>'check_id' = 'V11'),
  0::bigint, 'a Concierge on auto raises nothing, quotes and all');

update public.app_settings set value = '"suggest"'::jsonb, updated_at = '2026-10-10T06:00:00Z'
 where key = 'concierge_mode';
select is(
  (select e->>'title' from jsonb_array_elements(
      public.run_system_verifier_v1('d1000000-0000-4000-8000-000000000001', 'hourly', '2026-10-10T10:00:00Z')->'found') e
    where e->>'check_id' = 'V11'),
  'Concierge is not on auto', 'and four hours off auto does raise it');

select * from finish();
rollback;
