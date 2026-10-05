-- Session 70, SPEC-41 Parts 1 and 3: release calendar_block_triage_20261005.
-- Why an Airbnb block exists (calendar_events.block_*), where a brownout notice came from (ops_notices.source), the v2 answer RPC with
-- the v1 wrapper, the note RPC, and the metrics that stop calling answered blocks "unexplained".
-- Runs as the owner (the rehearsal's service_role has no BYPASSRLS); the grants are checked below. Synthetic rows only: uids zz-blk-*,
-- telegram ids 9000000041..43, uuids e5000000-..., chat -900000041. Everything rolls back.
begin;
select plan(33);

-- the columns and the checks ----------------------------------------------------------------------------------------
select is((select count(*)::int from information_schema.columns where table_schema = 'public' and table_name = 'calendar_events'
            and column_name in ('block_reason', 'block_reason_source', 'block_note', 'block_answered_by', 'block_answered_at')), 5,
  'calendar_events has the five block columns');
select has_column('public', 'ops_notices', 'source', 'ops_notices.source exists');

-- fixtures ------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  ('e5100000-0000-4000-8000-000000000041', 'Synthetic Triage', true),
  ('e5100000-0000-4000-8000-000000000042', 'Synthetic Triage Metrics', true);
insert into auth.users(id) values
  ('e5000000-0000-4000-8000-000000000041'), ('e5000000-0000-4000-8000-000000000042'), ('e5000000-0000-4000-8000-000000000043');
insert into public.staff_access_profiles(user_id, role, telegram_user_id) values
  ('e5000000-0000-4000-8000-000000000041', 'owner', 9000000041),
  ('e5000000-0000-4000-8000-000000000042', 'cleaner', 9000000042),
  ('e5000000-0000-4000-8000-000000000043', 'finance', 9000000043);
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, recon_status, block_reason, block_reason_source) values
  ('e5100000-0000-4000-8000-000000000041', 'zz-blk-1', 'airbnb', 'blocked', '2026-11-10', '2026-11-12', 'pending', null, null),
  ('e5100000-0000-4000-8000-000000000041', 'zz-blk-2', 'airbnb', 'blocked', '2026-11-13', '2026-11-15', 'pending', null, null),
  ('e5100000-0000-4000-8000-000000000041', 'zz-blk-3', 'airbnb', 'blocked', '2026-11-16', '2026-11-18', 'admin_block', 'maintenance', 'assumed'),
  ('e5100000-0000-4000-8000-000000000041', 'zz-blk-4', 'airbnb', 'blocked', '2026-11-19', '2026-11-21', 'pending', null, null),
  ('e5100000-0000-4000-8000-000000000041', 'zz-blk-5', 'airbnb', 'blocked', '2026-11-22', '2026-11-24', 'pending', null, null),
  ('e5100000-0000-4000-8000-000000000041', 'zz-blk-6', 'airbnb', 'blocked', '2026-11-25', '2026-11-27', 'pending', null, null);

select throws_ok($$update public.calendar_events set block_reason = 'holiday' where uid = 'zz-blk-6'$$, '23514', null,
  'block_reason refuses a value outside the list');
select throws_ok($$update public.calendar_events set block_reason_source = 'robot' where uid = 'zz-blk-6'$$, '23514', null,
  'block_reason_source refuses a value outside the list');
select throws_ok($$update public.calendar_events set block_note = repeat('x', 201) where uid = 'zz-blk-6'$$, '23514', null,
  'block_note is capped at 200 characters');

-- ops_notices.source ----------------------------------------------------------------------------------------------------
select throws_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date, source)
  values ('e5100000-0000-4000-8000-000000000041', 'brownout', 'zz source test', '2026-11-30', 'meralco')$$, '23514', null,
  'ops_notices.source refuses a provider that is not socoteco, ngcp or staff');
select lives_ok($$insert into public.ops_notices(property_id, notice_type, title, effective_date, source)
  values ('e5100000-0000-4000-8000-000000000041', 'brownout', 'zz NGCP grid interruption', '2026-11-30', 'ngcp')$$,
  'a brownout notice with source ngcp is accepted');
