-- 20261205000000_guide_v8_messages_analytics.sql
-- Guest guide v8.0.0: (1) two-way guest <-> host messages inside the guide, read and answered from the Cascade Staff app,
-- (2) privacy-safe usage analytics (which sections, cards and buttons guests open), read from the Staff app.
-- NOT APPLIED. Ships through the stay-site release flow (copy into stay-site/supabase/migrations, add a release contract,
-- rehearse with pgTAP, Lloyd runs the release block). Rollback: backend/rollback_20261205_guide_v8.sql. Checks: backend/verify_20261205_guide_v8.sql.
--
-- Design rules
--  * Additive only. No existing table or function body is changed. verify_booking is CALLED, not replaced.
--  * The guide never sees a table. Everything goes through SECURITY DEFINER functions with search_path ''.
--  * Guest auth = the guide's own check (check-in date + booking-name initial, verify_booking), minted into a random
--    session token. Only the sha256 of the token is stored. A token lives until checkout + 1 day.
--  * Minting is throttled per caller IP (8 failures / 15 min, like verify_admin_pin) and per check-in date (20 / 15 min).
--  * Messages hold no contact capture: the guide never asks for an e-mail or phone (Airbnb policy effective 2026-11-20,
--    "Limiting host-imposed contracts and other requirements"). It is an optional channel; Airbnb messaging stays offered.
--  * Analytics hold no personal data: a random per-device id, an optional thread id (verified guests), event name, section,
--    target id, a number, and a small meta object. No free text from the guest is ever logged as an event.
--  * Staff functions need an active owner/admin (current_staff_authorized('manage_guest_inbox', property)), the same gate as
--    the shared inbox (20260905040000).
--  * A new guest message asks notify-staff-inbox (pg_net + vault secret, guarded exactly like ops_notices_push_trg) to push
--    owner/admin phones with kind guest_wrote and psid 'guide:<thread id>' (fits that function's PSID pattern). Where pg_net or
--    the vault secret is absent (a rehearsal copy) nothing is sent and the insert still succeeds.

begin;

-- 0. guards -------------------------------------------------------------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.verify_booking(date,text,uuid)') is null then
    raise exception 'guide v8: public.verify_booking(date,text,uuid) missing' using errcode = '55000'; end if;
  if to_regprocedure('public.current_staff_authorized(text,uuid)') is null then
    raise exception 'guide v8: public.current_staff_authorized(text,uuid) missing' using errcode = '55000'; end if;
  if to_regclass('public.calendar_events') is null then
    raise exception 'guide v8: public.calendar_events missing' using errcode = '55000'; end if;
  if to_regclass('public.guide_threads') is not null then
    raise exception 'guide v8: already applied (public.guide_threads exists)' using errcode = '55000'; end if;
end $$;

-- 1. tables -------------------------------------------------------------------------------------------------------------------------------
create table public.guide_threads (
  id                uuid primary key default gen_random_uuid(),
  property_id       uuid not null references public.properties(id) on delete restrict,
  calendar_event_id uuid not null unique,
  checkin_date      date not null,
  checkout_date     date not null,
  guest_label       text not null check (char_length(guest_label) between 1 and 60),
  channel           text not null default 'airbnb' check (channel in ('airbnb','direct')),
  status            text not null default 'open' check (status in ('open','resolved')),
  last_guest_at     timestamptz,
  last_staff_at     timestamptz,
  guest_read_at     timestamptz,
  staff_read_at     timestamptz,
  created_at        timestamptz not null default now()
);

create table public.guide_sessions (
  token_hash  text primary key check (token_hash ~ '^[a-f0-9]{64}$'),
  thread_id   uuid not null references public.guide_threads(id) on delete cascade,
  expires_at  timestamptz not null,
  created_at  timestamptz not null default now()
);
create index guide_sessions_thread_idx on public.guide_sessions(thread_id);

create table public.guide_messages (
  id             uuid primary key default gen_random_uuid(),
  thread_id      uuid not null references public.guide_threads(id) on delete cascade,
  sender         text not null check (sender in ('guest','staff')),
  body           text not null check (char_length(btrim(body)) between 1 and 2000),
  staff_user_id  uuid references auth.users(id) on delete set null,
  client_msg_id  text not null check (char_length(client_msg_id) between 8 and 80),
  created_at     timestamptz not null default now(),
  unique (thread_id, client_msg_id)
);
create index guide_messages_thread_idx on public.guide_messages(thread_id, created_at);

create table public.guide_auth_attempts (
  id      bigint generated always as identity primary key,
  client  text not null check (char_length(client) between 1 and 80),
  tried_date date,
  ok      boolean not null,
  at      timestamptz not null default now()
);
create index guide_auth_attempts_idx on public.guide_auth_attempts(client, at desc);
create index guide_auth_attempts_date_idx on public.guide_auth_attempts(tried_date, at desc) where not ok;

create table public.guide_events (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  device     text not null check (device ~ '^[A-Za-z0-9_-]{8,40}$'),
  thread_id  uuid references public.guide_threads(id) on delete set null,
  verified   boolean not null default false,
  name       text not null check (name ~ '^[a-z][a-z0-9_]{1,39}$'),
  section    text check (section is null or section ~ '^[a-z0-9_-]{1,40}$'),
  target     text check (target is null or target ~ '^[A-Za-z0-9_:.-]{1,80}$'),
  value      numeric,
  meta       jsonb not null default '{}'::jsonb check (pg_column_size(meta) <= 600),
  version    text check (version is null or version ~ '^[0-9.]{1,12}$')
);
create index guide_events_at_idx on public.guide_events(at desc);
create index guide_events_device_idx on public.guide_events(device, at desc);

alter table public.guide_threads       enable row level security;
alter table public.guide_sessions      enable row level security;
alter table public.guide_messages      enable row level security;
alter table public.guide_auth_attempts enable row level security;
alter table public.guide_events        enable row level security;
revoke all on public.guide_threads, public.guide_sessions, public.guide_messages, public.guide_auth_attempts, public.guide_events
  from public, anon, authenticated;
-- no policies: only the SECURITY DEFINER functions below (and service_role) touch these tables.

-- 2. helpers ------------------------------------------------------------------------------------------------------------------------------
create function public.guide_token_thread_v1(p_token text) returns uuid
language sql stable security definer set search_path = '' as $$
  select s.thread_id from public.guide_sessions s
   where p_token is not null and char_length(p_token) between 32 and 128
     and s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and s.expires_at > now()
   limit 1;
$$;
revoke all on function public.guide_token_thread_v1(text) from public, anon, authenticated;

-- 3. guest: mint a session --------------------------------------------------------------------------------------------------------------
create function public.guide_session_v1(p_checkin_date date, p_initial text, p_client text default null,
  p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  -- throttle key: the caller's IP as PostgREST passes it (not chosen by the caller), else the client id they send
  v_ip text := nullif(split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', ''), ',', 1), '');
  v_client text := left(coalesce('ip:' || btrim(v_ip), nullif(btrim(p_client), ''), 'anon'), 80);
  v_fail_client int; v_fail_date int;
  v_vb jsonb; v_cal record; v_thread public.guide_threads%rowtype;
  v_token text; v_channel text; v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  select count(*) into v_fail_client from public.guide_auth_attempts
   where client = v_client and not ok and at > now() - interval '15 minutes';
  -- per check-in date: stops initial guessing for one stay even when the guesser rotates addresses
  select count(*) into v_fail_date from public.guide_auth_attempts
   where not ok and at > now() - interval '15 minutes' and tried_date = p_checkin_date;
  if v_fail_client >= 8 or v_fail_date >= 20 then
    return jsonb_build_object('ok', false, 'reason', 'throttled', 'throttled', true);
  end if;

  if p_checkin_date is null or p_initial is null or char_length(btrim(p_initial)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'missing');
  end if;

  v_vb := public.verify_booking(p_checkin_date, left(btrim(p_initial), 1), p_property_id);
  if v_vb is null or (v_vb->>'found') = 'false' or (v_vb->>'match') is distinct from 'true' then
    insert into public.guide_auth_attempts(client, tried_date, ok) values (v_client, p_checkin_date, false);
    return jsonb_build_object('ok', false, 'reason', case when (v_vb->>'expired') = 'true' then 'expired' else 'no_match' end);
  end if;
  if (v_vb->>'expired') = 'true' then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  -- messaging opens three days before arrival and closes the day after checkout (the guide's own expiry)
  if p_checkin_date > v_today + 3 then
    return jsonb_build_object('ok', false, 'reason', 'too_early', 'opens_on', p_checkin_date - 3);
  end if;

  select id, raw_summary into v_cal from public.calendar_events
   where property_id = p_property_id and status = 'confirmed' and checkin_date = p_checkin_date
   order by updated_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_match'); end if;

  v_channel := case when coalesce(v_cal.raw_summary, '') ilike 'direct%' then 'direct' else 'airbnb' end;

  insert into public.guide_threads(property_id, calendar_event_id, checkin_date, checkout_date, guest_label, channel)
  values (p_property_id, v_cal.id, p_checkin_date, (v_vb->>'checkout_date')::date,
          left(coalesce(nullif(v_vb->>'first_name', ''), 'Guest'), 60), v_channel)
  on conflict (calendar_event_id) do update
     set checkout_date = excluded.checkout_date, guest_label = excluded.guest_label, channel = excluded.channel
  returning * into v_thread;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.guide_sessions(token_hash, thread_id, expires_at)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_thread.id,
          ((v_thread.checkout_date + 2)::timestamp at time zone 'Asia/Manila'));
  insert into public.guide_auth_attempts(client, tried_date, ok) values (v_client, p_checkin_date, true);

  return jsonb_build_object('ok', true, 'token', v_token, 'thread_id', v_thread.id, 'channel', v_thread.channel,
    'guest_label', v_thread.guest_label, 'checkin_date', v_thread.checkin_date, 'checkout_date', v_thread.checkout_date);
end;
$$;
revoke all on function public.guide_session_v1(date, text, text, uuid) from public;
grant execute on function public.guide_session_v1(date, text, text, uuid) to anon, authenticated;

-- 4. guest: read the thread ---------------------------------------------------------------------------------------------------------------
create function public.guide_thread_v1(p_token text, p_since timestamptz default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_thread uuid := public.guide_token_thread_v1(p_token); v_t public.guide_threads%rowtype;
begin
  if v_thread is null then return jsonb_build_object('ok', false, 'reason', 'session'); end if;
  update public.guide_threads set guest_read_at = now() where id = v_thread returning * into v_t;
  return jsonb_build_object('ok', true, 'thread_id', v_t.id, 'status', v_t.status, 'staff_read_at', v_t.staff_read_at,
    'messages', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'from', m.sender, 'body', m.body,
        'at', m.created_at, 'client_msg_id', m.client_msg_id) order by m.created_at)
      from (select * from public.guide_messages
             where thread_id = v_thread and (p_since is null or created_at > p_since)
             order by created_at desc limit 200) m), '[]'::jsonb));
