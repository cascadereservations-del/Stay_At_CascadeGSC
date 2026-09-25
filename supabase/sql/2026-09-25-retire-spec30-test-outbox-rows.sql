-- 2026-09-25 (session 50): retire the outbox rows the SPEC-30 live test left (test@gmail.com, 18-19 and 18-20 Nov).
-- Nothing consumes booking.requested / booking.cancelled (D-234), so CH-W04 would report them every morning.
-- Same pattern as 2026-09-25-d234-prune-telegram-pending-and-retire-test-outbox.sql: dead_letter, not completed.
--
-- Run AFTER Lloyd declines request 5ee0b4e2 (18-20 Nov): the decline enqueues one more booking.cancelled row.
-- Guarded: refuses while 5ee0b4e2 is still pending; retires only pending rows of the two test requests and
-- expects 3 or 4 of them. Anything else rolls back.
-- Run with scripts/migrations/run-sql-on-host.sh from stay-site.

begin;

do $$
declare n integer;
begin
  if exists (select 1 from public.booking_inquiries
              where id = '5ee0b4e2-ab2e-4769-a6b3-a0f2f333ca17' and status = 'pending') then
    raise exception 'test request 5ee0b4e2 is still pending; decline it first, then run this again';
  end if;

  update public.automation_outbox
     set status = 'dead_letter',
         last_error_code = 'NO_CONSUMER_D070',
         completed_at = now()
   where aggregate_id in ('2c846866-2fb1-4d2b-8fa2-016ec4421c83',
                          '5ee0b4e2-ab2e-4769-a6b3-a0f2f333ca17')
     and status = 'pending';
  get diagnostics n = row_count;
  if n not in (3, 4) then
    raise exception 'expected 3 or 4 SPEC-30 test outbox rows, matched %; nothing changed', n;
  end if;
  raise notice 'retired % SPEC-30 test outbox rows as dead_letter', n;
end $$;

commit;

-- Forward check (true):
-- select count(*) = 0 from public.automation_outbox where status = 'pending' and aggregate_id in ('2c846866-2fb1-4d2b-8fa2-016ec4421c83','5ee0b4e2-ab2e-4769-a6b3-a0f2f333ca17');
