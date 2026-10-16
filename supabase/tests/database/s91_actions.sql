-- Session 91 (lane SQL): release s91_actions_20261025. Guest ID photo rotation (column, reset trigger, staff_photo_rotation_v1,
-- set_guest_photo_rotation_v1), ops_notice_close_v1, notices_v1 findings (open only) and the one low-stock rule in notices_v1 and staff_home_v1.
-- Synthetic fixtures only (uuids e9100000-..., property ...b0); every lookup is scoped to them because a real backup holds real rows.
-- Refusals are tested by calling as the refused role. Grants are not asserted (a --no-acl rehearsal carries none); the release forward checks prove them.
-- Everything rolls back.
begin;
select plan(56);

-- baseline grants a --no-acl restore lacks (idempotent, rolled back with the suite)
alter role service_role bypassrls;
grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid), public.current_staff_active(text[]) to authenticated, service_role;
grant select on public.guests, public.airbnb_reservations to authenticated;
grant execute on function public.staff_can_view_guest_id_object_v1(text) to authenticated, service_role;
grant execute on function public.notices_v1(uuid), public.staff_home_v1(uuid), public.staff_photo_rotation_v1(text[]),
  public.set_guest_photo_rotation_v1(text, smallint), public.ops_notice_close_v1(uuid, uuid) to authenticated, service_role;

-- fixtures -------------------------------------------------------------------------------------------------------------------------------
insert into public.properties(id, name, is_active) values
  ('e9100000-0000-4000-8000-0000000000b0', 'Synthetic S91 A', true),
  ('e9100000-0000-4000-8000-0000000000b1', 'Synthetic S91 B', true);
insert into auth.users(id) values
  ('e9100000-0000-4000-8000-000000000001'), ('e9100000-0000-4000-8000-000000000002'),
  ('e9100000-0000-4000-8000-000000000003'), ('e9100000-0000-4000-8000-000000000004');
insert into public.staff_access_profiles(user_id, role) values
  ('e9100000-0000-4000-8000-000000000001', 'cleaner'),
  ('e9100000-0000-4000-8000-000000000002', 'admin'),
  ('e9100000-0000-4000-8000-000000000003', 'owner');
insert into public.staff_property_access(user_id, property_id) values
  ('e9100000-0000-4000-8000-000000000001', 'e9100000-0000-4000-8000-0000000000b0'),
  ('e9100000-0000-4000-8000-000000000002', 'e9100000-0000-4000-8000-0000000000b0'),
  ('e9100000-0000-4000-8000-000000000003', 'e9100000-0000-4000-8000-0000000000b0');
insert into auth.users(id) values ('e9100000-0000-4000-8000-000000000005'), ('e9100000-0000-4000-8000-000000000006');
insert into public.staff_access_profiles(user_id, role, disabled_at, sessions_revoked_after) values
  ('e9100000-0000-4000-8000-000000000005', 'admin', now() - interval '1 hour', null),
  ('e9100000-0000-4000-8000-000000000006', 'admin', null, now() - interval '1 hour');
-- 05 is a disabled admin, 06 an admin whose sessions were revoked an hour ago (its token below was issued two hours ago).
-- 04 has no staff profile at all.

-- G1 is in the house now (its own photo is the primary one), G3 is neither current nor next.
insert into public.guests(id, property_id, name) values
  ('e9100000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000b0', 'Zz S91 Current'),
  ('e9100000-0000-4000-8000-0000000000c3', 'e9100000-0000-4000-8000-0000000000b0', 'Zz S91 Other');
insert into public.airbnb_reservations(id, property_id, confirmation_code, status, guest_id, guest_name, checkin_date, checkout_date) values
  ('e9100000-0000-4000-8000-0000000000d2', 'e9100000-0000-4000-8000-0000000000b0', 'ZZS91CUR', 'confirmed', 'e9100000-0000-4000-8000-0000000000c1', 'Zz S91 Current', current_date - 1, current_date + 2);
insert into public.calendar_events(property_id, uid, source, status, guest_name, checkin_date, checkout_date, linked_reservation_id) values
  ('e9100000-0000-4000-8000-0000000000b0', 'zz-s91-cur', 'airbnb', 'confirmed', 'Zz S91 Current', current_date - 1, current_date + 2, 'e9100000-0000-4000-8000-0000000000d2');