end;
$$;
revoke all on function public.guide_thread_v1(text, timestamptz) from public;
grant execute on function public.guide_thread_v1(text, timestamptz) to anon, authenticated;

-- 5. guest: send ------------------------------------------------------------------------------------------------------------------------
create function public.guide_send_v1(p_token text, p_body text, p_client_msg_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_thread uuid := public.guide_token_thread_v1(p_token); v_body text := btrim(coalesce(p_body, '')); v_id uuid; v_at timestamptz; v_recent int;
begin
  if v_thread is null then return jsonb_build_object('ok', false, 'reason', 'session'); end if;
  if char_length(v_body) not between 1 and 2000 then return jsonb_build_object('ok', false, 'reason', 'length'); end if;
  if p_client_msg_id is null or char_length(p_client_msg_id) not between 8 and 80 then
    return jsonb_build_object('ok', false, 'reason', 'client_msg_id'); end if;
  select id, created_at into v_id, v_at from public.guide_messages where thread_id = v_thread and client_msg_id = p_client_msg_id;
  if found then return jsonb_build_object('ok', true, 'id', v_id, 'at', v_at, 'already', true); end if;
  select count(*) into v_recent from public.guide_messages
   where thread_id = v_thread and sender = 'guest' and created_at > now() - interval '1 hour';
  if v_recent >= 30 then return jsonb_build_object('ok', false, 'reason', 'rate'); end if;
  insert into public.guide_messages(thread_id, sender, body, client_msg_id)
  values (v_thread, 'guest', v_body, p_client_msg_id) returning id, created_at into v_id, v_at;
  update public.guide_threads set last_guest_at = v_at, status = 'open' where id = v_thread;
  return jsonb_build_object('ok', true, 'id', v_id, 'at', v_at);
end;
$$;
revoke all on function public.guide_send_v1(text, text, text) from public;
grant execute on function public.guide_send_v1(text, text, text) to anon, authenticated;

-- 6. guest: analytics batch -------------------------------------------------------------------------------------------------------------
create function public.guide_track_v1(p_device text, p_events jsonb, p_token text default null, p_version text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_thread uuid := public.guide_token_thread_v1(p_token); v_recent int; v_n int := 0; e jsonb;
begin
  if p_device is null or p_device !~ '^[A-Za-z0-9_-]{8,40}$' then return jsonb_build_object('ok', false, 'reason', 'device'); end if;
  if p_events is null or jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 50 then
    return jsonb_build_object('ok', false, 'reason', 'events'); end if;
  select count(*) into v_recent from public.guide_events where device = p_device and at > now() - interval '1 hour';
  if v_recent >= 600 then return jsonb_build_object('ok', false, 'reason', 'rate'); end if;
  for e in select * from jsonb_array_elements(p_events) loop
    begin
      insert into public.guide_events(at, device, thread_id, verified, name, section, target, value, meta, version)
      values (
        least(now(), greatest(now() - interval '2 days', coalesce((e->>'at')::timestamptz, now()))),
        p_device, v_thread, v_thread is not null,
        e->>'name', nullif(e->>'section', ''), nullif(e->>'target', ''),
        case when jsonb_typeof(e->'value') = 'number' then (e->>'value')::numeric end,
        case when jsonb_typeof(e->'meta') = 'object' then e->'meta' else '{}'::jsonb end,
        nullif(p_version, ''));
      v_n := v_n + 1;
    exception when others then null; -- one bad event never drops the batch
    end;
  end loop;
  return jsonb_build_object('ok', true, 'stored', v_n);
end;
$$;
revoke all on function public.guide_track_v1(text, jsonb, text, text) from public;
grant execute on function public.guide_track_v1(text, jsonb, text, text) to anon, authenticated;

-- 7. staff: inbox list, one thread, reply, resolve ---------------------------------------------------------------------------------------
create function public.staff_guide_threads_v1(p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce(public.current_staff_authorized('manage_guest_inbox', p_property_id), false) then
    raise exception using errcode = '42501', message = 'staff access denied'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', t.id, 'guest_label', t.guest_label, 'channel', t.channel, 'status', t.status,
      'checkin_date', t.checkin_date, 'checkout_date', t.checkout_date,
      'last_guest_at', t.last_guest_at, 'last_staff_at', t.last_staff_at,
      'unread', (select count(*) from public.guide_messages m where m.thread_id = t.id and m.sender = 'guest'
                   and m.created_at > coalesce(t.staff_read_at, 'epoch'::timestamptz)),
      'last', (select jsonb_build_object('from', m.sender, 'body', left(m.body, 140), 'at', m.created_at)
                 from public.guide_messages m where m.thread_id = t.id order by m.created_at desc limit 1))
    order by greatest(coalesce(t.last_guest_at, 'epoch'), coalesce(t.last_staff_at, 'epoch'), t.created_at) desc)
    from public.guide_threads t where t.property_id = p_property_id
      and t.checkout_date >= (now() at time zone 'Asia/Manila')::date - 30), '[]'::jsonb);
