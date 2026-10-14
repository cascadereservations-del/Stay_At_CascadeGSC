-- 20261016000000_s82_inbox_push.sql
-- Session 82, lane XS (server): release s82_inbox_push_20261016. Cascade Staff 3.2, the Inbox push and manual power notices. Additive except three
-- function bodies, each behind an md5 guard that stops the release if the live body is not the one this was cut from.
--   1. Topics     staff_push_subscriptions.topics text[] (paid, inbox; default {paid}, so every existing phone keeps today's paid notice only).
--                 staff_push_subscribe_v1 gains an optional p_topics text[]. With p_topics null it behaves exactly as before (same checks, same
--                 upsert, same {ok:true}); with topics it merges them into the phone's row (asking for one never removes the other) and answers
--                 {ok:true, topics:[...]} with what was kept. `inbox` is kept only for an active owner/admin; anyone else asking for it keeps `paid`.
--                 The old 4-argument function is dropped and replaced by the 5-argument one (two overloads would make a 4-key RPC call ambiguous).
--                 staff_push_unsubscribe_topic_v1(endpoint, topic) removes one topic from the caller's own phone (the row goes with the last one).
--   2. Recipients staff_push_inbox_recipients_v1() (service role only): the subscriptions with topic inbox whose user is an ACTIVE owner/admin.
--   3. Claims     staff_push_claims + staff_push_claim_v1(p_key) (service role only): true once per key, so a guest message or a handover tells nobody
--                 twice. s_weekly_sweep_v1 (s82_staff_31) deletes claims older than 7 days.
--   3b. Notices   XS2 (Lloyd 2026-10-14, notifications on by default): a third topic `notices` for EVERY active staff role (cleaners included). The column
--                 default is {paid,notices}, so every existing phone (the ADD COLUMN fills them) and every new phone with p_topics null hears about a
--                 scheduled brownout or water interruption. staff_push_notice_recipients_v1(property) (service role only) lists those phones for people
--                 who are active staff of the property now. ops_notices_push_trg: AFTER INSERT on a brownout or water notice of the Cascade property it asks
--                 notify-staff-inbox (pg_net + vault secret, guarded like the paid trigger) to tell them; the function claims once and skips past dates.
--   3c. Cron      XS3: the pg_cron job rain-alert-2h (0 */2 * * *) is re-pointed so its call also carries x-cascade-cron-secret from the vault, because the
--                 new rain-alert function requires it. No-op where pg_cron is absent. Run this SQL before deploying rain-alert.
--   4. Power      ops_notice_add_v1 accepts type brownout (source stays manual). Every other rule is unchanged: no phone, e-mail or amount in the text,
--                 length and date limits, owner/admin only. notices_v1 already returns brownout rows (as type power).
-- Needs s82_staff_31 applied first (the sweep) and the s81 releases (the subscriptions, the notices): the guards stop the release otherwise.
-- Rollback: supabase/rollbacks/20261016_s82_inbox_push.sql

begin;

-- 0. guards: each replaced function must still be the body this release was cut from (md5 of prosrc, carriage returns stripped) ----------------
do $$
declare
  v_fn text; v_want text; v_got text;
begin
  for v_fn, v_want in select * from (values
    ('public.staff_push_subscribe_v1(text,text,text,text)', 'fbda406e0b4e4d80854ce1c383615080'),
    ('public.ops_notice_add_v1(text,text,date,time without time zone,numeric,text,uuid)', 'ee6211cfc99aa9735ea2f0f588f38e79'),
    ('public.s_weekly_sweep_v1()', 'a6082c2fca6d6f2cd136ce9057a1fc99')) v(a, b) loop
    select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure(v_fn);
    if v_got is null then raise exception 's82 inbox push: % does not exist (apply s81 and s82_staff_31 first)', v_fn using errcode = '55000'; end if;
    if v_got <> v_want then
      raise exception 's82 inbox push: % is not the body this release was cut from (md5 %): re-cut it from the live body', v_fn, v_got using errcode = '55000';
    end if;
  end loop;
end $$;

-- 1. topics on the subscriptions ---------------------------------------------------------------------------------------------------------
alter table public.staff_push_subscriptions add column if not exists topics text[] not null default '{paid,notices}';
alter table public.staff_push_subscriptions drop constraint if exists staff_push_subscriptions_topics_check;
alter table public.staff_push_subscriptions add constraint staff_push_subscriptions_topics_check
  check (cardinality(topics) between 1 and 3 and topics <@ array['paid', 'inbox', 'notices']::text[]);
comment on column public.staff_push_subscriptions.topics is 'S82: what this phone is told about: paid (a payment request was paid), notices (a scheduled brownout or water interruption, rain during a brownout; every active staff role) and/or inbox (a guest wrote or Cassy handed over; owner/admin only). Default {paid,notices}.';

drop function if exists public.staff_push_subscribe_v1(text, text, text, text);
create function public.staff_push_subscribe_v1(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null, p_topics text[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_kept text[]; v_topics text[];
begin
  if v_uid is null or not exists (select 1 from public.staff_access_profiles where user_id = v_uid and disabled_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  -- the endpoint is a URL the server will POST to: only the browsers' push services, https, no port, no credentials, a real dot before the suffix
  if coalesce(p_endpoint, '') !~* '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|([a-z0-9-]+\.)+(push\.apple\.com|notify\.windows\.com|push\.services\.mozilla\.com|pushnotifications\.push\.google\.com))(/|$)'
     or char_length(p_endpoint) > 1000
     or char_length(coalesce(p_p256dh, '')) not between 80 and 120 or char_length(coalesce(p_auth, '')) not between 16 and 40 then
    return jsonb_build_object('ok', false, 'reason', case when coalesce(p_endpoint, '') ~ '^https://' then 'endpoint_not_allowed' else 'bad_request' end);
  end if;
  if p_topics is null then
    -- today's callers: the paid notice only. A phone that already holds topics keeps them; a phone signed in as someone else starts again at paid.
    insert into public.staff_push_subscriptions(user_id, endpoint, p256dh, auth, user_agent)
    values (v_uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 200))
    on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent,
      topics = case when public.staff_push_subscriptions.user_id = excluded.user_id then public.staff_push_subscriptions.topics else excluded.topics end;
  else
    if cardinality(p_topics) = 0 or exists (select 1 from unnest(p_topics) t where t is null or t not in ('paid', 'inbox', 'notices')) then
      return jsonb_build_object('ok', false, 'reason', 'bad_topics');
    end if;
    -- paid and notices for any active staff member, inbox only for an active owner/admin; a topic list that ends up empty (a cleaner asking for inbox alone) keeps the paid notice
    v_kept := array(select distinct t from unnest(p_topics) t
                     where t in ('paid', 'notices') or (t = 'inbox' and exists (select 1 from public.staff_access_profiles p
                                                                   where p.user_id = v_uid and p.disabled_at is null and p.role in ('owner', 'admin')))
                     order by t);
    if cardinality(v_kept) = 0 then v_kept := array['paid']; end if;
    insert into public.staff_push_subscriptions(user_id, endpoint, p256dh, auth, user_agent, topics)
    values (v_uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 200), v_kept)
    on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent,
      topics = case when public.staff_push_subscriptions.user_id = excluded.user_id
                    then array(select distinct t from unnest(public.staff_push_subscriptions.topics || excluded.topics) t order by t)
                    else excluded.topics end;
  end if;
  delete from public.staff_push_subscriptions s
   where s.user_id = v_uid and s.id not in (select x.id from public.staff_push_subscriptions x where x.user_id = v_uid order by x.created_at desc, x.id limit 5);
  if p_topics is null then return jsonb_build_object('ok', true); end if;
  select s.topics into v_topics from public.staff_push_subscriptions s where s.endpoint = p_endpoint and s.user_id = v_uid;
  return jsonb_build_object('ok', true, 'topics', to_jsonb(coalesce(v_topics, v_kept)));
end $$;
revoke all on function public.staff_push_subscribe_v1(text, text, text, text, text[]) from public, anon, service_role;
grant execute on function public.staff_push_subscribe_v1(text, text, text, text, text[]) to authenticated;
comment on function public.staff_push_subscribe_v1(text, text, text, text, text[]) is 'S82: register or move this phone. p_topics null = the paid notice as before plus the notices topic for a new phone; else paid, notices and/or inbox merged into the phone''s row (inbox only for an active owner/admin). Answers {ok, topics} when topics were asked for.';

create function public.staff_push_unsubscribe_topic_v1(p_endpoint text, p_topic text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_topics text[];
begin
  if v_uid is null or not exists (select 1 from public.staff_access_profiles where user_id = v_uid and disabled_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  if p_topic is null or p_topic not in ('paid', 'inbox', 'notices') or p_endpoint is null then return jsonb_build_object('ok', false, 'reason', 'bad_request'); end if;
  select s.topics into v_topics from public.staff_push_subscriptions s where s.endpoint = p_endpoint and s.user_id = v_uid;
  -- not her phone, or the topic is not on it: nothing changes, and she is told what the phone holds (an empty list for a phone that is not hers)
  if v_topics is null or not (p_topic = any(v_topics)) then
    return jsonb_build_object('ok', true, 'topics', to_jsonb(coalesce(v_topics, '{}'::text[])));
  end if;
  -- the last topic gone: the phone no longer hears from us about anything, so the row goes (the browser keeps its own subscription)
  if cardinality(v_topics) = 1 then
    delete from public.staff_push_subscriptions where endpoint = p_endpoint and user_id = v_uid;
    return jsonb_build_object('ok', true, 'topics', '[]'::jsonb);
  end if;
  update public.staff_push_subscriptions set topics = array_remove(topics, p_topic) where endpoint = p_endpoint and user_id = v_uid returning topics into v_topics;
  return jsonb_build_object('ok', true, 'topics', to_jsonb(v_topics));
end $$;
revoke all on function public.staff_push_unsubscribe_topic_v1(text, text) from public, anon, service_role;
grant execute on function public.staff_push_unsubscribe_topic_v1(text, text) to authenticated;
comment on function public.staff_push_unsubscribe_topic_v1(text, text) is 'S82: remove one topic (paid, notices or inbox) from the caller''s own phone; the row is deleted with its last topic.';

-- 2. recipients ---------------------------------------------------------------------------------------------------------------------------
create function public.staff_push_inbox_recipients_v1() returns table(id uuid, endpoint text, p256dh text, auth text)
language sql stable security definer set search_path = '' as $$
  select s.id, s.endpoint, s.p256dh, s.auth
    from public.staff_push_subscriptions s
    join public.staff_access_profiles p on p.user_id = s.user_id
   where 'inbox' = any(s.topics) and p.disabled_at is null and p.role in ('owner', 'admin')
   order by s.created_at, s.id;
$$;
revoke all on function public.staff_push_inbox_recipients_v1() from public, anon, authenticated;
grant execute on function public.staff_push_inbox_recipients_v1() to service_role;
comment on function public.staff_push_inbox_recipients_v1() is 'S82 (service role): the phones that turned the Inbox push on, for people who are active owner/admin right now.';

create function public.staff_push_notice_recipients_v1(p_property_id uuid default '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd') returns table(id uuid, endpoint text, p256dh text, auth text)
language sql stable security definer set search_path = '' as $$
  select s.id, s.endpoint, s.p256dh, s.auth
    from public.staff_push_subscriptions s
    join public.staff_access_profiles p on p.user_id = s.user_id
   where 'notices' = any(s.topics) and p.disabled_at is null
     and exists (select 1 from public.staff_property_access a where a.user_id = s.user_id and a.property_id = p_property_id)
   order by s.created_at, s.id;
$$;
revoke all on function public.staff_push_notice_recipients_v1(uuid) from public, anon, authenticated;
grant execute on function public.staff_push_notice_recipients_v1(uuid) to service_role;
comment on function public.staff_push_notice_recipients_v1(uuid) is 'S82 (service role): the phones that hold the notices topic, for people who are active staff of the property right now (any role).';

-- 3. claims ------------------------------------------------------------------------------------------------------------------------------
create table if not exists public.staff_push_claims (
  key text primary key check (char_length(key) between 1 and 200),
  claimed_at timestamptz not null default now()
);
alter table public.staff_push_claims enable row level security;
revoke all on public.staff_push_claims from public, anon, authenticated;
grant select, insert, delete on public.staff_push_claims to service_role;
drop policy if exists staff_push_claims_service_all on public.staff_push_claims;
create policy staff_push_claims_service_all on public.staff_push_claims for all to service_role using (true) with check (true);
comment on table public.staff_push_claims is 'S82: one row per push event already told (key handover:<handoff> or guest_wrote:<psid>:<bucket>). Purged after 7 days by s_weekly_sweep_v1.';

create function public.staff_push_claim_v1(p_key text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  if p_key is null or char_length(p_key) not between 1 and 200 then return false; end if;
  insert into public.staff_push_claims(key) values (p_key) on conflict (key) do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;
revoke all on function public.staff_push_claim_v1(text) from public, anon, authenticated;
grant execute on function public.staff_push_claim_v1(text) to service_role;
comment on function public.staff_push_claim_v1(text) is 'S82 (service role): true the first time a key is claimed, false after. The sender claims before it sends.';

-- a scheduled brownout or water notice asks notify-staff-inbox to tell the staff. A failure here must never block the insert (power-watch, the Telegram notice
-- flow and ops_notice_add_v1 all insert here), so everything is guarded and dynamic: where pg_net or the vault secret is absent (a rehearsal copy) nothing is
-- sent. Only the Cascade property: a rehearsal fixture on its own property can never reach the live function. The function claims notice:<id> once and skips
-- a date in the past, so a second ask or a late insert is harmless.
create function public.ops_notices_push_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  if to_regnamespace('net') is null or to_regclass('vault.decrypted_secrets') is null then return null; end if;
  begin
    execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret' limit 1$q$ into v_secret;
    if coalesce(v_secret, '') = '' then return null; end if;
    perform net.http_post(
      url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/notify-staff-inbox',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cascade-cron-secret', v_secret),
      body := jsonb_build_object('kind', 'notice', 'notice_id', new.id),
      timeout_milliseconds := 20000);
  exception when others then
    raise warning 'ops_notices_push_trg: could not queue the notice push (%)', sqlstate;
  end;
  return null;
end $$;
revoke all on function public.ops_notices_push_trg() from public, anon, authenticated, service_role;
drop trigger if exists ops_notices_push on public.ops_notices;
create trigger ops_notices_push after insert on public.ops_notices
  for each row when (new.notice_type in ('brownout', 'water') and new.is_active and new.property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd')
  execute function public.ops_notices_push_trg();

-- the weekly sweep (s82_staff_31) also purges claims older than 7 days
create or replace function public.s_weekly_sweep_v1() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_secret text; v_id uuid; v_fired integer := 0; v_hashes integer := 0; v_progress integer := 0; v_claims integer := 0;
begin
  perform public.record_job_heartbeat('pay-weekly-sweep', 'started');
  delete from public.staff_upload_hashes where created_at < now() - interval '90 days';
  get diagnostics v_hashes = row_count;
  delete from public.cleaning_progress where day < (now() at time zone 'Asia/Manila')::date - 14;
  get diagnostics v_progress = row_count;
  delete from public.staff_push_claims where claimed_at < now() - interval '7 days';
  get diagnostics v_claims = row_count;
  -- same guards as staff_pay_notify_paid_trg: where pg_net or the vault secret is absent (a rehearsal copy) nothing is sent
  if to_regnamespace('net') is not null and to_regclass('vault.decrypted_secrets') is not null then
    begin
      execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret' limit 1$q$ into v_secret;
      if coalesce(v_secret, '') <> '' then
        for v_id in select * from public.s_paid_unnotified_v1() loop
          perform net.http_post(
            url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/notify-cleaner-payment',
            headers := jsonb_build_object('Content-Type', 'application/json', 'x-cascade-cron-secret', v_secret),
            body := jsonb_build_object('action', 'paid', 'request_id', v_id),
            timeout_milliseconds := 20000);
          v_fired := v_fired + 1;
        end loop;
      end if;
    exception when others then
      raise warning 's_weekly_sweep_v1: could not queue the paid notices (%)', sqlstate;
    end;
  end if;
  perform public.record_job_heartbeat('pay-weekly-sweep', 'succeeded');
  return jsonb_build_object('purged_upload_hashes', v_hashes, 'purged_progress_rows', v_progress, 'purged_push_claims', v_claims, 'paid_notices_asked', v_fired);
end $$;
revoke all on function public.s_weekly_sweep_v1() from public, anon, authenticated, service_role;

-- 4. ops_notice_add_v1: a brownout may be typed by hand (the only change: 'brownout' joins the type list) ----------------------------------------
create or replace function public.ops_notice_add_v1(
  p_type text, p_title text, p_date date, p_start_time time default null, p_duration_hours numeric default null,
  p_detail text default null, p_property_id uuid default null)
returns jsonb
language plpgsql volatile security definer
set search_path to ''
as $$
declare
  v_pid   uuid := coalesce(p_property_id,
                           (select s.property_id from public.staff_property_access s where s.user_id = auth.uid() order by s.property_id limit 1),
                           '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd');
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_title text := btrim(p_title);
  v_detail text := nullif(btrim(p_detail), '');
  v_id    uuid;
begin
  if not public.current_staff_authorized('manage_operations', v_pid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_type is null or p_type not in ('water', 'maintenance', 'deep_clean', 'note', 'brownout') then
    raise exception 'type_not_allowed' using errcode = '22023';
  end if;
  if v_title is null or char_length(v_title) < 1 or char_length(v_title) > 80 then
    raise exception 'title_length' using errcode = '22023';
  end if;
  if v_detail is not null and char_length(v_detail) > 200 then
    raise exception 'detail_length' using errcode = '22023';
  end if;
  -- a phone number, e-mail or amount is refused, never stored: the redaction helper would change it.
  if public.staff_redact_v1(v_title) <> v_title or (v_detail is not null and public.staff_redact_v1(v_detail) <> v_detail) then
    raise exception 'contact_or_amount_not_allowed' using errcode = '22023';
  end if;
  if p_date is null or p_date < v_today - 1 or p_date > v_today + 365 then
    raise exception 'date_out_of_range' using errcode = '22023';
  end if;
  if p_duration_hours is not null and (p_duration_hours <= 0 or p_duration_hours > 72) then
    raise exception 'duration_out_of_range' using errcode = '22023';
  end if;

  insert into public.ops_notices (property_id, notice_type, title, description, effective_date, effective_time, duration_hours, source, audience)
  values (v_pid, p_type, v_title, v_detail, p_date, p_start_time, p_duration_hours, 'manual', 'staff')
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'type', p_type, 'title', v_title, 'date', p_date);
end $$;
revoke all on function public.ops_notice_add_v1(text, text, date, time, numeric, text, uuid) from public, anon;
grant execute on function public.ops_notice_add_v1(text, text, date, time, numeric, text, uuid) to authenticated, service_role;
comment on function public.ops_notice_add_v1(text, text, date, time, numeric, text, uuid) is
  'Owner/admin: add a short manual water, maintenance, deep_clean, note or brownout notice. Phone numbers, e-mails and amounts are refused.';

-- 4b. rain-alert-2h: the cron job now signs its call (XS3) ----------------------------------------------------------------------------------
-- rain-alert pushes to every staff phone since XS2, so the function now requires x-cascade-cron-secret (or the service-role bearer). The job sent only the
-- publishable key, which is not a secret. Re-point it (same name, same schedule 0 */2 * * *) so it also sends the vault secret, read at call time, exactly like
-- release-expired-holds-hourly. Run this SQL BEFORE deploying the new rain-alert: the old function ignores the extra header, the new one needs it.
-- Where pg_cron is absent (a rehearsal copy) nothing happens; a job that already reads the vault secret is left alone.
do $$
declare v_id bigint; v_cmd text;
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron absent (rehearsal copy) - rain-alert-2h signing skipped';
    return;
  end if;
  execute $q$select jobid, command from cron.job where jobname = 'rain-alert-2h'$q$ into v_id, v_cmd;
  if v_id is null then
    raise warning 'rain-alert-2h is not scheduled here - nothing to re-point (read the forward check on production)';
    return;
  end if;
  if v_cmd like '%cascade_cron_shared_secret%' then
    raise notice 'rain-alert-2h already signs its call';
    return;
  end if;
  perform cron.alter_job(v_id, command := $cmd$select net.http_post(
        url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/rain-alert',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer sb_publishable_JFuRYZ9csmQULcMRmHXDSg_Abo9UeCj',
          'x-cascade-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret')
        ),
        body    := '{}'::jsonb,
        timeout_milliseconds := 60000
      ) as request_id;$cmd$);
  execute $q$select count(*) from cron.job where jobname = 'rain-alert-2h' and active and schedule = '0 */2 * * *' and command like '%cascade_cron_shared_secret%'$q$ into v_id;
  if v_id <> 1 then raise exception 'rain-alert-2h was not re-pointed'; end if;
end $$;

-- 5. final check -------------------------------------------------------------------------------------------------------------------------
do $$
begin
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'staff_push_subscribe_v1') <> 1 then raise exception 'staff_push_subscribe_v1 has more than one overload'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.staff_push_claims'::regclass) then raise exception 'staff_push_claims RLS not enabled'; end if;
  if has_table_privilege('authenticated', 'public.staff_push_claims', 'select,insert,update,delete') or has_table_privilege('anon', 'public.staff_push_claims', 'select,insert,update,delete') then
    raise exception 'staff_push_claims is open to an API role';
  end if;
  if has_function_privilege('authenticated', 'public.staff_push_claim_v1(text)', 'execute') or has_function_privilege('authenticated', 'public.staff_push_inbox_recipients_v1()', 'execute') then
    raise exception 'authenticated can run a service-only push function';
  end if;
  if has_function_privilege('anon', 'public.staff_push_subscribe_v1(text,text,text,text,text[])', 'execute') then raise exception 'anon can subscribe'; end if;
  if has_function_privilege('authenticated', 'public.staff_push_notice_recipients_v1(uuid)', 'execute') then raise exception 'authenticated can read the notice recipients'; end if;
  if not exists (select 1 from pg_trigger where tgname = 'ops_notices_push' and tgrelid = 'public.ops_notices'::regclass and not tgisinternal) then raise exception 'ops_notices_push trigger missing'; end if;
end $$;

commit;
