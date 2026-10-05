-- Session 70 (SPEC-40): release guest_id_photo_purge_20261005. The guest_companions trigger that queues orphaned ID photo paths,
-- the two service-role RPCs, and the two heartbeat rows. Property P and its guests are private to this suite (synthetic, example
-- names), so restored production rows never interfere; everything goes with the closing rollback. The suite inserts as the table
-- owner (service_role has no BYPASSRLS and no grant on the queue). The queue is emptied first so the counts are exact.
-- Fake objects are plain storage.objects rows; direct deletes there are blocked by protect_objects_delete, so "object gone" is
-- tested with a queue path that never had an object row.
--   companions  c1 photo, deleted        c2 no photo, deleted     c3 photo, replaced then notes-only update
--               c4+c5 share one photo     c6,c7 photos + c8 none under guest G2 (cascade)
--               c9 non-uuid path          ca re-queue, cb re-referenced photo
begin;
select plan(33);

select has_table('public', 'guest_id_photo_purge_queue', 'the purge queue exists');
select ok((select relrowsecurity from pg_class where oid = 'public.guest_id_photo_purge_queue'::regclass)
      and (select count(*) = 0 from pg_policies where schemaname = 'public' and tablename = 'guest_id_photo_purge_queue'),
  'RLS is on and there is no policy for anyone');
select ok(not has_table_privilege('anon', 'public.guest_id_photo_purge_queue', 'select')
      and not has_table_privilege('authenticated', 'public.guest_id_photo_purge_queue', 'select')
      and not has_table_privilege('service_role', 'public.guest_id_photo_purge_queue', 'select')
      and not has_table_privilege('service_role', 'public.guest_id_photo_purge_queue', 'insert')
      and not has_table_privilege('service_role', 'public.guest_id_photo_purge_queue', 'update')
      and not has_table_privilege('service_role', 'public.guest_id_photo_purge_queue', 'delete'),
  'no table privilege for anon, authenticated or service_role (only the RPCs touch the queue)');
select ok(exists (select 1 from pg_trigger t
                   where t.tgrelid = 'public.guest_companions'::regclass and t.tgname = 'guest_companions_release_photo'
                     and (t.tgtype & 1) = 1 and (t.tgtype & 2) = 0 and (t.tgtype & 4) = 0 and (t.tgtype & 8) = 8 and (t.tgtype & 16) = 16
                     and pg_get_triggerdef(t.oid) like '%UPDATE OF id_photo_path%'),
  'the trigger is AFTER ROW on delete and on update of id_photo_path only');
select has_function('public', 'guest_id_photo_purge_status_v1', array['interval'], 'the status RPC exists');
select has_function('public', 'guest_id_photo_purge_done_v1', array['text[]'], 'the done RPC exists');
select ok(has_function_privilege('service_role', 'public.guest_id_photo_purge_status_v1(interval)', 'execute')
      and has_function_privilege('service_role', 'public.guest_id_photo_purge_done_v1(text[])', 'execute'),
  'service_role can execute both RPCs');
select ok(not has_function_privilege('anon', 'public.guest_id_photo_purge_status_v1(interval)', 'execute')
      and not has_function_privilege('authenticated', 'public.guest_id_photo_purge_status_v1(interval)', 'execute')
      and not has_function_privilege('anon', 'public.guest_id_photo_purge_done_v1(text[])', 'execute')
      and not has_function_privilege('authenticated', 'public.guest_id_photo_purge_done_v1(text[])', 'execute'),
  'anon and authenticated cannot execute either RPC');
select ok((select count(*) = 3 and bool_and(p.prosecdef and p.proconfig = array['search_path=""'])
             from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('guest_companions_release_photo', 'guest_id_photo_purge_status_v1', 'guest_id_photo_purge_done_v1')),
  'all three functions are security definer with an empty search_path');
select ok((select count(*) = 2 from public.job_heartbeats
            where (job_name = 'guest-id-photos-backup' and expected_interval_seconds = 172800 and not ops_risk)
               or (job_name = 'guest-id-photos-drill' and expected_interval_seconds = 2678400 and not ops_risk)),
  'both heartbeat rows are seeded (2 days and monthly)');