end;
$$;

create function public.staff_guide_thread_v1(p_thread_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_t public.guide_threads%rowtype;
begin
  select * into v_t from public.guide_threads where id = p_thread_id;
  if not found then raise exception using errcode = 'P0002', message = 'guide thread not found'; end if;
  if not coalesce(public.current_staff_authorized('manage_guest_inbox', v_t.property_id), false) then
    raise exception using errcode = '42501', message = 'staff access denied'; end if;
  update public.guide_threads set staff_read_at = now() where id = p_thread_id;
  return jsonb_build_object('thread', to_jsonb(v_t) - 'property_id',
    'messages', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'from', m.sender, 'body', m.body, 'at', m.created_at,
        'staff_user_id', m.staff_user_id) order by m.created_at) from public.guide_messages m where m.thread_id = p_thread_id), '[]'::jsonb));
end;
$$;

create function public.staff_guide_reply_v1(p_thread_id uuid, p_body text, p_client_msg_id text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_t public.guide_threads%rowtype; v_body text := btrim(coalesce(p_body, '')); v_id uuid; v_at timestamptz;
begin
  select * into v_t from public.guide_threads where id = p_thread_id;
  if not found then raise exception using errcode = 'P0002', message = 'guide thread not found'; end if;
  if not coalesce(public.current_staff_authorized('manage_guest_inbox', v_t.property_id), false) then
    raise exception using errcode = '42501', message = 'staff access denied'; end if;
  if char_length(v_body) not between 1 and 2000 then raise exception using errcode = '22023', message = 'reply length'; end if;
  if p_client_msg_id is null or char_length(p_client_msg_id) not between 8 and 80 then
    raise exception using errcode = '22023', message = 'client_msg_id'; end if;
  insert into public.guide_messages(thread_id, sender, body, staff_user_id, client_msg_id)
  values (p_thread_id, 'staff', v_body, auth.uid(), p_client_msg_id)
  on conflict (thread_id, client_msg_id) do nothing
  returning id, created_at into v_id, v_at;
  if v_id is null then
    select id, created_at into v_id, v_at from public.guide_messages where thread_id = p_thread_id and client_msg_id = p_client_msg_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'at', v_at, 'already', true);
  end if;
  update public.guide_threads set last_staff_at = v_at, staff_read_at = v_at where id = p_thread_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'at', v_at);