insert into public.guests(id, property_id, name) values ('e9100000-0000-4000-8000-0000000000c5', 'e9100000-0000-4000-8000-0000000000b1', 'Zz S91 Other Property');
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path) values
  ('e9100000-0000-4000-8000-0000000000e5', 'e9100000-0000-4000-8000-0000000000c5', 'e9100000-0000-4000-8000-0000000000b1', 'Zz S91 Elsewhere', 'e9100000-0000-4000-8000-0000000000e5/11111111-0000-4000-8000-000000000005.jpg'),
  ('e9100000-0000-4000-8000-0000000000e1', 'e9100000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000b0', 'Zz S91 Current', 'e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg'),
  ('e9100000-0000-4000-8000-0000000000e2', 'e9100000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000b0', 'Zz S91 Companion', 'e9100000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-000000000002.jpg'),
  ('e9100000-0000-4000-8000-0000000000e4', 'e9100000-0000-4000-8000-0000000000c3', 'e9100000-0000-4000-8000-0000000000b0', 'Zz S91 Other', 'e9100000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg');

-- notices: one active on A, one active on B, one already closed
insert into public.ops_notices(id, property_id, notice_type, title, effective_date, source, is_active) values
  ('e9100000-0000-4000-8000-0000000000f1', 'e9100000-0000-4000-8000-0000000000b0', 'note', 'Zz S91 note', (now() at time zone 'Asia/Manila')::date + 1, 'manual', true),
  ('e9100000-0000-4000-8000-0000000000f2', 'e9100000-0000-4000-8000-0000000000b0', 'water', 'Zz S91 water', (now() at time zone 'Asia/Manila')::date + 1, 'gscwd', true),
  ('e9100000-0000-4000-8000-0000000000f3', 'e9100000-0000-4000-8000-0000000000b1', 'note', 'Zz S91 other property', (now() at time zone 'Asia/Manila')::date + 1, 'manual', true),
  ('e9100000-0000-4000-8000-0000000000f4', 'e9100000-0000-4000-8000-0000000000b0', 'note', 'Zz S91 already closed', (now() at time zone 'Asia/Manila')::date + 1, 'manual', false),
  ('e9100000-0000-4000-8000-0000000000f6', 'e9100000-0000-4000-8000-0000000000b0', 'note', 'Zz S91 staff note', (now() at time zone 'Asia/Manila')::date + 1, 'staff', true);

-- stock: below, exactly at, above, no level
insert into public.inventory_items(id, property_id, name, category, qty_on_hand, reorder_below, is_active) values
  ('e9100000-0000-4000-8000-0000000000a1', 'e9100000-0000-4000-8000-0000000000b0', '0 Zz S91 below', 'Supplies', 2, 5, true),
  ('e9100000-0000-4000-8000-0000000000a2', 'e9100000-0000-4000-8000-0000000000b0', '0 Zz S91 at the level', 'Supplies', 5, 5, true),
  ('e9100000-0000-4000-8000-0000000000a3', 'e9100000-0000-4000-8000-0000000000b0', '0 Zz S91 above', 'Supplies', 9, 5, true),
  ('e9100000-0000-4000-8000-0000000000a4', 'e9100000-0000-4000-8000-0000000000b0', '0 Zz S91 no level', 'Supplies', 0, null, true);
-- findings: one open, one acknowledged
insert into public.verifier_findings(key, check_id, severity, title, status) values
  ('zz-s91-open', 'V6', 'yellow', '0 Zz S91 open finding', 'open'),
  ('zz-s91-acked', 'V6', 'yellow', '0 Zz S91 acked finding', 'acknowledged');

-- 1-4. column, check, reset trigger ---------------------------------------------------------------------------------------------------------
select is((select format_type(atttypid, atttypmod) from pg_attribute where attrelid = 'public.guest_companions'::regclass and attname = 'id_photo_rotation' and not attisdropped),
  'smallint', 'id_photo_rotation is a smallint');
