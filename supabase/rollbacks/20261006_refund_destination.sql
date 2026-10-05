-- Compensating rollback for release refund_destination_20261006 (session 72, SPEC-42 9a).
-- Drops the two payer columns and their checks. Take a backup first: the stored payer names are lost.
-- Roll telegram-expense and upload-booking-receipt back first (the new code selects and writes these columns).
begin;
alter table public.booking_inquiries drop constraint if exists booking_inquiries_paid_from_name_len_check;
alter table public.booking_inquiries drop constraint if exists booking_inquiries_paid_from_channel_len_check;
alter table public.booking_inquiries drop column if exists paid_from_name, drop column if exists paid_from_channel;
commit;
