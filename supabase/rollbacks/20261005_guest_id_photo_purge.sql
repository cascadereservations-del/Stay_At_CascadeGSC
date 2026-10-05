-- Compensating rollback for release guest_id_photo_purge_20261005 (session 70, SPEC-40). Removes the trigger, the three functions
-- and the queue. Paths still queued then show up in the one-off orphan sweep (sql/2026-10-05-s70-guest-id-photo-orphan-sweep.sql).
-- The two heartbeat rows stay: DISABLE the two Task Scheduler tasks first (Cascade Guest ID Photos Daily Backup / Monthly Drill),
-- or job-heartbeat-monitor sends a Finance card when they go stale. The backup script stops purging on its own once the RPCs are gone.
begin;

drop trigger if exists guest_companions_release_photo on public.guest_companions;
drop function if exists public.guest_companions_release_photo();
drop function if exists public.guest_id_photo_purge_status_v1(interval);
drop function if exists public.guest_id_photo_purge_done_v1(text[]);
drop table if exists public.guest_id_photo_purge_queue;

commit;