-- Forward check 6 (no brownout notice with a null source), and the two real notices of the live board (present in a restore of production).
select is((select count(*)::int from public.ops_notices where notice_type = 'brownout' and source is null), 0,
  'no brownout notice has a null source: the backfill covered every one');
select is((select count(*)::int from public.ops_notices where id in ('c560cbbf-4af8-4f2a-83a5-900d0e86c154', '94f98e45-4ecf-4dd9-8adc-d644276dcf62') and source = 'socoteco'),
  (select count(*)::int from public.ops_notices where id in ('c560cbbf-4af8-4f2a-83a5-900d0e86c154', '94f98e45-4ecf-4dd9-8adc-d644276dcf62')),
  'the hand-entered SOCOTECO notice and the power-watch notice both read socoteco (vacuous on a database without them)');

-- grants ----------------------------------------------------------------------------------------------------------------
select ok(has_function_privilege('service_role', 'public.telegram_answer_calendar_block_v2(bigint,text,text)', 'execute')
      and has_function_privilege('service_role', 'public.telegram_note_calendar_block_v1(bigint,text,text)', 'execute')
      and has_function_privilege('service_role', 'public.telegram_answer_calendar_block_v1(bigint,text,text)', 'execute'),
  'service_role can execute v2, the note rpc and the v1 wrapper');
select ok(not has_function_privilege('authenticated', 'public.telegram_answer_calendar_block_v2(bigint,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.telegram_answer_calendar_block_v2(bigint,text,text)', 'execute')
      and not has_function_privilege('authenticated', 'public.telegram_note_calendar_block_v1(bigint,text,text)', 'execute')
      and not has_function_privilege('anon', 'public.telegram_note_calendar_block_v1(bigint,text,text)', 'execute'),
  'anon and authenticated cannot execute v2 or the note rpc');
select ok(pg_get_functiondef('public.telegram_answer_calendar_block_v1(bigint,text,text)'::regprocedure) like '%telegram_answer_calendar_block_v2%',
  'v1 is a wrapper over v2');

-- v2 --------------------------------------------------------------------------------------------------------------------
select is(public.telegram_answer_calendar_block_v2(4242424242, 'zz-blk-1', 'maint')->>'reason', 'unmapped_telegram_user',
  'an unmapped Telegram id changes nothing');
select is(public.telegram_answer_calendar_block_v2(9000000042, 'zz-blk-1', 'maint')->>'recon_status', 'admin_block',
  'a mapped cleaner may answer maint: the row becomes admin_block');
select is((select block_reason || '/' || block_reason_source || '/' || (block_answered_by = 'e5000000-0000-4000-8000-000000000042')::text || '/' || (block_answered_at is not null)::text
             from public.calendar_events where uid = 'zz-blk-1'),
  'maintenance/staff/true/true', 'the row carries the reason, the source staff, who and when');
select is(public.telegram_answer_calendar_block_v2(9000000042, 'zz-blk-2', 'unblock')->>'reason', 'not_authorized',
  'the same cleaner may not answer unblock');
select is((select recon_status || '/' || coalesce(block_reason, 'none') from public.calendar_events where uid = 'zz-blk-2'), 'pending/none',
  'and that row is unchanged');
select is(public.telegram_answer_calendar_block_v2(9000000043, 'zz-blk-2', 'maint')->>'reason', 'not_authorized',
  'a finance role may not label the calendar');
select is(public.telegram_answer_calendar_block_v2(9000000041, 'zz-blk-3', 'owner')->>'outcome', 'owner',
  'an assumed row can be answered, here owner use by the owner');
select is((select block_reason || '/' || block_reason_source from public.calendar_events where uid = 'zz-blk-3'), 'owner_use/staff',
  'owner maps to owner_use and the source moves from assumed to staff');
select is(public.telegram_answer_calendar_block_v2(9000000041, 'zz-blk-1', 'owner')->>'reason', 'not_pending',
  'a staff answer is never overwritten');
