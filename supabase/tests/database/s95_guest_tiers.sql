-- Session 95 (lane SQL): release s95_guest_tiers_20261028. The tier rule (guest_tier_v1), ordinals and the benefits line, refresh_guest_stats (DIRECT: mirrors skipped, upcoming stays
-- not counted for the tier, one history row per change), the manual tier (admin_set_guest_tier_v1: wins, clears, refused for a cleaner and anon), staff_guest_card_v1 tier keys,
-- the CHECK constraints, refresh_all_guest_tiers_v1 and its heartbeat. Synthetic fixtures only (uuids f9500000-...); every lookup is scoped to them because a real backup holds
-- real rows. Refusals are tested by calling as the refused role. Grants are not asserted (a --no-acl rehearsal carries none); the release forward checks prove them.
-- Everything rolls back.
begin;
select plan(77);

grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_active(text[]) to authenticated, service_role;
grant execute on function public.admin_set_guest_tier_v1(uuid, text, text) to authenticated;

-- fixtures: admin (a3), cleaner (a1); guests c1 (the main walk), c2 (20 nights in one stay), c3 (10 nights in one stay), c4 (no stays)
insert into auth.users(id) values ('f9500000-0000-4000-8000-0000000000a1'), ('f9500000-0000-4000-8000-0000000000a3');
insert into public.staff_access_profiles(user_id, role) values
  ('f9500000-0000-4000-8000-0000000000a1', 'cleaner'), ('f9500000-0000-4000-8000-0000000000a3', 'admin');
