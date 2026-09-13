-- 20260913150000_hmwax9dahz_cancelled_not_completed.sql (Cassy session 8, task 1)
-- HMWAX9DAHZ (Cüneyt, 11-26 Aug) was cancelled on 2026-08-10 (cancel email 19fec7e4eeddad9f,
-- status set to 'cancelled' correctly). On 2026-08-12 Airbnb paid the non-refunded share
-- (₱12,147.68, payout email 19ff411e85bb76df) and airbnb-email-sync's handlePayout set
-- status = 'completed' unconditionally, resurrecting 15 nights that were never stayed.
-- August occupancy reads 119 % because of this one row. The payout itself is real income and
-- its confirmed transaction row stays; only the reservation status is wrong.
-- Code fix in airbnb-email-sync (same session): a payout never flips 'cancelled' to 'completed'.
begin;

update public.airbnb_reservations
   set status = 'cancelled', updated_at = now()
 where confirmation_code = 'HMWAX9DAHZ'
   and status = 'completed'
   and cancelled_at is not null;

-- the payout also re-counted the stay in the guest's stats; recompute from the corrected row
select public.refresh_guest_stats(guest_id)
  from public.airbnb_reservations
 where confirmation_code = 'HMWAX9DAHZ' and guest_id is not null;

-- forward check: no reservation is both cancelled and not 'cancelled'
do $$
begin
  if exists (select 1 from public.airbnb_reservations where cancelled_at is not null and status <> 'cancelled') then
    raise exception 'a reservation with cancelled_at still carries a non-cancelled status';
  end if;
end $$;

commit;
