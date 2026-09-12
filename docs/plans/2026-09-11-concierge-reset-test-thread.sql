-- Reset the concierge smoke-test thread (Lloyd's own Messenger PSID) so the
-- 24 h human hold written by the failed 2026-09-11 01:52Z run does not silence
-- the retest. Safe to re-run; deletes only that one row.
begin;
delete from public.concierge_threads where psid = '24786231807734398';
commit;