end;
$$;

create function public.staff_guide_resolve_v1(p_thread_id uuid, p_resolved boolean default true)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_t public.guide_threads%rowtype;
begin
  select * into v_t from public.guide_threads where id = p_thread_id;
  if not found then raise exception using errcode = 'P0002', message = 'guide thread not found'; end if;
  if not coalesce(public.current_staff_authorized('manage_guest_inbox', v_t.property_id), false) then
    raise exception using errcode = '42501', message = 'staff access denied'; end if;
  update public.guide_threads set status = case when p_resolved then 'resolved' else 'open' end where id = p_thread_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- 8. staff: usage report ------------------------------------------------------------------------------------------------------------------
create function public.staff_guide_usage_v1(p_days int default 30,
  p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
begin
  if not coalesce(public.current_staff_authorized('manage_guest_inbox', p_property_id), false) then
    raise exception using errcode = '42501', message = 'staff access denied'; end if;
  return jsonb_build_object(
    'since', v_since,
    'devices', (select count(distinct device) from public.guide_events where at >= v_since),
    'verified_stays', (select count(distinct thread_id) from public.guide_events where at >= v_since and thread_id is not null),
    'opens', (select count(*) from public.guide_events where at >= v_since and name = 'guide_open'),
    'by_day', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'devices', n, 'events', e) order by d) from (
        select (at at time zone 'Asia/Manila')::date d, count(distinct device) n, count(*) e
          from public.guide_events where at >= v_since group by 1) x), '[]'::jsonb),
    'sections', coalesce((select jsonb_agg(jsonb_build_object('section', section, 'views', n, 'devices', dv,
          'avg_seconds', secs) order by n desc) from (
        select section, count(*) filter (where name = 'section_view') n, count(distinct device) dv,
               round(avg(value) filter (where name = 'section_time'))::int secs
          from public.guide_events where at >= v_since and section is not null group by section) x), '[]'::jsonb),
    'top_taps', coalesce((select jsonb_agg(jsonb_build_object('target', target, 'section', section, 'taps', n, 'devices', dv) order by n desc)
        from (select target, section, count(*) n, count(distinct device) dv from public.guide_events
               where at >= v_since and name in ('tap','link_out','copy','call','map_open','sheet_open') and target is not null
               group by target, section order by count(*) desc limit 40) x), '[]'::jsonb),
    'funnel', jsonb_build_object(
        'verify_start', (select count(distinct device) from public.guide_events where at >= v_since and name = 'verify_start'),
        'verify_ok',    (select count(distinct device) from public.guide_events where at >= v_since and name = 'verify_ok'),
        'browse_guest', (select count(distinct device) from public.guide_events where at >= v_since and name = 'browse_guest'),
        'checklist_done', (select count(distinct device) from public.guide_events where at >= v_since and name = 'checklist_done'),
        'message_sent', (select count(*) from public.guide_messages m join public.guide_threads t on t.id = m.thread_id
                           where m.sender = 'guest' and m.created_at >= v_since and t.property_id = p_property_id)),
    'searches_without_result', coalesce((select jsonb_agg(jsonb_build_object('target', target, 'n', n) order by n desc) from (
        select target, count(*) n from public.guide_events where at >= v_since and name = 'search_empty' group by target
         order by count(*) desc limit 15) x), '[]'::jsonb));