select is((select id_photo_rotation from public.guest_companions where id = 'e9100000-0000-4000-8000-0000000000e1'), null, 'a new row is unturned (null)');
select throws_ok($$update public.guest_companions set id_photo_rotation = 45 where id = 'e9100000-0000-4000-8000-0000000000e1'$$, '23514', null, 'the table check refuses 45');
update public.guest_companions set id_photo_rotation = 90 where id = 'e9100000-0000-4000-8000-0000000000e1';
update public.guest_companions set id_photo_rotation = 180 where id = 'e9100000-0000-4000-8000-0000000000e2';
update public.guest_companions set notes = 'unrelated edit' where id = 'e9100000-0000-4000-8000-0000000000e1';
select is((select id_photo_rotation from public.guest_companions where id = 'e9100000-0000-4000-8000-0000000000e1'), 90::smallint, 'an unrelated edit keeps the rotation');
update public.guest_companions set id_photo_path = 'e9100000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-0000000000ff.jpg' where id = 'e9100000-0000-4000-8000-0000000000e2';
select is((select id_photo_rotation from public.guest_companions where id = 'e9100000-0000-4000-8000-0000000000e2'), null, 'replacing the photo resets the rotation to null');

-- cleaner ----------------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9100000-0000-4000-8000-000000000001"}';
select is((select count(*)::int from public.staff_photo_rotation_v1(array[
    'e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg',
    'e9100000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-0000000000ff.jpg',
    'e9100000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg',
    'no/such/path.jpg'])), 1, 'cleaner: only the viewable (primary, in-house) path comes back; the companion, the other guest and the unknown path are absent');
select is((select rotation from public.staff_photo_rotation_v1(array['e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg'])), 90::smallint,
  'cleaner: reads the rotation of the viewable path');
