-- Rollback for release s81_staff_pay_push_20261014. Drops everything the release added. Existing pay objects are untouched, so Telegram settles keep working.
-- DATA LOSS (by design): staff_push_subscriptions rows (a staff member turns the toggle on again), staff_pay_requests.proof_path and
-- paid_notified_at (the screenshot itself stays in the cleaning-photos bucket and proof_file_id / proof_sha256 stay on the row),
-- staff_details.payout_bank_label. Apply with run-sql-on-host.sh.

begin;

drop trigger if exists staff_pay_notify_paid on public.staff_pay_requests;
drop function if exists public.staff_pay_notify_paid_trg();
drop function if exists public.staff_pay_notice_v1(uuid, text);
drop function if exists public.staff_pay_my_requests_v1();
drop function if exists public.staff_pay_admin_settle_v1(uuid, jsonb);
drop function if exists public.staff_pay_admin_step_v1(uuid, text);
drop function if exists public.staff_pay_payout_qr_v1(uuid);
drop function if exists public.staff_pay_admin_list_v1();
drop function if exists public.staff_push_subscribe_v1(text, text, text, text);
drop table if exists public.staff_push_subscriptions;
alter table public.staff_details drop column if exists payout_bank_label;
alter table public.staff_pay_requests drop column if exists paid_notified_at;
alter table public.staff_pay_requests drop column if exists proof_path;

commit;
