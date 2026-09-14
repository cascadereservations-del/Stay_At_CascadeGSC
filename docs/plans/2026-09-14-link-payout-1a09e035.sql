-- Link the payout e-mail that arrived 2026-09-14 03:43Z (gmail 1a09e035ddc42201, PHP 1,561.90,
-- HMZCDZCYZX James Rebaya) to its stay. airbnb-email-sync still inserts payout rows without
-- reservation_id (the D-110 migration filled existing rows once); until the function is patched,
-- new payouts need this one-liner or the admin edit sheet.
begin;
select public.admin_audit_context_v1('link new payout e-mail 1a09e035ddc42201 to HMZCDZCYZX (session 12, Lloyd 2026-09-14)');
update public.transactions t
   set reservation_id = r.id, updated_at = now()
  from public.airbnb_reservations r
 where t.external_ref = '1a09e035ddc42201' and t.source = 'airbnb_payout_email' and t.reservation_id is null
   and r.confirmation_code = 'HMZCDZCYZX';
select 'unlinked_payouts' k, count(*)::text v from public.transactions where source = 'airbnb_payout_email' and status = 'confirmed' and reservation_id is null;
commit;
