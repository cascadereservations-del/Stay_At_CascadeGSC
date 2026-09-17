-- Session 29 read-back (D-158 method), reusable after each register run: remove every synthetic Messenger booking made
-- from Lloyd's profile as "Ben" with guest_email ben@example.com (example.com is reserved, never a real guest).
-- Same delete order as 2026-09-17-session28-delete-synthetic-tests.sql (FKs). Safe to re-run; with nothing to delete it is a no-op.
begin;
create temp table _s29_ids as select id, id::text as t, guest_id from public.booking_inquiries where guest_email = 'ben@example.com';
delete from public.booking_decisions            where booking_id in (select id from _s29_ids);
delete from public.payment_finance_reviews      where booking_id in (select id from _s29_ids);
delete from public.payment_evidence_comparisons where booking_id in (select id from _s29_ids);
delete from public.payment_evidence_candidates  where booking_id in (select id from _s29_ids);
delete from public.automation_outbox            where aggregate_id in (select id from _s29_ids);
delete from public.transactions                 where booking_id in (select id from _s29_ids) or external_ref in (select t from _s29_ids);
delete from public.calendar_events              where uid in (select 'direct:' || t from _s29_ids union all select 'cascade-direct-' || t from _s29_ids);
delete from public.airbnb_reservations          where confirmation_code in (select 'DIRECT:' || t from _s29_ids);
delete from public.booking_holds                where booking_id in (select id from _s29_ids);
delete from public.booking_inquiries            where id in (select id from _s29_ids);
-- guest rows only if nothing else references them (never by name)
delete from public.guests g where g.id in (select guest_id from _s29_ids where guest_id is not null)
   and not exists (select 1 from public.booking_inquiries b where b.guest_id = g.id)
   and not exists (select 1 from public.airbnb_reservations r where r.guest_id = g.id);
-- the Messenger thread stays (Lloyd's real profile); only the flow state and any hold are cleared
update public.concierge_threads set booking_flow = null, human_until = null where psid = '24786231807734398';
commit;
-- forward checks (expect 0 everywhere)
select 'inquiry' k, count(*) from public.booking_inquiries where guest_email = 'ben@example.com'
union all select 'flow', count(*) from public.concierge_threads where psid = '24786231807734398' and booking_flow is not null;
