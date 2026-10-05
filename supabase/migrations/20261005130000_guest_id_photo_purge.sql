-- Session 70 (SPEC-40): release guest_id_photo_purge_20261005. The orphan fix for guest ID photos.
-- Every writer of a photo path goes through public.guest_companions (dashboard Remove and Replace, Telegram replace, and
-- "on delete cascade" from guests), so ONE trigger there queues every path that loses its last reference. The workstation
-- backup run (waves scripts/recovery/p5/guest-id-photos.mjs) drains the queue through the Storage API, only after the bytes are
-- in the encrypted chain and on Alfred, max 20 per run, 7 days after queueing.
--   guest_id_photo_purge_queue          paths waiting to be purged. Service role has NO table grant: only the two RPCs touch it.
--   guest_companions_release_photo      AFTER UPDATE OF id_photo_path OR DELETE trigger; never blocks a staff action.
--   guest_id_photo_purge_status_v1      what may be purged now (ids only, never names) plus the queue size and unqueued orphans.
--   guest_id_photo_purge_done_v1        clears a queue row ONLY when the storage object is really gone.
--   job_heartbeats                      'guest-id-photos-backup' (2 days) and 'guest-id-photos-drill' (monthly), so
--                                       job-heartbeat-monitor reports a dead backup task.
-- Object names are <companionId>/<uuid>.<ext>, never a guest name. Direct SQL deletes on storage.objects are blocked by
-- protect_objects_delete, so bytes are only ever deleted through the Storage API.

begin;

create table if not exists public.guest_id_photo_purge_queue (
  path text primary key,
  queued_at timestamptz not null default now(),
  source text not null check (source in ('delete', 'replace', 'sweep'))
);
comment on table public.guest_id_photo_purge_queue is
  'SPEC-40: guest-id-photos paths that lost their last guest_companions reference. Drained by the workstation backup run (Storage API, after the bytes are in the encrypted chain and on Alfred). No grants.';
alter table public.guest_id_photo_purge_queue enable row level security;
revoke all on public.guest_id_photo_purge_queue from public, anon, authenticated, service_role;

create or replace function public.guest_companions_release_photo()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.id_photo_path is null then return null; end if;
  if tg_op = 'UPDATE' and new.id_photo_path is not distinct from old.id_photo_path then return null; end if;
  -- AFTER ROW triggers fire at the end of the statement, so rows deleted by the same statement are already gone here.
  if exists (select 1 from public.guest_companions c where c.id_photo_path = old.id_photo_path) then return null; end if;
  -- Never block a staff action on bookkeeping: an odd path is simply not queued (the sweep reports it).
  if old.id_photo_path !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[^/]+$' then return null; end if;
  -- A path that was queued, re-referenced and then released again starts its 7 days over.
  insert into public.guest_id_photo_purge_queue(path, source)
  values (old.id_photo_path, case tg_op when 'DELETE' then 'delete' else 'replace' end)
  on conflict (path) do update set queued_at = now(), source = excluded.source;
  return null;
end $$;
revoke all on function public.guest_companions_release_photo() from public, anon, authenticated, service_role;

drop trigger if exists guest_companions_release_photo on public.guest_companions;
create trigger guest_companions_release_photo
  after update of id_photo_path or delete on public.guest_companions
  for each row execute function public.guest_companions_release_photo();

-- What the backup run may purge now (max 20, never younger than one day whatever the caller asks), and what it knows about.
create or replace function public.guest_id_photo_purge_status_v1(p_min_age interval default interval '7 days')
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'due', coalesce((select jsonb_agg(d.path order by d.queued_at, d.path) from (
        select q.path, q.queued_at from public.guest_id_photo_purge_queue q
         where q.queued_at <= now() - greatest(p_min_age, interval '1 day')
           and not exists (select 1 from public.guest_companions c where c.id_photo_path = q.path)
         order by q.queued_at, q.path
         limit 20) d), '[]'::jsonb),
    'queued', (select count(*) from public.guest_id_photo_purge_queue),
    'unqueued_orphans', (select count(*) from storage.objects o
        where o.bucket_id = 'guest-id-photos'
          and o.created_at < now() - interval '1 day'
          and o.name not like '%/.emptyFolderPlaceholder'
          and not exists (select 1 from public.guest_companions c where c.id_photo_path = o.name)
          and not exists (select 1 from public.guest_id_photo_purge_queue q where q.path = o.name)));
$$;

-- Clears queue rows ONLY for paths whose object is really gone (the caller cannot lie a row clear).
create or replace function public.guest_id_photo_purge_done_v1(p_paths text[])
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  delete from public.guest_id_photo_purge_queue q
   where q.path = any(p_paths)
     and not exists (select 1 from storage.objects o where o.bucket_id = 'guest-id-photos' and o.name = q.path);
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.guest_id_photo_purge_status_v1(interval) from public, anon, authenticated;
revoke all on function public.guest_id_photo_purge_done_v1(text[]) from public, anon, authenticated;
grant execute on function public.guest_id_photo_purge_status_v1(interval) to service_role;
grant execute on function public.guest_id_photo_purge_done_v1(text[]) to service_role;

-- last_succeeded_at = now() so the monitor does not alert before the first run: stale after 3 days (backup) / ~46 days (drill).
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at) values
  ('guest-id-photos-backup', 172800, false, now()),
  ('guest-id-photos-drill', 2678400, false, now())
on conflict (job_name) do nothing;

commit;
