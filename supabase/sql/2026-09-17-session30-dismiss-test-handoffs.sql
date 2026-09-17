-- Session 30 (2026-09-17): the seven concierge_handoffs still 'open' are all TEST messages from the
-- 2026-09-13 Concierge build day, none from a real guest (read 2026-09-17): six from Lloyd's own profile
-- (psid 24786231807734398: dog, aircon, mall, deposit screenshot, cancel, discount) and one from the "Ben"
-- test thread (psid 28174534122238309: "may discount po ba"). They made Today list seven phantom handoffs.
-- Dismissed by id, only while still open, so a re-run is a no-op and nothing else can match.
begin;
update public.concierge_handoffs
   set status = 'dismissed', resolved_by = 'session30: 2026-09-13 test message', resolved_at = now()
 where status = 'open'
   and id in ('322b1f39-12ff-482a-8ac4-47913e00f4ed','ff9d6107-141c-443e-9b8f-2aa08e175921',
              '2e742511-a174-4a0f-9de1-326946357256','a02b426f-454e-4286-ab40-36d920571a7e',
              'b5e9ec41-1a2e-45b4-95a2-84577a27e8f1','37f029b6-3816-41ef-8438-dd5fe6779e51',
              '82a6cb04-ed95-4b96-a50a-3d367bc91c40');
select count(*) as still_open from public.concierge_handoffs where status = 'open';
commit;
