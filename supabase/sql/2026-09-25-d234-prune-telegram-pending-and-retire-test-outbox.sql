-- 2026-09-25 (session 50, D-234 items 2 and 4): two small maintenance changes, one unit.
--
-- 1. Retire the two outbox rows the test booking DIR-1AE5902E left pending on 2026-09-24
--    (booking.requested finance, booking.cancelled guest). Nothing consumes them (D-234), so the CH-W04 sweep
--    would report them every morning. Same pattern as 2026-09-23-retire-three-internal-outbox-rows.sql:
--    dead_letter, not completed. The outbox trigger fires AFTER INSERT only; an UPDATE dispatches nothing.
-- 2. nightly-prune-logs gains one line: telegram_pending rows are otherwise purged only when an expense is
--    logged (telegram-expense), so an expired prompt can sit for days. Unscheduled by name and scheduled again
--    with the old body unchanged plus the new line.
--
-- Guarded: exactly these two ids, only while still pending. Any other count rolls back everything.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site.

begin;

do $$
declare n integer;
begin
  update public.automation_outbox
     set status = 'dead_letter',
         last_error_code = 'NO_CONSUMER_D070',
         completed_at = now()
   where id in ('eda3f8a3-32a2-4b86-a929-61f4453723cb',
                '6af0aed7-39bb-45e2-98c4-aaa3af20d67d')
     and status = 'pending'
     and aggregate_id = '1ae5902e-9701-4dc8-bb38-747fedd320f4';
  get diagnostics n = row_count;
  if n <> 2 then
    raise exception 'expected to retire 2 test-booking outbox rows, matched %; nothing changed', n;
  end if;
  raise notice 'retired % test-booking outbox rows as dead_letter', n;

  perform cron.unschedule('nightly-prune-logs');
  perform cron.schedule('nightly-prune-logs', '0 17 * * *', $cmd$
    delete from cron.job_run_details where end_time < now() - interval '90 days';
    delete from public.reconciliation_log where created_at < now() - interval '90 days';
    delete from public.calendar_sync_log where synced_at < now() - interval '90 days';
    delete from public.telegram_pending where expires_at < now() - interval '1 day';
    analyze public.calendar_events; analyze public.airbnb_transactions; analyze public.guests;
    analyze public.transactions; analyze public.cleaning_sessions; analyze public.inventory_items;
  $cmd$);
  raise notice 'nightly-prune-logs rescheduled with the telegram_pending line';
end $$;

commit;

-- Forward checks (every row true):
-- select count(*) = 0 from public.automation_outbox where status = 'pending' and aggregate_id = '1ae5902e-9701-4dc8-bb38-747fedd320f4';
-- select command like '%telegram_pending%' and schedule = '0 17 * * *' from cron.job where jobname = 'nightly-prune-logs';
