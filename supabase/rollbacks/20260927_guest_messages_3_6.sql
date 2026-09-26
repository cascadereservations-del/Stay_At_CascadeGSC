-- Compensating rollback for release guest_messages_3_6_20260927: due_guest_messages_v1 as release
-- guest_message_log_20260926 left it (confirmation and pre_arrival only), and the three review links removed.
-- guest-messages v2 still runs against it: it only ever sends what the function says is due.
begin;
create or replace function public.due_guest_messages_v1(p_now timestamptz default now())
returns table (booking_id uuid, message_key text)
language sql
stable
security definer
set search_path to ''
as $function$
  with b as (
    select bi.id, bi.checkin_date, bi.updated_at
      from public.booking_inquiries bi
     where bi.status = 'confirmed'
       and bi.source = 'direct'
       and bi.checkout_date > (p_now at time zone 'Asia/Manila')::date
  ), due as (
    select b.id, 'confirmation'::text as k
      from b
     where b.updated_at > p_now - interval '48 hours'
    union all
    select b.id, 'pre_arrival'::text
      from b
     where p_now >= ((b.checkin_date - 2) + time '15:00') at time zone 'Asia/Manila'
       and p_now <  ((b.checkin_date - 2) + time '21:00') at time zone 'Asia/Manila'
       and not exists (
         select 1 from public.guest_message_log c
          where c.booking_id = b.id and c.message_key = 'confirmation'
            and c.created_at > ((b.checkin_date + time '14:00') at time zone 'Asia/Manila') - interval '48 hours')
  )
  select d.id, d.k
    from due d
   where not exists (select 1 from public.guest_message_log l where l.booking_id = d.id and l.message_key = d.k);
$function$;
revoke all on function public.due_guest_messages_v1(timestamptz) from public, anon, authenticated;
grant execute on function public.due_guest_messages_v1(timestamptz) to service_role;
delete from public.app_settings where key in ('review_airbnb_url', 'review_facebook_url', 'review_google_url');
commit;