select is((select count(*)::int from public.staff_photo_rotation_v1(null)), 0, 'cleaner: a null list is empty');
select throws_ok($$select * from public.staff_photo_rotation_v1((select array_agg('p' || g) from generate_series(1, 51) g))$$, '22023', 'too_many_paths', 'cleaner: 51 paths are refused');
select throws_ok($$select public.set_guest_photo_rotation_v1('e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 270::smallint)$$,
  '42501', 'forbidden', 'cleaner cannot set a rotation');
select throws_ok($$select public.ops_notice_close_v1('e9100000-0000-4000-8000-0000000000f1', 'e9100000-0000-4000-8000-0000000000b0')$$,
  '42501', 'forbidden', 'cleaner cannot close a notice');
reset role;
select is((select id_photo_rotation from public.guest_companions where id = 'e9100000-0000-4000-8000-0000000000e1'), 90::smallint, 'the refused cleaner call changed nothing');
select ok((select is_active from public.ops_notices where id = 'e9100000-0000-4000-8000-0000000000f1'), 'the refused cleaner call left the notice open');

-- not staff / no session ---------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9100000-0000-4000-8000-000000000004"}';
select throws_ok($$select * from public.staff_photo_rotation_v1(array['x'])$$, '42501', 'forbidden', 'a user with no staff profile cannot read rotations');
select throws_ok($$select public.set_guest_photo_rotation_v1('x', 0::smallint)$$, '42501', 'forbidden', 'a user with no staff profile cannot set a rotation');
select throws_ok($$select public.ops_notice_close_v1('e9100000-0000-4000-8000-0000000000f1')$$, '42501', 'forbidden', 'a user with no staff profile cannot close a notice');
reset role;
set local role authenticated;
set local request.jwt.claims = '{}';
select throws_ok($$select * from public.staff_photo_rotation_v1(array['x'])$$, '42501', 'forbidden', 'no session cannot read rotations');
reset role;

-- admin: rotation ---------------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9100000-0000-4000-8000-000000000002"}';
select is((select count(*)::int from public.staff_photo_rotation_v1(array[
    'e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg',
    'e9100000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-0000000000ff.jpg',
    'e9100000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg',
    'no/such/path.jpg'])), 3, 'admin: every photo on the property comes back, the unknown path does not');
select is(public.set_guest_photo_rotation_v1('e9100000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', 270::smallint),
  jsonb_build_object('ok', true, 'path', 'e9100000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', 'rotation', 270), 'admin: set returns ok, path, rotation');
select is((select rotation from public.staff_photo_rotation_v1(array['e9100000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg'])), 270::smallint, 'admin: the new rotation reads back');
select is(public.set_guest_photo_rotation_v1('e9100000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', 0::smallint)->>'ok', 'true', 'admin: 0 is a valid rotation (turn back)');
select is((select rotation from public.staff_photo_rotation_v1(array['e9100000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg'])), 0::smallint, 'admin: 0 reads back as 0, not null');
select is(public.set_guest_photo_rotation_v1('no/such/path.jpg', 90::smallint), jsonb_build_object('ok', false, 'error', 'not_found'), 'admin: an unknown path is not_found');
select throws_ok($$select public.set_guest_photo_rotation_v1('e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 45::smallint)$$,
  '22023', 'rotation_invalid', 'admin: 45 is refused');
select throws_ok($$select public.set_guest_photo_rotation_v1('e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', null)$$,
  '22023', 'rotation_invalid', 'admin: null is refused');
select is((select rotation from public.staff_photo_rotation_v1(array['e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg'])), 90::smallint, 'admin: a refused rotation changed nothing');
reset role;

-- owner: rotation + notice close ------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9100000-0000-4000-8000-000000000003"}';
select is(public.set_guest_photo_rotation_v1('e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 180::smallint)->>'ok', 'true', 'owner: can set a rotation');
select is(public.ops_notice_close_v1('e9100000-0000-4000-8000-0000000000f1', 'e9100000-0000-4000-8000-0000000000b0'),
  jsonb_build_object('ok', true, 'id', 'e9100000-0000-4000-8000-0000000000f1'::uuid), 'owner: close returns ok and the id');
reset role;
select ok(not (select is_active from public.ops_notices where id = 'e9100000-0000-4000-8000-0000000000f1'), 'the closed notice is inactive');
select ok((select is_active from public.ops_notices where id = 'e9100000-0000-4000-8000-0000000000f2'), 'a different notice on the property stays active');

-- admin: notice close ---------------------------------------------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9100000-0000-4000-8000-000000000002"}';
select is(public.ops_notice_close_v1('e9100000-0000-4000-8000-0000000000f2', 'e9100000-0000-4000-8000-0000000000b0'), jsonb_build_object('ok', false, 'error', 'not_closable'), 'admin: a feed (gscwd) notice is not_closable');
select is(public.ops_notice_close_v1('e9100000-0000-4000-8000-0000000000f6', 'e9100000-0000-4000-8000-0000000000b0')->>'ok', 'true', 'admin: closes a hand-added (source staff) notice');
select is(public.ops_notice_close_v1('e9100000-0000-4000-8000-0000000000f1', 'e9100000-0000-4000-8000-0000000000b0'), jsonb_build_object('ok', false, 'error', 'not_found'), 'admin: closing it twice is not_found');
select is(public.ops_notice_close_v1('e9100000-0000-4000-8000-0000000000f4', 'e9100000-0000-4000-8000-0000000000b0'), jsonb_build_object('ok', false, 'error', 'not_found'), 'admin: an already closed notice is not_found');
select is(public.ops_notice_close_v1('e9100000-0000-4000-8000-0000000000ff', 'e9100000-0000-4000-8000-0000000000b0'), jsonb_build_object('ok', false, 'error', 'not_found'), 'admin: an absent id is not_found');
select throws_ok($$select public.ops_notice_close_v1('e9100000-0000-4000-8000-0000000000f3', 'e9100000-0000-4000-8000-0000000000b1')$$, '42501', 'forbidden', 'admin: another property is forbidden');
reset role;
select ok((select is_active from public.ops_notices where id = 'e9100000-0000-4000-8000-0000000000f3'), 'the other property notice is untouched');
select ok((select is_active from public.ops_notices where id = 'e9100000-0000-4000-8000-0000000000f2'), 'the feed notice is still active after the refused close');
select ok(exists(select 1 from public.admin_audit_log where entity_table = 'ops_notices' and entity_id = 'e9100000-0000-4000-8000-0000000000f6' and action = 'soft_delete'), 'the close is audited by the ops_notices trigger, labelled soft_delete like admin_soft_delete_v1');

-- admin: notices_v1 findings + low stock; staff_home_v1 low stock ---------------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9100000-0000-4000-8000-000000000002"}';
select ok(exists(select 1 from jsonb_array_elements(public.notices_v1('e9100000-0000-4000-8000-0000000000b0')->'house') h where h->>'kind' = 'finding' and h->>'id' = 'zz-s91-open'), 'notices_v1: the open finding is listed');
select ok(not exists(select 1 from jsonb_array_elements(public.notices_v1('e9100000-0000-4000-8000-0000000000b0')->'house') h where h->>'id' = 'zz-s91-acked'), 'notices_v1: the acknowledged finding is not listed');
select is((select array_agg(h->>'id' order by h->>'id') from jsonb_array_elements(public.notices_v1('e9100000-0000-4000-8000-0000000000b0')->'house') h where h->>'kind' = 'low_stock'),
  array['e9100000-0000-4000-8000-0000000000a1', 'e9100000-0000-4000-8000-0000000000a2'], 'notices_v1: low stock = below and exactly at the level, not above, not without a level');
select is((select array_agg(w->>'title' order by w->>'title') from jsonb_array_elements(public.staff_home_v1('e9100000-0000-4000-8000-0000000000b0')->'warnings') w where w->>'kind' = 'inventory' and w->>'title' like '%Zz S91%'),
  array['Low stock: 0 Zz S91 at the level', 'Low stock: 0 Zz S91 below'], 'staff_home_v1: the same two items, same rule');
select is((select count(*)::int from jsonb_array_elements(public.staff_home_v1('e9100000-0000-4000-8000-0000000000b0')->'warnings') w where w->>'kind' = 'verifier' and w->>'title' like '%Zz S91 acked%'), 0, 'staff_home_v1: the acknowledged finding is not a warning either');
reset role;

-- admin: another property's photo, and replacing a photo through save_guest_companion_v1 --------------------------------------------------------
set local role authenticated;
set local request.jwt.claims = '{"sub":"e9100000-0000-4000-8000-000000000002"}';
select is(public.set_guest_photo_rotation_v1('e9100000-0000-4000-8000-0000000000e5/11111111-0000-4000-8000-000000000005.jpg', 90::smallint), jsonb_build_object('ok', false, 'error', 'not_found'),
  'admin: a companion photo on another property is not_found');
select public.save_guest_companion_v1('e9100000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000e1', '{"id_photo_path":"e9100000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-0000000000aa.jpg"}'::jsonb, null, 'zz s91');
reset role;
select is((select id_photo_rotation from public.guest_companions where id = 'e9100000-0000-4000-8000-0000000000e5'), null, 'the refused call left the other property photo unturned');
select is((select id_photo_rotation from public.guest_companions where id = 'e9100000-0000-4000-8000-0000000000e1'), null, 'save_guest_companion_v1 replacing the photo path reset the rotation (it was 180)');

-- RLS on guests and airbnb_reservations follows the live profile ------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', format('{"sub":"e9100000-0000-4000-8000-000000000002","iat":%s}', extract(epoch from now())::bigint), true);
select is((select count(*)::int from public.guests where id in ('e9100000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000c3')), 2, 'active admin reads the guests');
select is((select count(*)::int from public.airbnb_reservations where id = 'e9100000-0000-4000-8000-0000000000d2'), 1, 'active admin reads the reservations');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', format('{"sub":"e9100000-0000-4000-8000-000000000005","iat":%s,"app_metadata":{"role":"admin"}}', extract(epoch from now())::bigint), true);
select is((select count(*)::int from public.guests where id in ('e9100000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000c3')), 0, 'disabled admin (JWT still says admin) reads no guests');
select is((select count(*)::int from public.airbnb_reservations where id = 'e9100000-0000-4000-8000-0000000000d2'), 0, 'disabled admin reads no reservations');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', format('{"sub":"e9100000-0000-4000-8000-000000000006","iat":%s,"app_metadata":{"role":"admin"}}', (extract(epoch from now()) - 7200)::bigint), true);
select is((select count(*)::int from public.guests where id in ('e9100000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000c3')), 0, 'revoked-session admin reads no guests');
select is((select count(*)::int from public.airbnb_reservations where id = 'e9100000-0000-4000-8000-0000000000d2'), 0, 'revoked-session admin reads no reservations');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', format('{"sub":"e9100000-0000-4000-8000-000000000001","iat":%s,"app_metadata":{"role":"admin"}}', extract(epoch from now())::bigint), true);
select is((select count(*)::int from public.guests where id in ('e9100000-0000-4000-8000-0000000000c1', 'e9100000-0000-4000-8000-0000000000c3')), 0, 'cleaner (even with an admin claim) reads no guests');
select is((select count(*)::int from public.airbnb_reservations where id = 'e9100000-0000-4000-8000-0000000000d2'), 0, 'cleaner reads no reservations');
reset role;
select ok((select bool_and(qual like '%current_staff_active%' and with_check like '%current_staff_active%' and qual not like '%app_metadata%') from pg_policies
  where tablename in ('guests', 'airbnb_reservations') and policyname in ('guests_owner_admin_all', 'airbnb_reservations_owner_admin_all')), 'both owner/admin policies use current_staff_active, not the JWT claim');

select * from finish();
rollback;
