-- 20261206000000_guide_v8_messages_analytics.sql
-- Guest guide v8.0.0: (1) two-way guest <-> host messages inside the guide, read and answered from the Cascade Staff app,
-- (2) privacy-safe usage analytics (which sections, cards and buttons guests open), read from the Staff app.
-- NOT APPLIED. Ships through the stay-site release flow (release contract supabase/releases/20261206_guide_v8.release.json,
-- rehearsal with pgTAP on a restored copy, Lloyd runs the release block). Rollback: supabase/rollbacks/20261206_guide_v8.sql.
-- Checks: supabase/sql/2026-12-06-guide-v8-verify.sql. Single-property by design: the staff usage report answers only for the default property.
--
-- Design rules
--  * Additive only. No existing table or function body is changed. verify_booking is CALLED, not replaced.
--  * The guide never sees a table. Everything goes through SECURITY DEFINER functions with search_path ''.
--  * Guest auth = the guide's own check (check-in date + booking-name initial, verify_booking), minted into a random
--    session token. Only the sha256 of the token is stored. A token lives until the end of checkout + 1 day, Manila time
--    (expires_at = Manila midnight of checkout + 2 days); a stay whose expires_at has already passed gets no session (reason 'expired').
--  * A booking whose name is a placeholder (Reserved / Airbnb / Not / empty: verify_booking then matches ANY initial) never gets a
--    session: reason 'no_name'. Minting is throttled per caller IP (8 failures / 15 min, like verify_admin_pin; the key is
--    cf-connecting-ip, else the rightmost x-forwarded-for entry, each trimmed and accepted only when it looks like an address
--    (^[0-9A-Fa-f:.]{2,45}$), else the client id; never x-real-ip (a client can send it through the gateway) and never the client-controlled
--    leftmost x-forwarded-for entry), per check-in date
--    (10 failures / 15 min) and per thread (20 sessions / day, reason 'busy'). Concurrent mints for one check-in date are serialised by a
--    transaction advisory lock so the counts below cannot be raced past. The function carries lock_timeout = 2s (a function-level SET, restored by
--    PostgreSQL on every exit): a caller that cannot get the lock, or any other lock, within 2 s answers reason 'busy' and nothing it did is kept,
--    instead of queueing on a pooled connection.
--  * Messages hold no contact capture: the guide never asks for an e-mail or phone (Airbnb policy effective 2026-11-20,
--    "Limiting host-imposed contracts and other requirements"). It is an optional channel; Airbnb messaging stays offered.
--  * Analytics hold no name, contact detail or message text: a random per-device id, an optional thread id (verified guests), event
--    name, section, target (max 80 chars, letters digits and _:.- only, so no spaces), a number (at most 1e9 in size, rounded to 3 decimals,
--    else dropped), and a small meta object of whitelisted keys with short scalar values (at most 200 bytes as stored, pg_column_size, else meta
--    is dropped and the event kept). The one place a guest's own words can land is a search_empty event: its target keeps the guest's
--    single-token search term (max 80 chars) and the staff usage report shows those terms to staff (searches_without_result). No other free text.
--    Capped per device (600 / hour, reason 'rate') and across all devices (60 / minute and 1000 / rolling 24 h, then dropped silently: ok,
--    stored 0), counted by arrival time (received_at), not the client clock. The caps are exact: a batch is cut to the room that is left.
--  * STORAGE BOUND (Free plan: one 500 MB database that also holds the bookings and the ledger). guide_events is bounded WITHOUT any scheduled job.
--    - Rows: never more than 1000 events arrive in any rolling 24 h, and retention is 30 days enforced inline: every guide_track_v1 call that gets
--      the lock first deletes up to 200 rows older than 30 days (by received_at, index guide_events_received_idx), before it may add at most 50.
--      So the table never holds more than 30 x 1000 = 30000 rows: rows younger than 30 days are at most 30000, and while older rows exist every
--      call removes at least as many as it adds. If nobody calls, nothing is added either.
--    - Width: every column is bounded: device 40, name 40, section 40, target 80, version 12 characters, value a number of at most 13 digits
--      (CHECK), meta at most 200 bytes as stored (CHECK), thread id 16 bytes. A full-width row is about 500 bytes of heap plus four index entries.
--    - Worst case (30000 full-width rows, all four indexes, freshly loaded): under 30 MB, i.e. under 6 % of the plan. The pgTAP suite loads exactly
--      that and asserts it (the measured figure is in the release contract notes). Dead rows and index pages between autovacuum runs can add to
--      that for a while; even at 1.5 times the loaded size it stays under 45 MB. Typical use (short names, small meta, mostly unverified devices):
--      under 12 MB at the full 30000 rows (asserted too); a quiet guide (a few hundred events a day) holds under 10000 rows, about 3 MB.
--    - ACCEPTED: anyone can use up the 1000 / day budget in about 20 minutes (device ids are client-chosen; 60 a minute), after which analytics
--      are dropped silently for up to 24 h (ok, stored 0). The guide, the messages and the sign-in keep working; only usage numbers go missing.
--      The orchestrator ruling asked for 2000 / day; at full width that measured 46.8 MB (rehearsal r4), which is not "well under 50 MB", so
--      the day budget is 1000 (a stay produces a few hundred events a day).
--    - The reports follow the retention: staff_guide_usage_v1 answers for at most 30 days; staff_guide_guests_v1 (up to 90 days) takes names
--      and first / last sign-in from guide_sessions, and its event-based numbers (opens, checklist_done, a later last_seen) cover the last 30 days.
--  * guide_auth_attempts is bounded WITHOUT any scheduled job too. guide_session_v1 (a) answers a check-in date outside [Manila today - 90, today + 3] before
--    any count, lock or insert (too_early / expired, verify_booking not called, no row), and (b) before any insert deletes up to 200 attempts older than
--    2 days (oldest first, index guide_auth_attempts_at_idx). Rows kept are those of the last 2 days: failures are capped at 10 per check-in date in
--    any 15 minutes (exact, under the per-date advisory lock), so at most 94 dates x 10 x 192 fifteen-minute windows = 180480 failure rows, plus ok rows
--    (one per minted session, at most 20 sessions a thread a day, one thread per date: 94 x 20 x 2 = 3760): 184240 rows. Measured in the pgTAP suite
--    (test section 16): see the release contract notes.
--  * guide_messages: guest sends are capped at 30 an hour and 200 a rolling 24 hours per thread (reason 'rate'); the per-thread worst case is in the contract notes.
--  * guide_sweep_v1 (30-day events, sessions 95 days after expiry, attempts 2 days) is housekeeping only: the storage bound does not depend on
--    it. Sessions are kept 95 days past expiry because staff_guide_guests_v1 (p_days up to 90) lists guests from guide_sessions; the token helper
--    refuses an expired token regardless, so a kept row grants nothing. guide_sessions is small: at most 20 new rows a thread a day.
--  * Staff functions need an active owner/admin (current_staff_authorized('manage_guest_inbox', property)), the same gate as
--    the shared inbox (20260905040000).
--  * A new guest message asks notify-staff-inbox (pg_net + vault secret, guarded exactly like ops_notices_push_trg) to push
--    owner/admin phones with kind guest_wrote and psid 'guide:<thread id>' (fits that function's PSID pattern). Where pg_net or
--    the vault secret is absent (a rehearsal copy) nothing is sent and the insert still succeeds.


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
create index guide_auth_attempts_at_idx on public.guide_auth_attempts(at);   -- the inline trim in guide_session_v1 and the sweep read the oldest rows first

create table public.guide_events (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),   -- client clock, clamped to [now - 2 days, now]; used for reports
  received_at timestamptz not null default now(),  -- arrival time; used by the rate caps (a backdated 'at' cannot dodge them)
  device     text not null check (device ~ '^[A-Za-z0-9_-]{8,40}$'),
  thread_id  uuid references public.guide_threads(id) on delete set null,
  verified   boolean not null default false,
  name       text not null check (name ~ '^[a-z][a-z0-9_]{1,39}$'),
  section    text check (section is null or section ~ '^[a-z0-9_-]{1,40}$'),
  target     text check (target is null or target ~ '^[A-Za-z0-9_:.-]{1,80}$'),
  value      numeric check (value is null or (abs(value) <= 1000000000 and value = round(value, 3))),
  meta       jsonb not null default '{}'::jsonb check (pg_column_size(meta) <= 200),
  version    text check (version is null or version ~ '^[0-9.]{1,12}$')
);
-- ascending keys: events arrive in time order, so new entries go to the right-hand edge of each time index (pages stay about 90 % full) and the
-- inline retention empties whole pages at the left-hand edge.
create index guide_events_at_idx on public.guide_events(at);
create index guide_events_device_idx on public.guide_events(device, received_at);
create index guide_events_received_idx on public.guide_events(received_at);

