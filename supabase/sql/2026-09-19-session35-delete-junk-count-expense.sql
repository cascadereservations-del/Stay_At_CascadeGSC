-- One-off reviewed SQL (session 35, 2026-09-19, D-195). Run with run-sql-on-host.sh from stay-site.
-- Idempotent: keyed on one explicit id, re-running is a no-op.
--
-- Removes the junk expense the /count reply bug created. Lloyd replied "2 20" to the stock-count card;
-- the reply router could not match its marker (every check tests for a literal backtick that Telegram
-- strips from reply_to_message.text), so the message fell through to the ordinary expense parser and
-- was booked as PHP 2.00, category 'other', notes '20', status confirmed, source telegram, dated
-- 2026-09-19. It is not a real expense and it should not sit in the ledger or the monthly totals.
--
-- The BUG itself is not fixed by this file. That is D-195 and it goes to the next build session,
-- together with the reply-card UX rework Lloyd asked for in the same breath.
--
-- Check before running, in case another junk row was created the same way:
--   select id, gross_amount, category, notes, created_at from public.transactions
--    where source = 'telegram' and category = 'other' and gross_amount < 50 order by created_at desc;

begin;

delete from public.transactions
 where id = 'bf66bbf9-369d-4a66-a832-0767bf960ce6'
   and source = 'telegram'
   and category = 'other'
   and gross_amount = 2.00;

do $$
declare v_left int;
begin
  select count(*) into v_left from public.transactions
   where id = 'bf66bbf9-369d-4a66-a832-0767bf960ce6';
  if v_left <> 0 then
    raise exception 'junk expense survived: the row did not match all four guard conditions, check it by hand';
  end if;
  raise notice 'junk count-reply expense removed';
end $$;

commit;
