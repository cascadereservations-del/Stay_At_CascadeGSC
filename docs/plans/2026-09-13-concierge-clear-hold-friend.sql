-- Clear the 24 h human hold on the friend's test thread (set 2026-09-13 09:28:05Z by a Page
-- echo - the Away message automation or a manual inbox reply). Keeps history. Safe to re-run.
begin;
update public.concierge_threads set human_until = null where psid = '28174534122238309';
commit;
