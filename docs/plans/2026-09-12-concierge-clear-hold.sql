-- Clear only the 24 h human hold on Lloyd's test thread, keeping its history.
-- Run between handoff tests (discount, pets, injection) so the next message is answered.
begin;
update public.concierge_threads set human_until = null where psid = '24786231807734398';
commit;