alter table public.guide_threads       enable row level security;
alter table public.guide_sessions      enable row level security;
alter table public.guide_messages      enable row level security;
alter table public.guide_auth_attempts enable row level security;
alter table public.guide_events        enable row level security;
revoke all on public.guide_threads, public.guide_sessions, public.guide_messages, public.guide_auth_attempts, public.guide_events
  from public, anon, authenticated;
-- no policies: only the SECURITY DEFINER functions below (and service_role) touch these tables.
-- explicit ACLs: service_role (sweeps, exports) keeps full access; the identity sequences are closed to the client roles.
grant all on public.guide_threads, public.guide_sessions, public.guide_messages, public.guide_auth_attempts, public.guide_events to service_role;
revoke all on sequence public.guide_auth_attempts_id_seq, public.guide_events_id_seq from public, anon, authenticated;
grant usage, select on sequence public.guide_auth_attempts_id_seq, public.guide_events_id_seq to service_role;

-- 2. helpers ------------------------------------------------------------------------------------------------------------------------------
create function public.guide_token_thread_v1(p_token text) returns uuid
language sql stable security definer set search_path = '' as $$
  select s.thread_id from public.guide_sessions s
   where p_token is not null and char_length(p_token) between 32 and 128
     and s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     and s.expires_at > now()
   limit 1;
