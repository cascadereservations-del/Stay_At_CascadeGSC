-- Session 116 (lane S): release s116_guest_photo_name_20261115. staff_guest_card_v1 gains id_photo_name: btrim(name) of the guest_companions row that holds the guest's
-- primary ID photo (the row id_face_box is read from), under the same gate as id_photo_path.
-- Synthetic fixtures only (uuids a1160000-...). Everything rolls back.
begin;
select plan(14);

grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.jwt() to anon, authenticated, service_role;
grant execute on function public.current_staff_authorized(text, uuid) to authenticated, service_role;

insert into public.properties(id, name, is_active) values ('a1160000-0000-4000-8000-0000000000b0', 'Synthetic S116', true);
insert into auth.users(id) values ('a1160000-0000-4000-8000-000000000001'), ('a1160000-0000-4000-8000-000000000002');
insert into public.staff_access_profiles(user_id, role) values
  ('a1160000-0000-4000-8000-000000000001', 'cleaner'), ('a1160000-0000-4000-8000-000000000002', 'cleaner');
insert into public.staff_property_access(user_id, property_id) values
  ('a1160000-0000-4000-8000-000000000001', 'a1160000-0000-4000-8000-0000000000b0'),
  ('a1160000-0000-4000-8000-000000000002', 'a1160000-0000-4000-8000-0000000000b0');
-- the second cleaner is disabled: staff_may_see_guest_id_v1 is false for that session
update public.staff_access_profiles set disabled_at = now() where user_id = 'a1160000-0000-4000-8000-000000000002';

-- G1: the only photos are companions (no row is named like the booker). G2: has its own photo (padded name). G3: no photo at all.
insert into public.guests(id, property_id, name) values
  ('a1160000-0000-4000-8000-0000000000c1', 'a1160000-0000-4000-8000-0000000000b0', 'Zz S116 Booker'),
  ('a1160000-0000-4000-8000-0000000000c2', 'a1160000-0000-4000-8000-0000000000b0', 'Zz S116 Own'),
  ('a1160000-0000-4000-8000-0000000000c3', 'a1160000-0000-4000-8000-0000000000b0', 'Zz S116 Nophoto');
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path, created_at) values
  ('a1160000-0000-4000-8000-0000000000e1', 'a1160000-0000-4000-8000-0000000000c1', 'a1160000-0000-4000-8000-0000000000b0', '  Zz S116 Friend A ', 'a1160000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', now() - interval '2 days'),
  ('a1160000-0000-4000-8000-0000000000e2', 'a1160000-0000-4000-8000-0000000000c1', 'a1160000-0000-4000-8000-0000000000b0', 'Zz S116 Friend B', 'a1160000-0000-4000-8000-0000000000e2/11111111-0000-4000-8000-000000000002.jpg', now() - interval '1 day'),
  ('a1160000-0000-4000-8000-0000000000e3', 'a1160000-0000-4000-8000-0000000000c2', 'a1160000-0000-4000-8000-0000000000b0', '  Zz S116 Own  ', 'a1160000-0000-4000-8000-0000000000e3/11111111-0000-4000-8000-000000000003.jpg', now() - interval '3 days'),
  ('a1160000-0000-4000-8000-0000000000e4', 'a1160000-0000-4000-8000-0000000000c2', 'a1160000-0000-4000-8000-0000000000b0', 'Zz S116 Other', 'a1160000-0000-4000-8000-0000000000e4/11111111-0000-4000-8000-000000000004.jpg', now() - interval '4 days'),
  ('a1160000-0000-4000-8000-0000000000e5', 'a1160000-0000-4000-8000-0000000000c3', 'a1160000-0000-4000-8000-0000000000b0', 'Zz S116 Nopath', null, now() - interval '5 days');

-- ===== a cleaner who may see IDs =====
select set_config('request.jwt.claims', json_build_object('sub','a1160000-0000-4000-8000-000000000001','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);

select is(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c1', current_date) ->> 'id_photo_name', 'Zz S116 Friend A',
  'only photos are companions: the name is the primary photo row name, trimmed (Friend A, the earlier photo)');
select is(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c1', current_date) ->> 'id_photo_path',
  'a1160000-0000-4000-8000-0000000000e1/11111111-0000-4000-8000-000000000001.jpg', 'and that row is the one id_photo_path points at');
select is(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c2', current_date) ->> 'id_photo_name', 'Zz S116 Own',
  'a guest with their own photo: their own name (the row named like the booker wins over an older companion), trimmed');
select is(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c2', current_date) ->> 'id_photo_path',
  'a1160000-0000-4000-8000-0000000000e3/11111111-0000-4000-8000-000000000003.jpg', 'and id_photo_path is that same row');
select ok(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c3', current_date) ? 'id_photo_name'
      and jsonb_typeof(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c3', current_date) -> 'id_photo_name') = 'null',
  'a guest with no photo: the key is present and null');
select ok(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', null, current_date) ? 'id_photo_name'
      and jsonb_typeof(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', null, current_date) -> 'id_photo_name') = 'null', 'no guest at all: the key is present and null');
select ok((select c ?& array['repeat', 'stay_count', 'earlier_stays', 'notes', 'id_photo_path', 'id_photo_name', 'id_face_box', 'tier', 'tier_line', 'notable'] and (select count(*) from jsonb_object_keys(c)) = 10
             from (select public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c1', current_date) c) x),
  'the card has its nine old keys and exactly one new one (id_photo_name)');

-- ===== a session that may not see IDs (disabled profile) =====
select set_config('request.jwt.claims', json_build_object('sub','a1160000-0000-4000-8000-000000000002','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select ok(jsonb_typeof(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c1', current_date) -> 'id_photo_name') = 'null',
  'a role that may not see IDs: id_photo_name is null');
select ok(jsonb_typeof(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c1', current_date) -> 'id_photo_path') = 'null',
  'and so is id_photo_path (same gate)');

-- ===== no session at all =====
select set_config('request.jwt.claims', '', true);
select ok(jsonb_typeof(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000b0', 'a1160000-0000-4000-8000-0000000000c1', current_date) -> 'id_photo_name') = 'null',
  'no signed-in staff: id_photo_name is null');

-- ===== a signed-in cleaner on a property they have no access to =====
select set_config('request.jwt.claims', json_build_object('sub','a1160000-0000-4000-8000-000000000001','role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
select ok(jsonb_typeof(public.staff_guest_card_v1('a1160000-0000-4000-8000-0000000000ff', 'a1160000-0000-4000-8000-0000000000c1', current_date) -> 'id_photo_name') = 'null',
  'a property the cleaner has no access to: id_photo_name is null');

-- ===== grants and shape unchanged =====
select ok(not has_function_privilege('anon', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute') and not has_function_privilege('authenticated', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute')
      and has_function_privilege('service_role', 'public.staff_guest_card_v1(uuid,uuid,date)', 'execute'), 'staff_guest_card_v1: service_role only (unchanged)');
select ok((select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = 'public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure),
  'still security definer, stable, empty search_path');
select ok((select p.prosrc like '%id_photo_name%' and p.prosrc like '%s115: what the cleaner reported%' from pg_proc p where p.oid = 'public.staff_guest_card_v1(uuid,uuid,date)'::regprocedure),
  'the s115 turnover-report lines are still in the body');

select * from finish();
rollback;
