-- 2026-09-23 (session 44, Lloyd's yes): retire the three internal outbox rows CH-W04 reports every morning
-- as "ANOMALIES FOUND - stale pending: 3" (F12, REVIEW-session-43-findings).
--
-- Nothing consumes route_class 'internal' (W01 dead by design, D-070), so these were never going to be
-- delivered. They become dead_letter, not completed: the CH-W04 sweep reads pending, dispatched, failed and
-- completed-without-a-delivery-record, so 'completed' would only move the noise to a new line tomorrow.
-- The outbox trigger fires AFTER INSERT only; an UPDATE dispatches nothing.
--
-- Guarded: exactly these three ids, only while still pending and internal. Any other count rolls back.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site.

begin;

do $$
declare n integer;
begin
  update public.automation_outbox
     set status = 'dead_letter',
         last_error_code = 'NO_CONSUMER_D070',
         completed_at = now()
   where id in ('d6d93cc9-50ff-4263-a619-2c9deaf1c5a9',
                '95538ebe-32be-4954-9f7b-711cd7dc2470',
                '4f0fbe73-1228-4b77-ba62-42f16e153b75')
     and status = 'pending'
     and route_class = 'internal';
  get diagnostics n = row_count;
  if n <> 3 then
    raise exception 'expected to retire 3 internal outbox rows, matched %; nothing changed', n;
  end if;
  raise notice 'retired % internal outbox rows as dead_letter', n;
end $$;

commit;
