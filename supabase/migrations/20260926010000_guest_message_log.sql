-- 20260926010000_guest_message_log.sql
-- Session 54 (Opus 5): release guest_message_log_20260926 - SPEC-05 messages 1 and 2 (D-174, D-253, D-257).
--
-- A confirmed direct booking hears from us twice by code: message 1 (`confirmation`) the moment it is confirmed and
-- message 2 (`pre_arrival`, the balance and deposit reminder) on check-in day - 2 at 15:00 Manila. The guest-messages
-- Edge Function sends them (Messenger inside the 24-hour window, else e-mail through the relay, always a Telegram card).
-- guest_message_log is the once-only lock: the function inserts the row BEFORE it sends, so a primary-key conflict
-- means another run has it, and a crash leaves a 'failed' row as evidence. Messages 3-6 are out of scope; the check
-- constraint already names them so a later release adds no DDL.

begin;

create table if not exists public.guest_message_log (
  booking_id  uuid not null references public.booking_inquiries(id),
  message_key text not null check (message_key in ('confirmation', 'pre_arrival', 'door_code', 'mid_stay', 'checkout_reminder', 'after_departure')),
  channel     text not null check (channel in ('messenger', 'email', 'card_only')),
  status      text not null check (status in ('sent', 'failed', 'skipped')),
  detail      text,
  created_at  timestamptz not null default now(),
  primary key (booking_id, message_key)
);

alter table public.guest_message_log enable row level security;
revoke all on table public.guest_message_log from public, anon, authenticated;
grant select, insert, update on table public.guest_message_log to service_role;

-- What is due now. `confirmation`: a confirmed direct booking touched in the last 48 h whose stay is not over (the
-- hourly run catches a dashboard confirm; the Telegram tap calls the function at once). `pre_arrival`: from check-in
-- day - 2 at 15:00 Manila for 6 hours (one failed run is caught by the next), skipped when the booking was confirmed
-- less than 48 h before the 14:00 check-in (message 1 already carried the address and the payment line). Never a key
-- that has a log row, whatever its status. A cancelled booking returns nothing: status is read at send time.
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

-- record_job_heartbeat refuses an unknown job_name, so the hourly job's row is seeded here. 7200 s like
-- release-expired-holds-hourly: one late run is not an alert.
insert into public.job_heartbeats (job_name, expected_interval_seconds, ops_risk, last_succeeded_at)
values ('guest-messages-hourly', 7200, false, now())
on conflict (job_name) do nothing;

commit;
