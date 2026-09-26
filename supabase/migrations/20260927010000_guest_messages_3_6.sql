-- 20260927010000_guest_messages_3_6.sql
-- Session 56 (Opus 5): release guest_messages_3_6_20260927 - SPEC-05 messages 3-6 (D-174 final copy, D-249, D-257).
--
-- due_guest_messages_v1 keeps its signature and grants and learns four more keys (all times Asia/Manila):
--   mid_stay           5+ night stays (D-249): check-in day + 4 at 15:00, or day + 3 when the stay is 5 or 6 nights
--                      (check-out would fall within 2 days of day + 4); 6-hour window.
--   checkout_reminder  check-out day 09:00 until 12:00 - never after the noon check-out it talks about.
--   after_departure    check-out day 16:00, 6-hour window. The complaint skip rule lives in guest-messages (it still
--                      logs the key and posts the "please write personally" card).
--   door_code_offer    the ID is on file (guest_profile_details via booking_inquiries.guest_id) and check-in is today
--                      to 7 days out. It is logged as key door_code (a card to Finance, never a message, never a PIN).
-- The base set now includes check-out day itself (after_departure and checkout_reminder need it); confirmation keeps
-- its old "stay not over" bound. A logged key is never due again, whatever its status.
-- app_settings gains the three review links message 5.2 reads; a blank one drops its bullet.

begin;

create or replace function public.due_guest_messages_v1(p_now timestamptz default now())
returns table (booking_id uuid, message_key text)
language sql
stable
security definer
set search_path to ''
as $function$
  with t as (select (p_now at time zone 'Asia/Manila')::date as d),
  b as (
    select bi.id, bi.checkin_date, bi.checkout_date, bi.updated_at, bi.guest_id,
           bi.checkout_date - bi.checkin_date as nights
      from public.booking_inquiries bi, t
     where bi.status = 'confirmed'
       and bi.source = 'direct'
       and bi.checkout_date >= t.d
  ), due as (
    select b.id, 'confirmation'::text as k
      from b, t
     where b.updated_at > p_now - interval '48 hours'
       and b.checkout_date > t.d
    union all
    select b.id, 'pre_arrival'::text
      from b
     where p_now >= ((b.checkin_date - 2) + time '15:00') at time zone 'Asia/Manila'
       and p_now <  ((b.checkin_date - 2) + time '21:00') at time zone 'Asia/Manila'
       and not exists (
         select 1 from public.guest_message_log c
          where c.booking_id = b.id and c.message_key = 'confirmation'
            and c.created_at > ((b.checkin_date + time '14:00') at time zone 'Asia/Manila') - interval '48 hours')
    union all
    select b.id, 'mid_stay'::text
      from b
     where b.nights >= 5
       and p_now >= ((b.checkin_date + case when b.nights <= 6 then 3 else 4 end) + time '15:00') at time zone 'Asia/Manila'
       and p_now <  ((b.checkin_date + case when b.nights <= 6 then 3 else 4 end) + time '21:00') at time zone 'Asia/Manila'
    union all
    select b.id, 'checkout_reminder'::text
      from b
     where p_now >= (b.checkout_date + time '09:00') at time zone 'Asia/Manila'
       and p_now <  (b.checkout_date + time '12:00') at time zone 'Asia/Manila'
    union all
    select b.id, 'after_departure'::text
      from b
     where p_now >= (b.checkout_date + time '16:00') at time zone 'Asia/Manila'
       and p_now <  (b.checkout_date + time '22:00') at time zone 'Asia/Manila'
    union all
    select b.id, 'door_code_offer'::text
      from b
      join public.guest_profile_details g on g.guest_id = b.guest_id, t
     where g.id_on_file
       and b.checkin_date between t.d and t.d + 7
  )
  select d.id, d.k
    from due d
   where not exists (
     select 1 from public.guest_message_log l
      where l.booking_id = d.id
        and l.message_key = case d.k when 'door_code_offer' then 'door_code' else d.k end);
$function$;

revoke all on function public.due_guest_messages_v1(timestamptz) from public, anon, authenticated;
grant execute on function public.due_guest_messages_v1(timestamptz) to service_role;

-- Message 5.2's review links (public URLs; app_settings is anon-readable, which is fine for these). Lloyd fills the
-- Facebook and Google ones with one UPDATE each; blank drops the bullet, all three blank drops the list.
insert into public.app_settings (key, value) values
  ('review_airbnb_url', to_jsonb('https://airbnb.com/h/cascadesgsc'::text)),
  ('review_facebook_url', to_jsonb(''::text)),
  ('review_google_url', to_jsonb(''::text))
on conflict (key) do nothing;

commit;
