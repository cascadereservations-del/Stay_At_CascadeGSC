-- Session 72, SPEC-42 item 9a: a refund goes only to the account that paid (invariant I3).
-- The kind CHECK already allows refund_confirm (release 20261005100000 re-created it), so nothing is widened here.
-- upload-booking-receipt now keeps who paid, read off the guest's proof of payment, so telegram-expense /refund can compare the
-- recipient with it:
--   paid_from_name     the sender name printed on the first payment proof read for the booking (first read wins, written once by the Edge function)
--   paid_from_channel  the channel on that proof (GCash, Maya, a bank)
-- Both are nullable with no default: every existing booking has none, and /refund then asks for a typed reason instead of guessing.
-- Expand only: two nullable columns, two length checks that every existing row satisfies. No data change.
-- Only a proof-grade read (an amount found, confidence >= 0.5) is stored. If a wrong first read still claims the slot, clear it by hand (the next receipt then writes):
--   update public.booking_inquiries set paid_from_name = null, paid_from_channel = null where id = '<uuid>';
-- Rollback: supabase/rollbacks/20261006_refund_destination.sql
begin;

alter table public.booking_inquiries
  add column if not exists paid_from_name text,
  add column if not exists paid_from_channel text;

alter table public.booking_inquiries drop constraint if exists booking_inquiries_paid_from_name_len_check;
alter table public.booking_inquiries add constraint booking_inquiries_paid_from_name_len_check check (paid_from_name is null or char_length(paid_from_name) between 1 and 80);
alter table public.booking_inquiries drop constraint if exists booking_inquiries_paid_from_channel_len_check;
alter table public.booking_inquiries add constraint booking_inquiries_paid_from_channel_len_check check (paid_from_channel is null or char_length(paid_from_channel) between 1 and 40);

comment on column public.booking_inquiries.paid_from_name is 'Sender name on the first payment proof read for this booking. /refund compares the refund recipient with it (invariant I3). Written once by upload-booking-receipt.';
comment on column public.booking_inquiries.paid_from_channel is 'Channel on that payment proof (GCash, Maya, a bank). Shown beside the name on the /refund card.';

commit;
