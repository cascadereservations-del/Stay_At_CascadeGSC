-- Session 70 (SPEC-40 section 4.4), PART B: queue the orphans Lloyd approved from PART A (2026-10-05-s70-guest-id-photo-orphan-sweep.sql).
-- Needs release guest_id_photo_purge_20261005 applied first (the queue table). queued_at is backdated 8 days so the next
-- daily photo backup run purges them, after confirming each is in the encrypted chain (a placeholder needs no backup).
-- Edit the array to exactly the approved paths. Re-running changes nothing. Run with stay-site/scripts/migrations/run-sql-on-host.sh.
begin;

insert into public.guest_id_photo_purge_queue(path, source, queued_at)
select p, 'sweep', now() - interval '8 days'
  from unnest(array['6c1e7edc-4c43-4b2d-b7d3-124b4f6c3429/.emptyFolderPlaceholder']::text[]) p
 where not exists (select 1 from public.guest_companions c where c.id_photo_path = p)
on conflict (path) do nothing;

select count(*) as queued_now from public.guest_id_photo_purge_queue;

commit;
