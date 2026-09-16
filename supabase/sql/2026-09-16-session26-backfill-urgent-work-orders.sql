-- Session 26 (2026-09-16), Telegram plan §6.4: backfill the historical [URGENT] cleaner notes as
-- RESOLVED work orders so guest_context_v1 has history to show. Idempotent (raise_work_order_v1
-- keys on wo:cleaning_issue:cleaning_session:<id>:1). The two rows marked "duplicate submission"
-- (session 22 backfill) are skipped: same issue, same guest, already represented once.
-- Run AFTER the 20260916160000 migration is applied. Lloyd runs it with run-sql-on-host.sh.
begin;
-- Step 1: raise (idempotent). A separate statement on purpose: inside an UPDATE ... FROM cte the
-- planner scanned work_orders first (0 recent rows) and never evaluated the CTE, so the first run
-- on 2026-09-16 inserted nothing (UPDATE 0).
select public.raise_work_order_v1(
    '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid, 'cleaning_issue', 'cleaning_session:' || c.id::text || ':1',
    left(btrim(substring(c.notes from '\[URGENT\]\s*([^\n|]+)')), 200),
    'Cleaner note after ' || c.last_guest_name || ' (' || c.cleaned_at::date || '): ' || btrim(substring(c.notes from '\[URGENT\]\s*([^\n|]+)')),
    'high') as raised
  from public.cleaning_sessions c
 where c.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'
   and c.notes ilike '%[URGENT]%' and c.notes not ilike '%duplicate submission%';
-- Step 2: mark them resolved, dated by the cleaning they came from.
update public.work_orders w
   set status = 'resolved', blocks_arrival = false,
       resolved_at = coalesce(w.resolved_at, c.cleaned_at),
       resolution = coalesce(w.resolution, 'Backfilled 2026-09-16 (session 26): historical cleaner note, treated as resolved.')
  from public.cleaning_sessions c
 where w.source_kind = 'cleaning_issue' and w.status = 'open'
   and w.source_ref = 'cleaning_session:' || c.id::text || ':1'
   and c.cleaned_at < now() - interval '1 day';
commit;

-- Forward checks
select count(*) as backfilled from public.work_orders where source_kind = 'cleaning_issue' and status = 'resolved';           -- expect 5
select count(*) as still_open_from_backfill from public.work_orders where source_kind = 'cleaning_issue' and status = 'open'; -- expect 0
select public.guest_context_v1('6ae230f4-c189-4547-84b1-cb6e0b2cc9bd', null, 'Dale Anwen De La Cerna')->>'last_issue';     -- expect gatulo ubos sa aircon
