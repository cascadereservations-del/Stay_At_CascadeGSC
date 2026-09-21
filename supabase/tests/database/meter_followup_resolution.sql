-- The graduated meter-mismatch alert: the exit from the block.
--
-- This one IS behavioural. A catalogue-only check would pass on a function that
-- stamped nothing, and the whole point of the release is that an unresolved
-- mismatch stops appearing in get_meter_photo_followups once someone answers
-- for it. The last-but-two assertion is the release: the block lifts.
--
-- Every fixture is created inside this transaction and disappears with the
-- closing rollback, so CI's empty baseline database (B103) is enough and no
-- production row is read.
begin;
select plan(18);

select has_function('public','resolve_meter_followup_v1',array['uuid','text'],'resolve_meter_followup_v1(uuid, text) exists');
select is_definer('public','resolve_meter_followup_v1',array['uuid','text'],'it is security definer');
select ok(has_function_privilege('authenticated','public.resolve_meter_followup_v1(uuid,text)','execute'),'authenticated staff may answer');
select ok(not has_function_privilege('anon','public.resolve_meter_followup_v1(uuid,text)','execute'),'anon may not');
select has_column('public','meter_readings','vision_resolved_by','vision_resolved_by exists');
select has_column('public','meter_readings','vision_resolved_note','vision_resolved_note exists');

-- Two properties, so that "a cleaner of some other property" is a real case.
insert into public.properties(id,name,is_active) values
 ('c1000000-0000-4000-8000-000000000001','Synthetic Meter Property',true),
 ('c1000000-0000-4000-8000-000000000002','Synthetic Other Property',true) on conflict(id) do nothing;
insert into auth.users(id) values
 ('c2000000-0000-4000-8000-000000000001'),
 ('c2000000-0000-4000-8000-000000000002') on conflict(id) do nothing;
insert into public.staff_access_profiles(user_id,role,disabled_at,sessions_revoked_after) values
 ('c2000000-0000-4000-8000-000000000001','cleaner',null,null),
 ('c2000000-0000-4000-8000-000000000002','cleaner',null,null)
on conflict(user_id) do update set role=excluded.role,disabled_at=null,sessions_revoked_after=null;
insert into public.staff_property_access(user_id,property_id) values
 ('c2000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000001'),
 ('c2000000-0000-4000-8000-000000000002','c1000000-0000-4000-8000-000000000002') on conflict do nothing;

-- Session 1: a real mismatch, the case that blocks.
insert into public.cleaning_sessions(id,submission_id,cleaner_name,property_id,cleaning_type,submitted_by_user_id)
values('c3000000-0000-4000-8000-000000000001','meterfu-session-1','Synthetic Cleaner',
       'c1000000-0000-4000-8000-000000000001','turnover','c2000000-0000-4000-8000-000000000001');
insert into public.meter_readings(id,session_id,property_id,submitted_by_user_id,electric_curr,water_curr,vision_electric,vision_verdict,vision_checked_at)
values('c4000000-0000-4000-8000-000000000001','c3000000-0000-4000-8000-000000000001',
       'c1000000-0000-4000-8000-000000000001','c2000000-0000-4000-8000-000000000001',
       3832,70.873,3814,'mismatch',now());

-- Session 2: meter photos skipped, and so no meter_readings row at all. It is
-- raised as a follow-up but can never be stamped, and must say so rather than
-- report a resolution that did not happen.
insert into public.cleaning_sessions(id,submission_id,cleaner_name,property_id,cleaning_type,submitted_by_user_id,meter_photos_skipped)
values('c3000000-0000-4000-8000-000000000002','meterfu-session-2','Synthetic Cleaner',
       'c1000000-0000-4000-8000-000000000001','turnover','c2000000-0000-4000-8000-000000000001',true);

set local role authenticated;
set local request.jwt.claims='{"sub":"c2000000-0000-4000-8000-000000000001","aal":"aal1"}';

-- The answer is checked before anything else is even looked up: a tap that says
-- nothing is not an answer, and must never clear a block.
select throws_ok(
  $$select public.resolve_meter_followup_v1('c3000000-0000-4000-8000-000000000001','   ')$$,
  '22023', null, 'a blank answer is refused');
select throws_ok(
  $$select public.resolve_meter_followup_v1('c3000000-0000-4000-8000-0000000000ff','I re-sent the photo')$$,
  '22023', null, 'an unknown session is refused');

-- The mismatch is raised before anyone answers for it.
select is(
  (select count(*) from public.get_meter_photo_followups('c1000000-0000-4000-8000-000000000001',14)
    where session_id='c3000000-0000-4000-8000-000000000001'),
  1::bigint, 'the unresolved mismatch is raised at sign-in');

select is(
  public.resolve_meter_followup_v1('c3000000-0000-4000-8000-000000000001','I re-sent the photo to Lloyd')->>'outcome',
  'resolved', 'answering it resolves it');
select is(
  public.resolve_meter_followup_v1('c3000000-0000-4000-8000-000000000002','I forgot, I photographed it today')->>'outcome',
  'no_reading_row', 'a skipped session with no reading row says so instead of claiming a resolution');

-- A second tap must not rewrite who cleared it.
select is(
  public.resolve_meter_followup_v1('c3000000-0000-4000-8000-000000000001','tapped again')->>'outcome',
  'already_resolved', 'a second tap is idempotent');

set local request.jwt.claims='{"sub":"c2000000-0000-4000-8000-000000000002","aal":"aal1"}';
select throws_ok(
  $$select public.resolve_meter_followup_v1('c3000000-0000-4000-8000-000000000001','not mine to clear')$$,
  '42501', null, 'a cleaner of another property cannot clear it');

reset role;
select isnt((select vision_resolved_at from public.meter_readings where id='c4000000-0000-4000-8000-000000000001'),
  null, 'vision_resolved_at is stamped');
select is((select vision_resolved_by from public.meter_readings where id='c4000000-0000-4000-8000-000000000001'),
  'c2000000-0000-4000-8000-000000000001'::uuid, 'it names the cleaner who answered, not the second tapper');
select is((select vision_resolved_note from public.meter_readings where id='c4000000-0000-4000-8000-000000000001'),
  'I re-sent the photo to Lloyd', 'her words are kept, and the second tap did not overwrite them');
select is((select vision_verdict from public.meter_readings where id='c4000000-0000-4000-8000-000000000001'),
  'mismatch', 'resolving does not erase the finding itself');

-- The release, in one assertion: the block lifts.
set local role authenticated;
set local request.jwt.claims='{"sub":"c2000000-0000-4000-8000-000000000001","aal":"aal1"}';
select is(
  (select count(*) from public.get_meter_photo_followups('c1000000-0000-4000-8000-000000000001',14)
    where session_id='c3000000-0000-4000-8000-000000000001'),
  0::bigint, 'once answered, the mismatch is no longer raised and no longer blocks');
reset role;

select * from finish();
rollback;