end;
$$;

revoke all on function public.staff_guide_threads_v1(uuid), public.staff_guide_thread_v1(uuid),
  public.staff_guide_reply_v1(uuid, text, text), public.staff_guide_resolve_v1(uuid, boolean),
  public.staff_guide_usage_v1(int, uuid) from public, anon;
grant execute on function public.staff_guide_threads_v1(uuid), public.staff_guide_thread_v1(uuid),
  public.staff_guide_reply_v1(uuid, text, text), public.staff_guide_resolve_v1(uuid, boolean),
  public.staff_guide_usage_v1(int, uuid) to authenticated;

-- 9. push owner/admin phones on a new guest message ---------------------------------------------------------------------------------------
create function public.guide_messages_push_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  if new.sender <> 'guest' then return null; end if;
  if to_regnamespace('net') is null or to_regclass('vault.decrypted_secrets') is null then return null; end if;
  begin
    execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret' limit 1$q$ into v_secret;
    if v_secret is null then return null; end if;
    perform net.http_post(
      url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/notify-staff-inbox',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cascade-cron-secret', v_secret),
      body := jsonb_build_object('kind', 'guest_wrote', 'psid', 'guide:' || new.thread_id::text));
  exception when others then
    raise warning 'guide_messages_push_trg: could not queue the push (%)', sqlstate;
  end;
  return null;
end;
$$;
revoke all on function public.guide_messages_push_trg() from public, anon, authenticated;
create trigger guide_messages_push after insert on public.guide_messages
  for each row execute function public.guide_messages_push_trg();

-- 10. housekeeping: events older than 180 days and expired sessions go (call from the existing weekly sweep or pg_cron) ----------------
create function public.guide_sweep_v1() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare a int; b int; c int;
begin
  delete from public.guide_events where at < now() - interval '180 days'; get diagnostics a = row_count;
  delete from public.guide_sessions where expires_at < now(); get diagnostics b = row_count;
  delete from public.guide_auth_attempts where at < now() - interval '2 days'; get diagnostics c = row_count;
  return jsonb_build_object('events', a, 'sessions', b, 'attempts', c);
end;
$$;
revoke all on function public.guide_sweep_v1() from public, anon, authenticated;
grant execute on function public.guide_sweep_v1() to service_role;

commit;
