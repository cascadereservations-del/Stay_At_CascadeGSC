-- Session 28 test series (D-158 method): remove the two synthetic Messenger bookings made from Lloyd's profile
-- ("Ben", psid 24786231807734398): F21FBEC9 (Oct 10-12, CONFIRMED via the Telegram tap - calendar, reservation and
-- ledger rows exist) and 395A8549 (Oct 25-27, pending hold). Guest rows are resolved from the bookings themselves.
-- Order matters for the FKs. The receipt PNG in the private booking-receipts bucket cannot be deleted by SQL.
begin;
create temp table _s28_guests as select distinct guest_id from public.booking_inquiries where id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb') and guest_id is not null;
delete from public.booking_decisions            where booking_id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
delete from public.payment_finance_reviews      where booking_id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
delete from public.payment_evidence_comparisons where booking_id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
delete from public.payment_evidence_candidates  where booking_id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
delete from public.automation_outbox            where aggregate_id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
delete from public.transactions                 where booking_id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb') or external_ref in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
delete from public.calendar_events              where uid in ('direct:f21fbec9-82c1-4199-9296-84aad72c5735', 'cascade-direct-f21fbec9-82c1-4199-9296-84aad72c5735', 'direct:395a8549-ab22-4b5d-8a33-a0bbd4c57cbb', 'cascade-direct-395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
delete from public.airbnb_reservations          where confirmation_code in ('DIRECT:f21fbec9-82c1-4199-9296-84aad72c5735', 'DIRECT:395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
delete from public.booking_holds                where booking_id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
delete from public.booking_inquiries            where id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb');
-- guest rows only if nothing else references them (never by name)
delete from public.guests g where g.id in (select guest_id from _s28_guests)
   and not exists (select 1 from public.booking_inquiries b where b.guest_id = g.id)
   and not exists (select 1 from public.airbnb_reservations r where r.guest_id = g.id);
-- the Messenger thread stays (Lloyd's real profile); only the flow state and any hold are cleared
update public.concierge_threads set booking_flow = null, human_until = null where psid = '24786231807734398';
commit;
-- forward checks (expect 0 everywhere)
select 'inquiry' k, count(*) from public.booking_inquiries where id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb')
union all select 'holds', count(*) from public.booking_holds where booking_id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb')
union all select 'calendar', count(*) from public.calendar_events where uid like '%f21fbec9-82c1-4199-9296-84aad72c5735' or uid like '%395a8549-ab22-4b5d-8a33-a0bbd4c57cbb'
union all select 'reservations', count(*) from public.airbnb_reservations where confirmation_code like 'DIRECT:f21fbec9%' or confirmation_code like 'DIRECT:395a8549%'
union all select 'transactions', count(*) from public.transactions where booking_id in ('f21fbec9-82c1-4199-9296-84aad72c5735', '395a8549-ab22-4b5d-8a33-a0bbd4c57cbb')
union all select 'flow', count(*) from public.concierge_threads where psid = '24786231807734398' and booking_flow is not null;
