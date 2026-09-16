-- Session 27 (D-158 method): remove the synthetic direct booking "Session Twentyseven" 4A19F743
-- (24-26 Sep 2026 hold + synthetic GCash receipt) after the evidence-producer and Telegram-tap tests.
-- Order matters for the FKs (booking_decisions -> payment_finance_reviews -> comparisons -> candidates).
-- The PNG in the private booking-receipts bucket (4a19f743-.../fbba57ac-....png) cannot be deleted by SQL.
begin;
delete from public.booking_decisions            where booking_id = '4a19f743-c9ec-4dc6-8582-c0139b798afe';
delete from public.payment_finance_reviews      where booking_id = '4a19f743-c9ec-4dc6-8582-c0139b798afe';
delete from public.payment_evidence_comparisons where booking_id = '4a19f743-c9ec-4dc6-8582-c0139b798afe';
delete from public.payment_evidence_candidates  where booking_id = '4a19f743-c9ec-4dc6-8582-c0139b798afe';
delete from public.automation_outbox            where aggregate_id = '4a19f743-c9ec-4dc6-8582-c0139b798afe';
delete from public.transactions                 where booking_id = '4a19f743-c9ec-4dc6-8582-c0139b798afe' or external_ref = '4a19f743-c9ec-4dc6-8582-c0139b798afe';
delete from public.airbnb_reservations          where confirmation_code = 'DIRECT:4a19f743-c9ec-4dc6-8582-c0139b798afe';
delete from public.calendar_events              where uid in ('direct:4a19f743-c9ec-4dc6-8582-c0139b798afe', 'cascade-direct-4a19f743-c9ec-4dc6-8582-c0139b798afe');
delete from public.booking_holds                where booking_id = '4a19f743-c9ec-4dc6-8582-c0139b798afe';
-- the synthetic guest row has no other bookings or reservations (checked 2026-09-17 01:10 Manila)
delete from public.guests where id = (select guest_id from public.booking_inquiries where id = '4a19f743-c9ec-4dc6-8582-c0139b798afe')
   and not exists (select 1 from public.booking_inquiries b where b.guest_id = public.guests.id and b.id <> '4a19f743-c9ec-4dc6-8582-c0139b798afe');
delete from public.booking_inquiries            where id = '4a19f743-c9ec-4dc6-8582-c0139b798afe';
commit;
-- forward checks (expect 0 everywhere)
select 'inquiry' k, count(*) from public.booking_inquiries where id = '4a19f743-c9ec-4dc6-8582-c0139b798afe'
union all select 'holds', count(*) from public.booking_holds where booking_id = '4a19f743-c9ec-4dc6-8582-c0139b798afe'
union all select 'candidates', count(*) from public.payment_evidence_candidates where booking_id = '4a19f743-c9ec-4dc6-8582-c0139b798afe'
union all select 'calendar', count(*) from public.calendar_events where uid like '%4a19f743-c9ec-4dc6-8582-c0139b798afe'
union all select 'guest', count(*) from public.guests where name = 'Session Twentyseven';
