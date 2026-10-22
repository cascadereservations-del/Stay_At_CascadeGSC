-- 2026-10-28 s95: READ-ONLY preview of the tier backfill. Run on production BEFORE 20261028000000_s95_guest_tiers.sql; changes nothing.
-- Prints how many guests of the property move from their stored tier (the old rule: returning at 2+ stays, "vip" at 4+ stays or 10+ nights) to the new effective tier
-- (vip 7+ stays or 20+ nights; regular 4+ or 10+; returning 2+; none), counting only completed stays: Airbnb completed, or confirmed with a checkout before today in Manila,
-- DIRECT:% mirrors skipped, plus confirmed booking_inquiries with a checkout before today. No hand-set tiers exist before the migration. Computed inline, not through the new functions.
begin read only;

with completed as (
  select a.guest_id, a.nights from public.airbnb_reservations a
   where a.guest_id is not null and a.confirmation_code not like 'DIRECT:%'
     and (a.status = 'completed' or (a.status = 'confirmed' and a.checkout_date < (now() at time zone 'Asia/Manila')::date))
  union all
  select b.guest_id, b.nights from public.booking_inquiries b
   where b.guest_id is not null and b.status = 'confirmed' and b.checkout_date < (now() at time zone 'Asia/Manila')::date),
agg as (select guest_id, count(*) stays, coalesce(sum(nights), 0) nights from completed group by guest_id),
g as (
  select gu.id, gu.tier old_tier, coalesce(ag.stays, 0) stays, coalesce(ag.nights, 0) nights
    from public.guests gu left join agg ag on ag.guest_id = gu.id
   where gu.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
select coalesce(old_tier, 'none') as old_tier,
       coalesce(case when stays >= 7 or nights >= 20 then 'vip' when stays >= 4 or nights >= 10 then 'regular' when stays >= 2 then 'returning' end, 'none') as new_tier,
       count(*) as guests
  from g
 group by 1, 2
 order by 1, 2;

commit;