$$;
-- ML-21 grants, restated in full for every function of this release. service_role is revoked wherever nothing needs it: grep of supabase/functions
-- finds no edge function that calls any guide_* or staff_guide_* function (the push goes the other way, from the trigger to notify-staff-inbox through
-- pg_net), and the definer functions call this helper as the owner. Only guide_sweep_v1 keeps service_role (weekly sweep / pg_cron).
revoke all on function public.guide_token_thread_v1(text) from public, anon, authenticated, service_role;

-- 3. guest: mint a session --------------------------------------------------------------------------------------------------------------
create function public.guide_session_v1(p_checkin_date date, p_initial text, p_client text default null,
  p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' set lock_timeout = '2s' as $$
declare
  -- throttle key: the caller's address as the edge reports it, tried in this order: cf-connecting-ip (written by Cloudflare itself), then the
  -- RIGHTMOST x-forwarded-for entry (the one the last trusted proxy appended). Each is trimmed and used only when it looks like an address
  -- (^[0-9A-Fa-f:.]{2,45}$); a garbage value is skipped. x-real-ip is NOT used: a client can send it and the gateway passes it through. The LEFTMOST
  -- x-forwarded-for entry is whatever the caller sent and is never used.
  -- With no usable header (a direct call, or a malformed request.headers setting) the key falls back to the client id the caller sends:
  -- rotating it is possible there, which is why the per-check-in-date cap below exists.
  v_hdr json; v_xff text[]; v_cand text; v_ip text; v_client text;
  v_fail_client int; v_fail_date int; v_minted int;
  v_vb jsonb; v_cal record; v_thread public.guide_threads%rowtype;
  -- Manila calendar date throughout (the property's clock); verify_booking itself judges expiry with the database date
  v_token text; v_channel text; v_today date := (now() at time zone 'Asia/Manila')::date; v_exp timestamptz;
begin
  -- request.headers is set by PostgREST; bad JSON, a non-object value or a missing setting must never raise: the key just falls back.
  begin
    v_hdr := nullif(current_setting('request.headers', true), '')::json;
    v_xff := string_to_array(coalesce(v_hdr->>'x-forwarded-for', ''), ',');
    foreach v_cand in array array[btrim(v_hdr->>'cf-connecting-ip'), btrim(v_xff[cardinality(v_xff)])] loop
      if v_cand ~ '^[0-9A-Fa-f:.]{2,45}$' then v_ip := v_cand; exit; end if;
    end loop;
  exception when others then
    v_ip := null;
  end;
  v_client := left(coalesce('ip:' || v_ip, nullif(btrim(p_client), ''), 'anon'), 80);

  -- Date window, BEFORE any count, lock or insert: only a check-in date from Manila today - 90 to today + 3 can ever be a real, signable stay (messaging opens
  -- 3 days before arrival; the longest stay the house takes ends well inside 90 days, and the token dies 2 days after checkout). Any other date is answered
  -- without calling verify_booking and WITHOUT writing an attempt row, so a caller cannot grow guide_auth_attempts by walking over random dates. A date after
  -- today + 3 answers too_early (the same answer a real far-future stay gets; it reveals nothing about bookings), a date before today - 90 answers expired.
  -- A null date is not in the window test: it falls through to the existing 'missing' answer (no row either).
  if p_checkin_date is not null then
    if p_checkin_date > v_today + 3 then
      return jsonb_build_object('ok', false, 'reason', 'too_early', 'opens_on', p_checkin_date - 3);
    end if;
    if p_checkin_date < v_today - 90 then
      return jsonb_build_object('ok', false, 'reason', 'expired');
    end if;
  end if;

  -- Serialise concurrent mints for the same check-in date: the throttle counts below are read-then-insert, so without this lock several
  -- parallel calls would all read the same count and slip past the 10-per-date cap together. The lock is held to the end of the transaction.
  -- The wait is capped by the function's own lock_timeout = 2s (see the exception clause at the end): a caller that cannot get the lock in time
  -- answers 'busy' instead of piling up on a pooled connection.
  perform pg_advisory_xact_lock(hashtext('guide_session:' || coalesce(p_checkin_date::text, '')));

  select count(*) into v_fail_client from public.guide_auth_attempts
   where client = v_client and not ok and at > now() - interval '15 minutes';
  -- per check-in date: stops initial guessing for one stay even when the guesser rotates addresses
  select count(*) into v_fail_date from public.guide_auth_attempts
   where not ok and at > now() - interval '15 minutes' and tried_date = p_checkin_date;
  if v_fail_client >= 8 or v_fail_date >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'throttled', 'throttled', true);
  end if;

  if p_checkin_date is null or p_initial is null or char_length(btrim(p_initial)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'missing');
  end if;

  -- Inline retention (no scheduled job): every call that can reach an insert first deletes up to 200 attempts older than 2 days, oldest first (index
  -- guide_auth_attempts_at_idx). The throttle windows are 15 minutes, so a row older than 2 days is never read. skip locked: a concurrent trim on
  -- another date's call takes other rows instead of waiting. A call adds at most one row, so while old rows exist every call removes more than it adds.
  delete from public.guide_auth_attempts
   where id in (select id from public.guide_auth_attempts where at < now() - interval '2 days' order by at limit 200 for update skip locked);

  v_vb := public.verify_booking(p_checkin_date, left(btrim(p_initial), 1), p_property_id);
  if v_vb is null or (v_vb->>'found') = 'false' or (v_vb->>'match') is distinct from 'true' then
    insert into public.guide_auth_attempts(client, tried_date, ok) values (v_client, p_checkin_date, false);
    return jsonb_build_object('ok', false, 'reason', case when (v_vb->>'expired') = 'true' then 'expired' else 'no_match' end);
  end if;
  if (v_vb->>'expired') = 'true' then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  -- verify_booking maps a placeholder name (Reserved / Airbnb / Not / empty) to first_name 'Guest' and then matches ANY initial: that is no
  -- proof of identity, so no thread and no token. It counts as a failed attempt so probing dates for such bookings is throttled.
  if lower(coalesce(nullif(btrim(v_vb->>'first_name'), ''), 'guest')) = 'guest' then
    insert into public.guide_auth_attempts(client, tried_date, ok) values (v_client, p_checkin_date, false);
    return jsonb_build_object('ok', false, 'reason', 'no_name');
  end if;
  -- messaging opens three days before arrival and closes the day after checkout (the guide's own expiry)
  if p_checkin_date > v_today + 3 then
    return jsonb_build_object('ok', false, 'reason', 'too_early', 'opens_on', p_checkin_date - 3);
  end if;
  -- the token's own expiry: Manila midnight at the start of checkout + 2 days, i.e. the end of the day after checkout, Manila time.
  -- verify_booking judges expiry with the database (UTC) date, which runs up to eight hours behind Manila: in that gap it still answers "not
  -- expired" for a stay whose token would already be dead on arrival. No thread and no session are created for it.
  v_exp := (((v_vb->>'checkout_date')::date + 2)::timestamp at time zone 'Asia/Manila');
  if v_exp <= now() then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  select id, raw_summary into v_cal from public.calendar_events
   where property_id = p_property_id and status = 'confirmed' and checkin_date = p_checkin_date
   order by updated_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_match'); end if;

  -- per thread: at most 20 sessions a day (a guest has a handful of devices; more is a loop or an attack)
  select count(*) into v_minted from public.guide_sessions s join public.guide_threads t on t.id = s.thread_id
   where t.calendar_event_id = v_cal.id and s.created_at > now() - interval '1 day';
  if v_minted >= 20 then
    return jsonb_build_object('ok', false, 'reason', 'busy');
  end if;

  v_channel := case when coalesce(v_cal.raw_summary, '') ilike 'direct%' then 'direct' else 'airbnb' end;

  insert into public.guide_threads(property_id, calendar_event_id, checkin_date, checkout_date, guest_label, channel)
  values (p_property_id, v_cal.id, p_checkin_date, (v_vb->>'checkout_date')::date,
          left(coalesce(nullif(v_vb->>'first_name', ''), 'Guest'), 60), v_channel)
  on conflict (calendar_event_id) do update
     set checkout_date = excluded.checkout_date, guest_label = excluded.guest_label, channel = excluded.channel
  returning * into v_thread;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  -- expires_at = v_exp: Manila midnight at the start of checkout + 2 days (the thread's checkout_date is the verified one, so it is the same value)
  insert into public.guide_sessions(token_hash, thread_id, expires_at)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_thread.id, v_exp);
  insert into public.guide_auth_attempts(client, tried_date, ok) values (v_client, p_checkin_date, true);

  return jsonb_build_object('ok', true, 'token', v_token, 'thread_id', v_thread.id, 'channel', v_thread.channel,
    'guest_label', v_thread.guest_label, 'checkin_date', v_thread.checkin_date, 'checkout_date', v_thread.checkout_date);
exception when lock_not_available then
  -- lock_timeout (2 s, function-level SET) ran out on the per-date advisory lock or on a row lock further down. Everything this call did is
  -- undone (the exception clause rolls the block back; no attempt row, no thread, no session) and the guest is told to try again.
  return jsonb_build_object('ok', false, 'reason', 'busy');
end;
$$;
revoke all on function public.guide_session_v1(date, text, text, uuid) from public, service_role;
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
revoke all on function public.guide_thread_v1(text, timestamptz) from public, service_role;
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
  -- and at most 200 guest messages per thread in any rolling 24 hours (30 an hour alone would allow 720 a day)
  select count(*) into v_recent from public.guide_messages
   where thread_id = v_thread and sender = 'guest' and created_at > now() - interval '24 hours';
  if v_recent >= 200 then return jsonb_build_object('ok', false, 'reason', 'rate'); end if;
  insert into public.guide_messages(thread_id, sender, body, client_msg_id)
  values (v_thread, 'guest', v_body, p_client_msg_id) returning id, created_at into v_id, v_at;
  update public.guide_threads set last_guest_at = v_at, status = 'open' where id = v_thread;
  return jsonb_build_object('ok', true, 'id', v_id, 'at', v_at);
end;
$$;
revoke all on function public.guide_send_v1(text, text, text) from public, service_role;
grant execute on function public.guide_send_v1(text, text, text) to anon, authenticated;

-- 6. guest: analytics batch -------------------------------------------------------------------------------------------------------------
-- Anonymous and unauthenticated by design, so it is capped four ways: 50 events a batch, 600 events an hour per device (reason 'rate'), 60 events
-- a minute across all devices, and 1000 events per rolling 24 hours across all devices (the last two drop the batch silently: ok, stored 0). The
-- caps count arrival time (received_at), not the client's clock, and are exact: a batch is cut to the room left under all three (the rest of it is
-- dropped). With the 30-day retention enforced inline below the table never holds more than 30000 rows; see the STORAGE BOUND in the header.
-- The global lock is only TRIED: when another call holds it this one answers ok, stored 0 (silent drop) and never waits.
-- value keeps a JSON number of at most 1e9 in size, rounded to 3 decimals (anything larger is stored as null: a client cannot store a number
-- thousands of digits long). meta keeps only the known keys below and only short scalar values (a number, a boolean, or a token-like string up to
-- 40 characters); anything else, free text included, is dropped before it is stored, and a meta object that is still over 200 bytes as stored
-- (pg_column_size) is replaced by '{}' (the event itself is kept). target is the one free-ish field: at most 80 token characters (no spaces);
-- for a search_empty event it holds the guest's single-token search term, which the staff usage report lists.
create function public.guide_track_v1(p_device text, p_events jsonb, p_token text default null, p_version text default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_thread uuid := public.guide_token_thread_v1(p_token); v_recent int; v_minute int; v_day int; v_room int; v_n int := 0; e jsonb; v_meta jsonb; v_val numeric;
begin
  if p_device is null or p_device !~ '^[A-Za-z0-9_-]{8,40}$' then return jsonb_build_object('ok', false, 'reason', 'device'); end if;
  if p_events is null or jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 50 then
    return jsonb_build_object('ok', false, 'reason', 'events'); end if;
  -- One global lock for the whole function: the caps below are count-then-insert, so without it parallel batches would all read the same
  -- count and together overshoot the global caps. Only TRIED: a caller that finds it taken drops its batch silently (ok, stored 0) instead of
  -- queueing on a pooled connection. Held to the end of the transaction.
  if not pg_try_advisory_xact_lock(hashtext('guide_track')) then
    return jsonb_build_object('ok', true, 'stored', 0);
  end if;
  -- Inline retention (no scheduled job needed): drop up to 200 events older than 30 days, oldest first (index guide_events_received_idx). It runs
  -- before the caps, so a call that is then refused or dropped still trims.
  delete from public.guide_events where id in (
    select id from public.guide_events where received_at < now() - interval '30 days' order by received_at limit 200);
  select count(*) into v_recent from public.guide_events where device = p_device and received_at > now() - interval '1 hour';
  if v_recent >= 600 then return jsonb_build_object('ok', false, 'reason', 'rate'); end if;
  select count(*) into v_minute from public.guide_events where received_at > now() - interval '1 minute';
  if v_minute >= 60 then return jsonb_build_object('ok', true, 'stored', 0); end if;
  select count(*) into v_day from public.guide_events where received_at > now() - interval '24 hours';
  if v_day >= 1000 then return jsonb_build_object('ok', true, 'stored', 0); end if;
  -- room left under all three caps (at least 1 here); the batch is cut to it, so no cap is ever overshot
  v_room := least(600 - v_recent, 60 - v_minute, 1000 - v_day);
  for e in select * from jsonb_array_elements(p_events) loop
    exit when v_n >= v_room;
    begin
      v_meta := '{}'::jsonb;
      if jsonb_typeof(e->'meta') = 'object' then
        select coalesce(jsonb_object_agg(m.key, m.value), '{}'::jsonb) into v_meta
          from jsonb_each(e->'meta') m
         where m.key in ('k', 'src', 'kind', 'lang', 'tab', 'theme', 'dir', 'n', 'from', 'to', 'result', 'method', 'status', 'count', 'len', 'ok')
           and (jsonb_typeof(m.value) in ('number', 'boolean')
                or (jsonb_typeof(m.value) = 'string' and (m.value #>> '{}') ~ '^[A-Za-z0-9_:.-]{1,40}$'));
        if pg_column_size(v_meta) > 200 then v_meta := '{}'::jsonb; end if;
      end if;
      v_val := case when jsonb_typeof(e->'value') = 'number' then (e->>'value')::numeric end;
      v_val := case when abs(v_val) <= 1000000000 then round(v_val, 3) end;
      insert into public.guide_events(at, device, thread_id, verified, name, section, target, value, meta, version)
      values (
        least(now(), greatest(now() - interval '2 days', coalesce((e->>'at')::timestamptz, now()))),
        p_device, v_thread, v_thread is not null,
        e->>'name', nullif(e->>'section', ''), nullif(e->>'target', ''),
        v_val,
        v_meta,
        nullif(p_version, ''));
      v_n := v_n + 1;
    exception when others then null; -- one bad event never drops the batch
    end;
  end loop;
  return jsonb_build_object('ok', true, 'stored', v_n);
end;
$$;
revoke all on function public.guide_track_v1(text, jsonb, text, text) from public, service_role;
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
      and exists (select 1 from public.guide_messages m where m.thread_id = t.id)
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
declare v_t public.guide_threads%rowtype; v_body text := btrim(coalesce(p_body, '')); v_id uuid; v_at timestamptz; v_recent int;
begin
  select * into v_t from public.guide_threads where id = p_thread_id;
  if not found then raise exception using errcode = 'P0002', message = 'guide thread not found'; end if;
  if not coalesce(public.current_staff_authorized('manage_guest_inbox', v_t.property_id), false) then
    raise exception using errcode = '42501', message = 'staff access denied'; end if;
  if char_length(v_body) not between 1 and 2000 then raise exception using errcode = '22023', message = 'reply length'; end if;
  if p_client_msg_id is null or char_length(p_client_msg_id) not between 8 and 80 then
    raise exception using errcode = '22023', message = 'client_msg_id'; end if;
  -- a replay of an existing client_msg_id is answered first: never counted, never refused
  select id, created_at into v_id, v_at from public.guide_messages where thread_id = p_thread_id and client_msg_id = p_client_msg_id;
  if found then return jsonb_build_object('ok', true, 'id', v_id, 'at', v_at, 'already', true); end if;
  select count(*) into v_recent from public.guide_messages
   where thread_id = p_thread_id and sender = 'staff' and created_at > now() - interval '1 hour';
  if v_recent >= 60 then return jsonb_build_object('ok', false, 'reason', 'rate'); end if;
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
-- SINGLE-PROPERTY: guide_events has no property column (an event is a device tapping a section of the one guest guide), so the report
-- belongs to the default property only (the id every s13x function defaults to). For any other property id it answers an empty, flagged object.
create function public.staff_guide_usage_v1(p_days int default 30,
  p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  -- exactly p_days Manila dates, today included: the window starts at Manila midnight of the first plotted day. p_days is clamped to 1..30:
  -- events are kept 30 days, so a longer window would only show empty days ("since" tells the client the window it really got).
  v_first date := (now() at time zone 'Asia/Manila')::date - (greatest(1, least(coalesce(p_days, 30), 30)) - 1);
  v_since timestamptz := ((now() at time zone 'Asia/Manila')::date - (greatest(1, least(coalesce(p_days, 30), 30)) - 1))::timestamp at time zone 'Asia/Manila';
begin
  if not coalesce(public.current_staff_authorized('manage_guest_inbox', p_property_id), false) then
    raise exception using errcode = '42501', message = 'staff access denied'; end if;
  if p_property_id is distinct from '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid then
    return jsonb_build_object('single_property', true, 'since', v_first, 'devices', 0, 'verified_stays', 0, 'opens', 0,
      'by_day', '[]'::jsonb, 'sections', '[]'::jsonb, 'top_taps', '[]'::jsonb, 'funnel', '{}'::jsonb, 'searches_without_result', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'since', v_first,
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

-- 8b. staff: guests who signed in to the guide ---------------------------------------------------------------------------------------------
-- One row per guide thread that has at least one guide_sessions row (a successful sign-in: guide_session_v1 mints a session only after verify_booking
-- matched a real name) and whose last_seen falls inside the window. Window = the last p_days Manila dates, today included (same rule as the usage report),
-- p_days clamped to 1..90. Same gate, same single-property rule and same error shape as staff_guide_usage_v1; the second argument has a default so
-- the one-argument call staff_guide_guests_v1(p_days) works.
-- Derivations (each from tables this migration creates):
--   thread_id, checkin_date, checkout_date : guide_threads.
--   guest_label : guide_threads.guest_label is the booking's first name only (guide_session_v1 stores verify_booking's first_name). Defence in depth: a
--                 label of several words is cut to "first-word L." (last word's initial, never a surname); an empty label, the placeholder 'Guest', or any
--                 label holding '@' or a digit (an e-mail, a phone, an id) becomes 'Guest'. The schema holds no surname, phone, e-mail or ID for a thread.
--   first_seen  : earliest guide_sessions.created_at of the thread (the first sign-in, any date).
--   last_seen   : latest of the thread's newest guide_sessions.created_at and newest verified guide_events.at (a returning guest reuses the token, so
--                 events, not new sessions, show the later visits); events only count inside the window.
--   opens       : greatest(guide_open events of the thread in the window, sessions minted in the window), so a guest who signed in is never shown with 0.
--   checklist_done : count of the thread's checklist_done events in the window (the guide emits one per ticked item; guide_events records it). 0 when none.
--   Events are kept 30 days (see STORAGE BOUND): for p_days above 30 the event-based parts (opens from events, checklist_done, a last_seen later than
--   the newest sign-in) cover the last 30 days only; guest, dates, first_seen and the sign-in based last_seen and opens cover the whole window,
--   because guide_sweep_v1 keeps sessions 95 days past their expiry.
--   messaged    : at least one guide_messages row with sender 'guest' on the thread (any date).
-- Order: last_seen desc (thread id breaks ties), capped at 60 rows; total is the uncapped count of threads inside the window.
create function public.staff_guide_guests_v1(p_days int default 30,
  p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_since timestamptz := ((now() at time zone 'Asia/Manila')::date - (greatest(1, least(coalesce(p_days, 30), 90)) - 1))::timestamp at time zone 'Asia/Manila';
  v_out jsonb;
begin
  if not coalesce(public.current_staff_authorized('manage_guest_inbox', p_property_id), false) then
    raise exception using errcode = '42501', message = 'staff access denied'; end if;
  if p_property_id is distinct from '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'::uuid then
    return jsonb_build_object('guests', '[]'::jsonb, 'total', 0, 'single_property', true); end if;
  with s as (
    select thread_id, min(created_at) as first_session, max(created_at) as last_session,
           count(*) filter (where created_at >= v_since) as sessions_in
      from public.guide_sessions group by thread_id),
  e as (
    select thread_id, max(at) as last_event,
           count(*) filter (where name = 'guide_open') as opens_in,
           count(*) filter (where name = 'checklist_done') as done_in
      from public.guide_events where thread_id is not null and at >= v_since group by thread_id),
  r as (
    select t.id, t.checkin_date, t.checkout_date, t.guest_label as raw_label,
           s.first_session as first_seen, greatest(s.last_session, e.last_event) as last_seen,
           greatest(coalesce(e.opens_in, 0), s.sessions_in)::int as opens, coalesce(e.done_in, 0)::int as checklist_done,
           exists (select 1 from public.guide_messages m where m.thread_id = t.id and m.sender = 'guest') as messaged
      from public.guide_threads t join s on s.thread_id = t.id left join e on e.thread_id = t.id
     where t.property_id = p_property_id),
  f as (
    select r.*, string_to_array(regexp_replace(btrim(r.raw_label), '\s+', ' ', 'g'), ' ') as w
      from r where r.last_seen >= v_since),
  l as (
    select f.*, case
        when nullif(btrim(f.raw_label), '') is null or f.raw_label ~ '[@0-9]' or lower(btrim(f.raw_label)) = 'guest' then 'Guest'
        when cardinality(f.w) = 1 then f.w[1]
        else f.w[1] || ' ' || upper(left(f.w[cardinality(f.w)], 1)) || '.' end as guest_label
      from f)
  select jsonb_build_object(
    'guests', coalesce((select jsonb_agg(jsonb_build_object('thread_id', x.id, 'guest_label', x.guest_label, 'checkin_date', x.checkin_date,
        'checkout_date', x.checkout_date, 'first_seen', x.first_seen, 'last_seen', x.last_seen, 'opens', x.opens,
        'checklist_done', x.checklist_done, 'messaged', x.messaged) order by x.last_seen desc, x.id)
      from (select * from l order by last_seen desc, id limit 60) x), '[]'::jsonb),
    'total', (select count(*) from f)) into v_out;
  return v_out;
end;
$$;

revoke all on function public.staff_guide_threads_v1(uuid), public.staff_guide_thread_v1(uuid),
  public.staff_guide_reply_v1(uuid, text, text), public.staff_guide_resolve_v1(uuid, boolean),
  public.staff_guide_usage_v1(int, uuid), public.staff_guide_guests_v1(int, uuid) from public, anon, service_role;
grant execute on function public.staff_guide_threads_v1(uuid), public.staff_guide_thread_v1(uuid),
  public.staff_guide_reply_v1(uuid, text, text), public.staff_guide_resolve_v1(uuid, boolean),
  public.staff_guide_usage_v1(int, uuid), public.staff_guide_guests_v1(int, uuid) to authenticated;
-- ML-21: the staff functions are for signed-in staff only (they need auth.uid()); service_role is revoked explicitly because a production default
-- privilege would otherwise grant it, instead of leaving the ACL implicit.

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
-- service_role is revoked too: PostgreSQL checks EXECUTE on a trigger function when the trigger is created, not when it fires, so inserts by service_role
-- (table grants stay) still run the trigger.
revoke all on function public.guide_messages_push_trg() from public, anon, authenticated, service_role;
create trigger guide_messages_push after insert on public.guide_messages
  for each row execute function public.guide_messages_push_trg();

-- 10. housekeeping: events older than 30 days, sessions 95 days past expiry, old attempts (optional weekly sweep or pg_cron; the storage bound does not depend on it)
create function public.guide_sweep_v1() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare a int; b int; c int;
begin
  delete from public.guide_events where received_at < now() - interval '30 days'; get diagnostics a = row_count;
  -- 95 days past expiry: staff_guide_guests_v1 (p_days max 90) reads guide_sessions; guide_token_thread_v1 refuses expired tokens anyway
  delete from public.guide_sessions where expires_at < now() - interval '95 days'; get diagnostics b = row_count;
  delete from public.guide_auth_attempts where at < now() - interval '2 days'; get diagnostics c = row_count;
  return jsonb_build_object('events', a, 'sessions', b, 'attempts', c);
end;
$$;
revoke all on function public.guide_sweep_v1() from public, anon, authenticated, service_role;
grant execute on function public.guide_sweep_v1() to service_role;