delete from public.guest_id_photo_purge_queue;
create temp table s70_base as select (public.guest_id_photo_purge_status_v1() ->> 'unqueued_orphans')::int as orphans;

insert into public.properties(id, name, is_active) values ('e4000000-0000-4000-8000-000000000070', 'Synthetic Photo Purge 70', true);
insert into public.guests(id, property_id, name) values
  ('e4000000-0000-4000-8000-0000000000b1', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Photo Guest One'),
  ('e4000000-0000-4000-8000-0000000000b2', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Photo Guest Two');
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path) values
  ('e4000000-0000-4000-8000-0000000000c1', 'e4000000-0000-4000-8000-0000000000b1', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion 1',
   'e4000000-0000-4000-8000-0000000000c1/e4000000-0000-4000-8000-0000000000f1.jpg'),
  ('e4000000-0000-4000-8000-0000000000c2', 'e4000000-0000-4000-8000-0000000000b1', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion 2', null),
  ('e4000000-0000-4000-8000-0000000000c3', 'e4000000-0000-4000-8000-0000000000b1', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion 3',
   'e4000000-0000-4000-8000-0000000000c3/e4000000-0000-4000-8000-0000000000f3.jpg'),
  ('e4000000-0000-4000-8000-0000000000c4', 'e4000000-0000-4000-8000-0000000000b1', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion 4',
   'e4000000-0000-4000-8000-0000000000c4/e4000000-0000-4000-8000-0000000000f4.jpg'),
  ('e4000000-0000-4000-8000-0000000000c5', 'e4000000-0000-4000-8000-0000000000b1', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion 5',
   'e4000000-0000-4000-8000-0000000000c4/e4000000-0000-4000-8000-0000000000f4.jpg'),
  ('e4000000-0000-4000-8000-0000000000c6', 'e4000000-0000-4000-8000-0000000000b2', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion 6',
   'e4000000-0000-4000-8000-0000000000c6/e4000000-0000-4000-8000-0000000000f6.jpg'),
  ('e4000000-0000-4000-8000-0000000000c7', 'e4000000-0000-4000-8000-0000000000b2', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion 7',
   'e4000000-0000-4000-8000-0000000000c7/e4000000-0000-4000-8000-0000000000f7.jpg'),
  ('e4000000-0000-4000-8000-0000000000c8', 'e4000000-0000-4000-8000-0000000000b2', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion 8', null),
  ('e4000000-0000-4000-8000-0000000000c9', 'e4000000-0000-4000-8000-0000000000b1', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion 9',
   'Synthetic Companion 9 passport.jpg');

-- 1. Remove a companion that has a photo.
delete from public.guest_companions where id = 'e4000000-0000-4000-8000-0000000000c1';
select is((select source from public.guest_id_photo_purge_queue where path = 'e4000000-0000-4000-8000-0000000000c1/e4000000-0000-4000-8000-0000000000f1.jpg'),
  'delete', 'removing a companion with a photo queues its path (source delete)');

-- 2. Remove a companion without a photo.
delete from public.guest_companions where id = 'e4000000-0000-4000-8000-0000000000c2';
select is((select count(*)::int from public.guest_id_photo_purge_queue), 1, 'removing a companion without a photo queues nothing');

-- 3. Replace the photo path.
update public.guest_companions set id_photo_path = 'e4000000-0000-4000-8000-0000000000c3/e4000000-0000-4000-8000-0000000000f9.jpg'
 where id = 'e4000000-0000-4000-8000-0000000000c3';
select is((select source from public.guest_id_photo_purge_queue where path = 'e4000000-0000-4000-8000-0000000000c3/e4000000-0000-4000-8000-0000000000f3.jpg'),
  'replace', 'replacing the photo queues the OLD path (source replace)');
select is((select count(*)::int from public.guest_id_photo_purge_queue where path = 'e4000000-0000-4000-8000-0000000000c3/e4000000-0000-4000-8000-0000000000f9.jpg'),
  0, 'the NEW path is not queued');

-- 4. Update another column only.
update public.guest_companions set notes = 'seen at the gate' where id = 'e4000000-0000-4000-8000-0000000000c3';
select is((select count(*)::int from public.guest_id_photo_purge_queue), 2, 'an update that leaves id_photo_path alone queues nothing');

-- 5. Two rows share one photo (no unique constraint): only the last reference releases it.
delete from public.guest_companions where id = 'e4000000-0000-4000-8000-0000000000c4';
select is((select count(*)::int from public.guest_id_photo_purge_queue where path = 'e4000000-0000-4000-8000-0000000000c4/e4000000-0000-4000-8000-0000000000f4.jpg'),
  0, 'deleting one of two rows that share a photo queues nothing');
delete from public.guest_companions where id = 'e4000000-0000-4000-8000-0000000000c5';
select is((select count(*)::int from public.guest_id_photo_purge_queue where path = 'e4000000-0000-4000-8000-0000000000c4/e4000000-0000-4000-8000-0000000000f4.jpg'),
  1, 'deleting the second (last) reference queues the path');

-- 6. Deleting the guests row cascades and queues every companion photo.
delete from public.guests where id = 'e4000000-0000-4000-8000-0000000000b2';
select is((select count(*)::int from public.guest_id_photo_purge_queue
            where path in ('e4000000-0000-4000-8000-0000000000c6/e4000000-0000-4000-8000-0000000000f6.jpg',
                           'e4000000-0000-4000-8000-0000000000c7/e4000000-0000-4000-8000-0000000000f7.jpg')),
  2, 'deleting the guest queues every companion photo it cascades away');

-- 7. A path that is not <uuid>/<file> never blocks the delete and is not queued.
select lives_ok($$delete from public.guest_companions where id = 'e4000000-0000-4000-8000-0000000000c9'$$,
  'removing a companion whose path has a name in it still succeeds');
select is((select count(*)::int from public.guest_id_photo_purge_queue where path like '%passport%'), 0, 'a non-uuid path is not queued (the sweep reports it)');

-- 8. A path queued, re-referenced and released again starts its 7 days over.
update public.guest_id_photo_purge_queue set queued_at = now() - interval '8 days'
 where path = 'e4000000-0000-4000-8000-0000000000c1/e4000000-0000-4000-8000-0000000000f1.jpg';
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path)
values ('e4000000-0000-4000-8000-0000000000ca', 'e4000000-0000-4000-8000-0000000000b1', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion A',
        'e4000000-0000-4000-8000-0000000000c1/e4000000-0000-4000-8000-0000000000f1.jpg');
delete from public.guest_companions where id = 'e4000000-0000-4000-8000-0000000000ca';
select is((select queued_at = now() from public.guest_id_photo_purge_queue
            where path = 'e4000000-0000-4000-8000-0000000000c1/e4000000-0000-4000-8000-0000000000f1.jpg'),
  true, 'releasing a re-referenced path again resets queued_at');

-- 9. status.due: capped at 20, never younger than 7 days (or 1 day whatever is asked), never a re-referenced path.
delete from public.guest_id_photo_purge_queue;
insert into public.guest_id_photo_purge_queue(path, source, queued_at)
select 'e4000000-0000-4000-8000-' || lpad(i::text, 12, '0') || '/e4000000-0000-4000-8000-' || lpad(i::text, 12, '0') || '.jpg',
       'sweep', now() - interval '8 days'
  from generate_series(1, 25) i;
select is(jsonb_array_length(public.guest_id_photo_purge_status_v1() -> 'due'), 20, 'status.due is capped at 20 paths');

delete from public.guest_id_photo_purge_queue;
insert into public.guest_companions(id, guest_id, property_id, name, id_photo_path)
values ('e4000000-0000-4000-8000-0000000000cb', 'e4000000-0000-4000-8000-0000000000b1', 'e4000000-0000-4000-8000-000000000070', 'Synthetic Companion B',
        'e4000000-0000-4000-8000-0000000000cb/e4000000-0000-4000-8000-0000000000fb.jpg');
insert into public.guest_id_photo_purge_queue(path, source, queued_at) values
  ('e4000000-0000-4000-8000-0000000000d1/e4000000-0000-4000-8000-0000000000e1.jpg', 'delete', now() - interval '8 days'),
  ('e4000000-0000-4000-8000-0000000000d2/e4000000-0000-4000-8000-0000000000e2.jpg', 'delete', now()),
  ('e4000000-0000-4000-8000-0000000000d3/e4000000-0000-4000-8000-0000000000e3.jpg', 'delete', now() - interval '2 hours'),
  ('e4000000-0000-4000-8000-0000000000cb/e4000000-0000-4000-8000-0000000000fb.jpg', 'delete', now() - interval '8 days');
select is(public.guest_id_photo_purge_status_v1() -> 'due',
  '["e4000000-0000-4000-8000-0000000000d1/e4000000-0000-4000-8000-0000000000e1.jpg"]'::jsonb,
  'status.due holds only the 8-day-old unreferenced path (not young, not 2 hours old, not re-referenced)');
select is(public.guest_id_photo_purge_status_v1(interval '0') -> 'due',
  '["e4000000-0000-4000-8000-0000000000d1/e4000000-0000-4000-8000-0000000000e1.jpg"]'::jsonb,
  'a zero min age is floored at one day: the 2-hour-old and the young rows stay out');
select is(jsonb_typeof(public.guest_id_photo_purge_status_v1() -> 'queued'), 'number', 'status.queued is a number');
select is((public.guest_id_photo_purge_status_v1() ->> 'queued')::int, 4, 'status.queued counts every queue row');

-- 10. done clears a row only when the object is really gone.
insert into storage.objects(bucket_id, name) values ('guest-id-photos', 'e4000000-0000-4000-8000-0000000000d1/e4000000-0000-4000-8000-0000000000e1.jpg');
select is(public.guest_id_photo_purge_done_v1(array[
    'e4000000-0000-4000-8000-0000000000d1/e4000000-0000-4000-8000-0000000000e1.jpg',
    'e4000000-0000-4000-8000-0000000000d3/e4000000-0000-4000-8000-0000000000e3.jpg']), 1,
  'done reports 1: the row whose object is gone is cleared, the one whose object still exists is not');
select is((select count(*)::int from public.guest_id_photo_purge_queue
            where path = 'e4000000-0000-4000-8000-0000000000d1/e4000000-0000-4000-8000-0000000000e1.jpg'), 1, 'the row with a live object stays queued');
select is((select count(*)::int from public.guest_id_photo_purge_queue
            where path = 'e4000000-0000-4000-8000-0000000000d3/e4000000-0000-4000-8000-0000000000e3.jpg'), 0, 'the row with no object is gone');
select is(public.guest_id_photo_purge_done_v1(array[]::text[]), 0, 'done with an empty list clears nothing');
select is(public.guest_id_photo_purge_done_v1(null), 0, 'done with null clears nothing');

-- 11. unqueued_orphans: an old object nobody references and nobody queued. Placeholders and queued paths are not counted.
insert into storage.objects(bucket_id, name, created_at) values
  ('guest-id-photos', 'e4000000-0000-4000-8000-0000000000d9/e4000000-0000-4000-8000-0000000000e9.jpg', now() - interval '3 days'),
  ('guest-id-photos', 'e4000000-0000-4000-8000-0000000000d9/.emptyFolderPlaceholder', now() - interval '3 days');
select is((public.guest_id_photo_purge_status_v1() ->> 'unqueued_orphans')::int - (select orphans from s70_base), 1,
  'one old unreferenced object counts as an unqueued orphan (the placeholder does not)');
insert into public.guest_id_photo_purge_queue(path, source) values ('e4000000-0000-4000-8000-0000000000d9/e4000000-0000-4000-8000-0000000000e9.jpg', 'sweep');
select is((public.guest_id_photo_purge_status_v1() ->> 'unqueued_orphans')::int - (select orphans from s70_base), 0,
  'once queued, it is no longer an unqueued orphan');

select * from finish();
rollback;
