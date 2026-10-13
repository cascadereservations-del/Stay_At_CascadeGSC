-- s81: name the payee's bank for the "You were paid" notice (staff_details.payout_bank_label, added by
-- 20261014010000_s81_staff_pay_push.sql). One payee has a payout QR today; her preferred account is MariBank
-- (Lloyd, 2026-10-13). Not a migration: run once with run-sql-on-host.sh AFTER the s81_staff_pay_push release.
-- Reads the row count before and after; touches only rows that have a payout QR and no label yet; never prints the QR.
begin;
select count(*) as payees_with_qr, count(payout_bank_label) as labelled_before from public.staff_details where payout_qrph is not null;
update public.staff_details set payout_bank_label = 'MariBank' where payout_qrph is not null and payout_bank_label is null;
select count(*) as payees_with_qr, count(payout_bank_label) as labelled_after from public.staff_details where payout_qrph is not null;
commit;
