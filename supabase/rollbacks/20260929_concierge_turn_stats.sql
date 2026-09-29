-- Compensating rollback for release concierge_turn_stats_20260929. Safe in any order: messenger-concierge's stats insert
-- is advisory (turn_stats_failed logged) and daily-digest's cassy_week_v1 read is advisory (the card goes out without it).
-- The week's stats rows are lost.
begin;
drop function if exists public.cassy_week_v1(timestamptz);
drop table if exists public.concierge_turn_stats;
commit;
