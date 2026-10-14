-- Rollback for release s82_inbox_push_20261016. Compensating: puts the three replaced function bodies back to the exact bodies this release was cut from
-- (staff_push_subscribe_v1 as s81 shipped it, ops_notice_add_v1 as s81 shipped it, s_weekly_sweep_v1 as s82_staff_31 shipped it) and drops what it added.
-- DATA LOSS (by design): the topics column (a phone that held only the inbox topic is deleted, so it does not start hearing about payments), the
-- claims table (at most 7 days of "already told" keys). Brownouts typed by hand stay: they are valid rows under the old checks and still show in notices_v1.
-- A manual brownout can no longer be added after this rollback (type_not_allowed), as before the release.
-- Apply with run-sql-on-host.sh. The functions notify-staff-inbox and messenger-concierge may stay deployed: with the RPCs gone the sender answers
-- "rpc_failed" and sends nothing, the concierge ignores the answer.

begin;

-- phones without the paid topic (inbox-only or notices-only) go; the rest keep their paid notice
delete from public.staff_push_subscriptions where not ('paid' = any(topics));

drop trigger if exists ops_notices_push on public.ops_notices;
drop function if exists public.ops_notices_push_trg();
drop function if exists public.staff_push_notice_recipients_v1(uuid);
drop function if exists public.staff_push_claim_v1(text);
drop function if exists public.staff_push_inbox_recipients_v1();
drop function if exists public.staff_push_unsubscribe_topic_v1(text, text);
drop table if exists public.staff_push_claims;
drop function if exists public.staff_push_subscribe_v1(text, text, text, text, text[]);

alter table public.staff_push_subscriptions drop constraint if exists staff_push_subscriptions_topics_check;
alter table public.staff_push_subscriptions drop column if exists topics;

create or replace function public.staff_push_subscribe_v1(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
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
  -- the same phone signed in as someone else moves to that person: one endpoint, one owner
  insert into public.staff_push_subscriptions(user_id, endpoint, p256dh, auth, user_agent)
  values (v_uid, p_endpoint, p_p256dh, p_auth, left(p_user_agent, 200))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent;
  delete from public.staff_push_subscriptions s
   where s.user_id = v_uid and s.id not in (select x.id from public.staff_push_subscriptions x where x.user_id = v_uid order by x.created_at desc, x.id limit 5);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.staff_push_subscribe_v1(text, text, text, text) from public, anon, service_role;
grant execute on function public.staff_push_subscribe_v1(text, text, text, text) to authenticated;

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
  if p_type is null or p_type not in ('water', 'maintenance', 'deep_clean', 'note') then
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
  'Owner/admin: add a short manual water, maintenance, deep_clean or note notice. Phone numbers, e-mails and amounts are refused.';

create or replace function public.s_weekly_sweep_v1() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_secret text; v_id uuid; v_fired integer := 0; v_hashes integer := 0; v_progress integer := 0;
begin
  perform public.record_job_heartbeat('pay-weekly-sweep', 'started');
  delete from public.staff_upload_hashes where created_at < now() - interval '90 days';
  get diagnostics v_hashes = row_count;
  delete from public.cleaning_progress where day < (now() at time zone 'Asia/Manila')::date - 14;
  get diagnostics v_progress = row_count;
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
  return jsonb_build_object('purged_upload_hashes', v_hashes, 'purged_progress_rows', v_progress, 'paid_notices_asked', v_fired);
end $$;
revoke all on function public.s_weekly_sweep_v1() from public, anon, authenticated, service_role;

-- every restored body must be exactly the one this release was cut from
do $$
declare
  v_fn text; v_want text; v_got text;
begin
  for v_fn, v_want in select * from (values
    ('public.staff_push_subscribe_v1(text,text,text,text)', 'fbda406e0b4e4d80854ce1c383615080'),
    ('public.ops_notice_add_v1(text,text,date,time without time zone,numeric,text,uuid)', 'ee6211cfc99aa9735ea2f0f588f38e79'),
    ('public.s_weekly_sweep_v1()', 'a6082c2fca6d6f2cd136ce9057a1fc99')) v(a, b) loop
    select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure(v_fn);
    if v_got is distinct from v_want then raise exception 'rollback: % restored to md5 % (want %)', v_fn, v_got, v_want; end if;
  end loop;
end $$;

commit;
