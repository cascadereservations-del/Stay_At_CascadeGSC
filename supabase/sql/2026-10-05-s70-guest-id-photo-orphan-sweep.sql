-- Session 70 (SPEC-40 section 4.4), PART A: read-only listing of guest-id-photos objects that no guest_companions row points at
-- and that are not queued. Safe to run any time (select only). A name that is not uuid-shaped is masked, so a guest name can
-- never print. Lloyd approves the list before PART B (2026-10-05-s70-guest-id-photo-orphan-sweep-queue.sql) queues anything.
-- Expected on 2026-10-04: exactly one row, the .emptyFolderPlaceholder of a deleted companion folder.
-- Needs release guest_id_photo_purge_20261005 applied (it reads the queue table).
select case when o.name ~ '^[0-9a-f-]{36}/[^/]+$' then o.name else '<non-uuid name hidden>' end as path,
       (o.metadata->>'size')::bigint as bytes,
       o.created_at,
       case when o.name like '%/.emptyFolderPlaceholder' then 'placeholder'
            when not exists (select 1 from public.guest_companions c where c.id::text = split_part(o.name, '/', 1)) then 'companion gone'
            else 'companion points at another photo' end as why
  from storage.objects o
 where o.bucket_id = 'guest-id-photos'
   and o.created_at < now() - interval '1 day'
   and not exists (select 1 from public.guest_companions c where c.id_photo_path = o.name)
   and not exists (select 1 from public.guest_id_photo_purge_queue q where q.path = o.name)
 order by o.created_at;