insert into public.properties(id, name, is_active) values ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Cascade Hideaway', true) on conflict (id) do nothing;
insert into public.guests(id, property_id, name) values
  ('f9500000-0000-4000-8000-0000000000c1', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S95 Walk'),
  ('f9500000-0000-4000-8000-0000000000c2', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S95 Twenty'),
  ('f9500000-0000-4000-8000-0000000000c3', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S95 Ten'),
  ('f9500000-0000-4000-8000-0000000000c4', '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'Zz S95 None');
insert into public.airbnb_reservations(property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZS95A1', 'completed', 'f9500000-0000-4000-8000-0000000000c1', 'Zz S95 Walk', current_date - 200, current_date - 198),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZS95A2', 'completed', 'f9500000-0000-4000-8000-0000000000c1', 'Zz S95 Walk', current_date - 150, current_date - 148),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZS95C2', 'completed', 'f9500000-0000-4000-8000-0000000000c2', 'Zz S95 Twenty', current_date - 100, current_date - 80),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZS95C3', 'completed', 'f9500000-0000-4000-8000-0000000000c3', 'Zz S95 Ten', current_date - 100, current_date - 90);

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'iat', extract(epoch from now())::bigint)::text, true),
         set_config('role', 'authenticated', true);
$$;
grant execute on function pg_temp.as_user(uuid) to public;

-- 1. the tier rule: stays 1/2/3/4/6/7, nights 9/10/19/20 ----------------------------------------------------------------------------------------
select is(public.guest_tier_v1(0, 0), null, '0 stays, 0 nights: no tier');
select is(public.guest_tier_v1(1, 9), null, '1 stay, 9 nights: no tier');
select is(public.guest_tier_v1(2, 2), 'returning', '2 stays: returning');
select is(public.guest_tier_v1(3, 6), 'returning', '3 stays: still returning');
select is(public.guest_tier_v1(4, 8), 'regular', '4 stays: regular');
select is(public.guest_tier_v1(6, 12), 'regular', '6 stays: still regular');
select is(public.guest_tier_v1(7, 14), 'vip', '7 stays: vip');
select is(public.guest_tier_v1(1, 10), 'regular', '10 nights in one stay: regular');
select is(public.guest_tier_v1(1, 19), 'regular', '19 nights: still regular');
select is(public.guest_tier_v1(1, 20), 'vip', '20 nights: vip');
select is(public.guest_tier_v1(null, null), null, 'unknown counts give no tier');

-- 2. ordinals and the benefits line ---------------------------------------------------------------------------------------------------------------
select is(array(select public.guest_ordinal_v1(n) from unnest(array[1, 2, 3, 4, 10, 11, 12, 13, 21, 22, 23, 101, 111, 112]) n),
  array['1st', '2nd', '3rd', '4th', '10th', '11th', '12th', '13th', '21st', '22nd', '23rd', '101st', '111th', '112th'], 'English ordinals incl. the teens and 21/22/23');
select is(public.guest_tier_line_v1('returning', 1),
  'Returning guest (2nd stay): welcome treat (local coffee sachets + snack); first hour of early check-in or late check-out free if the calendar allows.', 'returning line, 2nd stay');
select is(public.guest_tier_line_v1('regular', 3),
  'Regular guest (4th stay): welcome treat (local coffee sachets + snack); up to 2 hours early check-in or late check-out free if the calendar allows; set up their saved preferences.', 'regular line, 4th stay');
select is(public.guest_tier_line_v1('vip', 10),
  'VIP guest (11th stay): welcome treat (local coffee sachets + snack) and a handwritten welcome note; up to 2 hours early or late free if the calendar allows; mid-stay refresh at any stay length; set up their saved preferences.', 'vip line, 11th stay');
select is(public.guest_tier_line_v1('vip', 11) like 'VIP guest (12th stay)%' and public.guest_tier_line_v1('returning', 20) like 'Returning guest (21st stay)%', true, '12th and 21st read right in the line');
select is(public.guest_tier_line_v1(null, 5), null, 'no tier: no line');
select is(public.guest_tier_line_v1('gold', 5), null, 'an unknown tier: no line');

-- 3. refresh_guest_stats: the walk of guest c1 -----------------------------------------------------------------------------------------------------
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c1');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), 'returning', 'two completed stays: returning');
select is((select total_stays from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), 2, 'total_stays is the airbnb count as before');
select ok((select tier_changed_at is not null from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), 'tier_changed_at is stamped on the change');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1'), 1, 'one history row for the first tier');
select is((select reason from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1'), 'Tier: Returning (2 completed stays, 4 nights)', 'the history reason is the tier with the completed stays and nights as counts');
select is((select after_state from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1'),
  '{"tier": "returning", "completed_stays": 2, "completed_nights": 4}'::jsonb, 'after_state carries the tier, completed stays and nights');
select ok((select changed_by is null and before_state = '{"tier": null}'::jsonb from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1'), 'automatic change: changed_by null, before tier null');
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c1');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1'), 1, 'refreshing again with nothing changed writes no row');

-- a DIRECT: mirror plus the same stay in booking_inquiries is ONE stay: 3 completed stays (returning), not 4 (regular)
insert into public.airbnb_reservations(property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'DIRECT:ZZS95', 'completed', 'f9500000-0000-4000-8000-0000000000c1', 'Zz S95 Walk', current_date - 100, current_date - 98);
insert into public.booking_inquiries(guest_name, checkin_date, checkout_date, status, guest_id) values
  ('Zz S95 Walk', current_date - 100, current_date - 98, 'confirmed', 'f9500000-0000-4000-8000-0000000000c1');
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c1');
select is((select (s.stays, s.nights)::text from public.guest_completed_stats_v1('f9500000-0000-4000-8000-0000000000c1') s), '(3,6)', 'the DIRECT: row is skipped, the direct booking counts once: 3 stays, 6 nights');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), 'returning', 'three completed stays: still returning');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1'), 1, 'no tier change, no new history row');

-- a cancelled booking and an upcoming confirmed one do not count toward the tier; the upcoming one still counts in total_stays
insert into public.airbnb_reservations(property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZS95CAN', 'cancelled', 'f9500000-0000-4000-8000-0000000000c1', 'Zz S95 Walk', current_date - 60, current_date - 55),
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZS95FUT', 'confirmed', 'f9500000-0000-4000-8000-0000000000c1', 'Zz S95 Walk', current_date + 2, current_date + 5);
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c1');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), 'returning', 'an upcoming confirmed stay and a cancelled one are not counted for the tier');
select is((select total_stays from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), 4, 'total_stays still counts the upcoming confirmed stay (2 completed + DIRECT mirror + upcoming)');
select is((select stays from public.guest_completed_stats_v1('f9500000-0000-4000-8000-0000000000c1')), 3, 'completed stays are still 3');

-- a confirmed stay whose checkout is already past is completed: the fourth stay makes the guest regular
insert into public.airbnb_reservations(property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'ZZS95PAST', 'confirmed', 'f9500000-0000-4000-8000-0000000000c1', 'Zz S95 Walk', current_date - 20, current_date - 18);
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c1');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), 'regular', 'a confirmed stay past its checkout counts: 4 completed stays = regular');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1'), 2, 'one more history row for the change');
select ok(exists (select 1 from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1' and reason = 'Tier: Regular (4 completed stays, 8 nights)'
  and before_state = '{"tier": "returning"}'::jsonb and (after_state ->> 'completed_stays')::int = 4 and (after_state ->> 'completed_nights')::int = 8), 'the Regular row has the counts in the reason, the before tier and the counts in after_state');

-- nights alone: one 20-night stay is vip, one 10-night stay is regular; no stays is none
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c2');
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c3');
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c4');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c2'), 'vip', 'one 20-night stay: vip');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c3'), 'regular', 'one 10-night stay: regular');
-- the 10-night guest drops to one 3-night stay: no tier, and the reason uses the singular
update public.airbnb_reservations set checkout_date = current_date - 97 where confirmation_code = 'ZZS95C3';
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c3');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c3'), null, 'one 3-night stay: the regular tier is lost');
select is((select reason from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c3' and after_state -> 'tier' = 'null'::jsonb), 'Tier: none (1 completed stay)', 'the reason reads 1 completed stay (singular)');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c4'), null, 'a guest with no stays has no tier');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c4'), 0, 'and no history row');
select lives_ok($$select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000ff')$$, 'refreshing a guest that does not exist does nothing and does not fail');

-- 4. CHECK constraints ----------------------------------------------------------------------------------------------------------------------------
select throws_ok($$update public.guests set tier = 'gold' where id = 'f9500000-0000-4000-8000-0000000000c4'$$, '23514', null, 'the tier CHECK refuses a value outside the four');
select throws_ok($$update public.guests set tier_manual = 'gold' where id = 'f9500000-0000-4000-8000-0000000000c4'$$, '23514', null, 'the tier_manual CHECK refuses a value outside the three');
select lives_ok($$update public.guests set tier = 'regular', tier_manual = 'vip' where id = 'f9500000-0000-4000-8000-0000000000c4'$$, 'regular and vip are accepted values');
update public.guests set tier = null, tier_manual = null where id = 'f9500000-0000-4000-8000-0000000000c4';

-- 5. the manual tier: refused for a cleaner and anon -------------------------------------------------------------------------------------------
select pg_temp.as_user('f9500000-0000-4000-8000-0000000000a1');
select throws_ok($$select public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000c1', 'vip', 'trying it on')$$, '42501', 'forbidden', 'a cleaner cannot set a tier');
reset role;
set local role anon;
select throws_ok($$select public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000c1', 'vip', 'trying it on')$$, '42501', null, 'anon cannot set a tier');
reset role;
select is((select tier_manual from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), null, 'the refused calls changed nothing');

-- 6. the manual tier as admin: wins, clears, history once per change -----------------------------------------------------------------------------
select pg_temp.as_user('f9500000-0000-4000-8000-0000000000a3');
select is(public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000c1', 'vip', '  Friend of the family  '),
  '{"ok": true, "tier": "vip", "computed": "regular", "manual": "vip"}'::jsonb, 'admin: a hand-set vip wins over the computed regular');
reset role;
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), 'vip', 'guests.tier is the effective tier');
select ok(exists (select 1 from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1' and changed_by = 'f9500000-0000-4000-8000-0000000000a3'
  and reason = 'Manual tier: vip - Friend of the family' and before_state = '{"tier": "regular"}'::jsonb and after_state ->> 'tier' = 'vip'), 'one history row carries the actor, the trimmed reason and both tiers');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1'), 3, 'exactly one new row for that change (not two)');
select public.refresh_guest_stats('f9500000-0000-4000-8000-0000000000c1');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), 'vip', 'a later automatic refresh keeps the manual tier');
select is((select count(*)::int from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1'), 3, 'and writes no row');
select pg_temp.as_user('f9500000-0000-4000-8000-0000000000a3');
select public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000c1', 'vip', 'Confirmed by Lloyd');
reset role;
select is((select count(*)::int from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1' and reason like 'Manual tier:%'), 2,
  'setting the same effective tier again keeps an audit row of the decision');
select pg_temp.as_user('f9500000-0000-4000-8000-0000000000a3');
select is(public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000c1', null, 'Back to automatic'),
  '{"ok": true, "tier": "regular", "computed": "regular", "manual": null}'::jsonb, 'admin: NULL clears the manual tier and the computed tier returns');
reset role;
select ok(exists (select 1 from public.guest_profile_history where guest_id = 'f9500000-0000-4000-8000-0000000000c1' and reason = 'Manual tier: cleared - Back to automatic'
  and before_state = '{"tier": "vip"}'::jsonb and after_state ->> 'tier' = 'regular'), 'the clearing is in the history');
select is((select tier_manual from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), null, 'tier_manual is null again');

-- refusals inside the function
select pg_temp.as_user('f9500000-0000-4000-8000-0000000000a3');
select is(public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000c1', 'gold', 'a fine reason'), '{"ok": false, "reason": "bad_tier"}'::jsonb, 'an unknown tier is refused');
select is(public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000c1', 'vip', '  x '), '{"ok": false, "reason": "bad_reason"}'::jsonb, 'a reason under 3 characters (trimmed) is refused');
select is(public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000c1', 'vip', null), '{"ok": false, "reason": "bad_reason"}'::jsonb, 'a missing reason is refused');
select is(public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000c1', 'vip', repeat('x', 201)), '{"ok": false, "reason": "bad_reason"}'::jsonb, 'a reason over 200 characters is refused');
select is(public.admin_set_guest_tier_v1('f9500000-0000-4000-8000-0000000000fe', 'vip', 'a fine reason'), '{"ok": false, "reason": "guest_not_found"}'::jsonb, 'an unknown guest is refused');
reset role;
select is((select tier_manual from public.guests where id = 'f9500000-0000-4000-8000-0000000000c1'), null, 'the refusals changed nothing');

-- 7. staff_guest_card_v1 -----------------------------------------------------------------------------------------------------------------------
select is(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9500000-0000-4000-8000-0000000000c1', current_date) ->> 'tier', 'regular', 'the card carries the effective tier');
select is(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9500000-0000-4000-8000-0000000000c1', current_date) ->> 'tier_line',
  public.guest_tier_line_v1('regular', 4), 'and the line for the stay being prepared (4 completed so far)');
select ok(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9500000-0000-4000-8000-0000000000c1', current_date) ->> 'tier_line' like 'Regular guest (5th stay)%', 'the 5th stay is named');
-- the line ordinal is the card's own count: 5 earlier stays before current_date + 5 (the upcoming one has ended by then), so stay 6 in both
select is(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9500000-0000-4000-8000-0000000000c1', current_date + 5) ->> 'stay_count', '6', 'a later check-in counts the finished upcoming stay: stay_count 6');
select ok(public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9500000-0000-4000-8000-0000000000c1', current_date + 5) ->> 'tier_line' like 'Regular guest (6th stay)%', 'and the tier line says 6th stay, equal to stay_count');
select ok((select c ?& array['repeat', 'stay_count', 'earlier_stays', 'notes', 'id_photo_path', 'tier', 'tier_line'] and (select count(*) from jsonb_object_keys(c)) = 8
             from (select public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9500000-0000-4000-8000-0000000000c1', current_date) c) x), 'the card has its five old keys, the two tier keys and (since s96) notable');
select ok((select jsonb_typeof(c -> 'tier') = 'null' and jsonb_typeof(c -> 'tier_line') = 'null'
             from (select public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'f9500000-0000-4000-8000-0000000000c4', current_date) c) x), 'a guest with no tier: both keys are null');
select ok((select jsonb_typeof(c -> 'tier') = 'null' and jsonb_typeof(c -> 'tier_line') = 'null'
             from (select public.staff_guest_card_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', null, current_date) c) x), 'no guest at all: both keys are null');

-- 8. refresh_all_guest_tiers_v1 and the heartbeat ---------------------------------------------------------------------------------------------------
select is((select expected_interval_seconds from public.job_heartbeats where job_name = 'guest-tiers-nightly'), 86400, 'guest-tiers-nightly is seeded with a daily interval');
update public.guests set tier = null, tier_changed_at = null where id = 'f9500000-0000-4000-8000-0000000000c2';
select ok((select public.refresh_all_guest_tiers_v1()) >= 4, 'the nightly refresh returns the number of guests it refreshed (at least the four fixtures)');
select is((select tier from public.guests where id = 'f9500000-0000-4000-8000-0000000000c2'), 'vip', 'and it repaired a stale tier');
select ok((select last_started_at is not null and last_succeeded_at >= last_started_at and consecutive_failures = 0 and last_error_code is null from public.job_heartbeats where job_name = 'guest-tiers-nightly'),
  'the heartbeat shows a started and a succeeded run');
select ok(not exists (select 1 from public.guests where tier is not null and tier not in ('returning', 'regular', 'vip')), 'no guest holds a tier outside the four values');

select * from finish();
rollback;