select throws_ok($$select public.telegram_answer_calendar_block_v2(9000000041, 'zz-blk-2', 'nope')$$, '22023', null,
  'an unknown answer is refused');
select is(public.telegram_answer_calendar_block_v2(9000000041, 'zz-blk-2', 'direct')->>'recon_status', 'skipped',
  'direct by the owner is stored as skipped');

-- v1 wrapper ----------------------------------------------------------------------------------------------------------
select is(public.telegram_answer_calendar_block_v1(9000000041, 'zz-blk-4', 'maint')->>'recon_status', 'admin_block',
  'v1 maint still works through the wrapper');
select is((select block_reason from public.calendar_events where uid = 'zz-blk-4'), 'maintenance', 'and writes the reason maintenance');
select throws_ok($$select public.telegram_answer_calendar_block_v1(9000000041, 'zz-blk-5', 'brownout')$$, '22023', null,
  'v1 keeps its own three-answer check');

-- the note rpc ---------------------------------------------------------------------------------------------------------
select is(public.telegram_answer_calendar_block_v2(9000000041, 'zz-blk-5', 'brownout')->>'outcome', 'brownout', 'the owner taps Brownout on another block');
select is(public.telegram_note_calendar_block_v1(9000000042, 'zz-blk-5', 'NGCP 8 hours')->>'reason', 'not_yours',
  'a different person cannot add the detail');
select is(public.telegram_note_calendar_block_v1(9000000041, 'zz-blk-4', 'some detail')->>'reason', 'not_yours',
  'a maintenance answer takes no detail');
select is(public.telegram_note_calendar_block_v1(9000000041, 'zz-blk-5', '   ' || repeat('n', 250))->>'ok', 'true',
  'the person who answered adds the detail');
select is((select char_length(block_note)::text || '/' || left(block_note, 1) from public.calendar_events where uid = 'zz-blk-5'), '200/n',
  'it is trimmed and kept to 200 characters');

-- the follow-up questions ride the existing pending kind ---------------------------------------------------------------
select lives_ok($$insert into public.telegram_pending(chat_id, kind, payload)
  values (-900000041, 'awaiting_reply', '{"flow":"block_brownout","from_id":9000000041,"uid":"x"}')$$,
  'an awaiting_reply row for block_brownout is accepted: no new pending kind is needed');

-- the metrics: only unexplained blocks are "unexplained" -----------------------------------------------------------------
insert into auth.users(id) values ('e5000000-0000-4000-8000-000000000044');
insert into public.staff_access_profiles(user_id, role) values ('e5000000-0000-4000-8000-000000000044', 'owner');
insert into public.app_settings(key, value) values ('operating_start_date', '"2026-01-01"'::jsonb) on conflict (key) do update set value = excluded.value;
insert into public.calendar_events(property_id, uid, source, status, checkin_date, checkout_date, recon_status) values
  ('e5100000-0000-4000-8000-000000000042', 'zz-m-pending', 'airbnb', 'blocked', '2026-02-05', '2026-02-07', 'pending'),
  ('e5100000-0000-4000-8000-000000000042', 'zz-m-answered', 'airbnb', 'blocked', '2026-02-10', '2026-02-12', 'admin_block'),
  ('e5100000-0000-4000-8000-000000000042', 'brownout:2026-02-15', 'manual', 'blocked', '2026-02-15', '2026-02-16', 'admin_block');
select set_config('request.jwt.claims', json_build_object('sub', 'e5000000-0000-4000-8000-000000000044', 'role', 'authenticated', 'aal', 'aal2', 'iat', extract(epoch from now())::bigint)::text, true);
select set_config('role', 'authenticated', true);
select is((public.get_hospitality_metrics_v1('e5100000-0000-4000-8000-000000000042', '2026-02-01', '2026-03-01')->>'blockedNights'), '2',
  'one pending 2-night block, one answered 2-night block and one brownout row: only the pending nights are unexplained');
reset role;

select * from finish();
rollback;
