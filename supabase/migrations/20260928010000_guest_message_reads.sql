-- 20260928010000_guest_message_reads.sql
-- Session 56 fix: release guest_message_reads_20260928. Two service_role reads the session-56 code did as table reads,
-- which service_role may not do: work_orders and guest_profile_details are revoked from it (20260913100000; the pattern
-- since is a security-definer RPC, as raise_work_order_v1 / guest_context_v1). Found by the synthetic proof on
-- 2026-09-27 16:05 Manila: "permission denied for table work_orders", and the fail-safe held message 5.2 as "open
-- complaint" - every real guest's thank-you would have been held. The digest's ID read failed the same way.
--   guest_message_hold_v1(booking)  message 5.2 waits for a person: an OPEN complaint/safety handoff on the booking's
--                                   Messenger thread, or an OPEN work order raised on the stay's dates (Manila).
--   arrivals_without_id_v1(from,to) confirmed direct arrivals in [from, to] whose guest has no ID on file (or no profile).
-- Both service_role only. No table, column or existing grant changes.

begin;

create or replace function public.guest_message_hold_v1(p_booking_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
           select 1
             from public.concierge_handoffs h
             join public.concierge_threads t on t.psid = h.psid
            where t.booking_flow ->> 'booking_id' = p_booking_id::text
              and h.status = 'open'
              and h.risk in ('complaint', 'safety'))
      or exists (
           select 1
             from public.booking_inquiries b
             join public.work_orders w on w.property_id = b.property_id
            where b.id = p_booking_id
              and w.status = 'open'
              and (w.created_at at time zone 'Asia/Manila')::date between b.checkin_date and b.checkout_date);
$function$;

revoke all on function public.guest_message_hold_v1(uuid) from public, anon, authenticated;
grant execute on function public.guest_message_hold_v1(uuid) to service_role;

create or replace function public.arrivals_without_id_v1(p_from date, p_to date)
returns table (guest_name text, checkin_date date)
language sql
stable
security definer
set search_path to ''
as $function$
  select b.guest_name, b.checkin_date
    from public.booking_inquiries b
    left join public.guest_profile_details g on g.guest_id = b.guest_id
   where b.status = 'confirmed'
     and b.source = 'direct'
     and b.checkin_date between p_from and p_to
     and not coalesce(g.id_on_file, false)
   order by b.checkin_date;
$function$;

revoke all on function public.arrivals_without_id_v1(date, date) from public, anon, authenticated;
grant execute on function public.arrivals_without_id_v1(date, date) to service_role;

commit;
