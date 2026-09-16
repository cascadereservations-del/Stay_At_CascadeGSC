-- Session 26 (2026-09-16), Telegram plan §6.4: backfill the historical [URGENT] cleaner notes as
-- RESOLVED work orders so guest_context_v1 has history to show. Idempotent (raise_work_order_v1
-- keys on wo:cleaning_issue:cleaning_session:<id>:1). The two rows marked "duplicate submission"
-- (session 22 backfill) are skipped: same issue, same guest, already represented once.
-- Run AFTER the 20260916160000 migration is applied. Lloyd runs it with run-sql-on-host.sh.
begin;
with src as (
  select c.id, c.cleaned_at, c.last_guest_name,
         btrim(substring(c.notes from '\[URGENT\]\s*([^\n|]+)')) as issue
    from public.cleaning_sessions c
   where c.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
     and c.notes ilike '%[URGENT]%' and c.notes not ilike '%duplicate submission%'
), raised as (
  select s.id, s.cleaned_at, (public.raise_work_order_v1(
      '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', 'cleaning_issue', 'cleaning_session:' || s.id || ':1',
      left(s.issue, 200), 'Cleaner note after ' || s.last_guest_name || ' (' || s.cleaned_at::date || '): ' || s.issue, 'high'))->>'id' as wo_id
    from src s
)
update public.work_orders w
   set status = 'resolved', blocks_arrival = false,
       resolved_at = coalesce(w.resolved_at, r.cleaned_at),
       resolution = coalesce(w.resolution, 'Backfilled 2026-09-16 (session 26): historical cleaner note, treated as resolved.')
  from raised r
 where w.id = r.wo_id::uuid and w.status = 'open' and w.created_at > now() - interval '5 minutes';
commit;

-- Forward checks
select count(*) as backfilled from public.work_orders where source_kind = 'cleaning_issue' and status = 'resolved';           -- expect 5
select count(*) as still_open_from_backfill from public.work_orders where source_kind = 'cleaning_issue' and status = 'open'; -- expect 0
select public.guest_context_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', null, 'Dale Anwen De La Cerna')->>'last_issue';     -- expect gatulo ubos sa aircon
