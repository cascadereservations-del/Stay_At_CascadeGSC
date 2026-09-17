-- Session 28 (D-158 method): remove the synthetic Messenger booking CE442EBF (Lloyd as "Ben", psid 24786231807734398,
-- 3-4 Oct 2026 hold) after the receipt -> Confirm live test. Derived from the session-27 script.
-- Order matters for the FKs (booking_decisions -> payment_finance_reviews -> comparisons -> candidates).
-- The PNG in the private booking-receipts bucket (ce442ebf-3a50-4915-8279-071eabdd7cb0.../fbba57ac-....png) cannot be deleted by SQL.
begin;
delete from public.booking_decisions            where booking_id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0';
delete from public.payment_finance_reviews      where booking_id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0';
delete from public.payment_evidence_comparisons where booking_id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0';
delete from public.payment_evidence_candidates  where booking_id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0';
delete from public.automation_outbox            where aggregate_id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0';
delete from public.transactions                 where booking_id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0' or external_ref = 'ce442ebf-3a50-4915-8279-071eabdd7cb0';
delete from public.calendar_events              where uid in ('direct:ce442ebf-3a50-4915-8279-071eabdd7cb0', 'cascade-direct-ce442ebf-3a50-4915-8279-071eabdd7cb0');
delete from public.airbnb_reservations          where confirmation_code = 'DIRECT:ce442ebf-3a50-4915-8279-071eabdd7cb0';
delete from public.booking_holds                where booking_id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0';
delete from public.booking_inquiries            where id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0';
-- guest row by id (ca0f15fc = "Ben", total_stays 0, only this inquiry, 0 reservations - checked 2026-09-17 09:10 Manila); never by name
delete from public.guests g where g.id = 'ca0f15fc-b38c-4e84-af75-7675cf4f1e03'
   and not exists (select 1 from public.booking_inquiries b where b.guest_id = g.id)
   and not exists (select 1 from public.airbnb_reservations r where r.guest_id = g.id);
-- the Messenger thread stays (it is Lloyd's real profile); only the flow state is cleared
update public.concierge_threads set booking_flow = null where psid = '24786231807734398';
commit;
-- forward checks (expect 0 everywhere)
select 'inquiry' k, count(*) from public.booking_inquiries where id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0'
union all select 'holds', count(*) from public.booking_holds where booking_id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0'
union all select 'candidates', count(*) from public.payment_evidence_candidates where booking_id = 'ce442ebf-3a50-4915-8279-071eabdd7cb0'
union all select 'calendar', count(*) from public.calendar_events where uid like '%ce442ebf-3a50-4915-8279-071eabdd7cb0'
union all select 'flow', count(*) from public.concierge_threads where psid = '24786231807734398' and booking_flow is not null;
