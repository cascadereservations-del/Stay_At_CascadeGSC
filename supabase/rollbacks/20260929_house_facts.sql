-- Compensating rollback for release house_facts_20260929. Deploy messenger-concierge, telegram-cassy and telegram-expense
-- from waves 9ef15fc (before 2859e3b) first: the new concierge writes concierge_threads.verified_until.
begin;
drop table if exists public.house_facts;
alter table public.concierge_threads drop column if exists verified_until;
commit;
