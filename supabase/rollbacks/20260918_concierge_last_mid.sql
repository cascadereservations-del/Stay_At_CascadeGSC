-- Compensating rollback for 20260918010000_concierge_last_mid.sql. Drops the dedup column; the
-- Concierge then answers a retried webhook twice again, which is the behaviour that existed before.
-- No conversation data is lost: last_mid holds only the id of the last message processed.
begin;
alter table public.concierge_threads drop column if exists last_mid;
commit;
