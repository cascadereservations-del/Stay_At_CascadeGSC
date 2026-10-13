-- Session 81, Lane C: release s81_staff_pay_push_20261014. The admin pays a staff payment request from a bank app by QR Ph, the system marks it
-- PAID only with a stored payment screenshot, and the staff member is told three ways (in-app notice, Telegram, Web Push).
-- Additive only: two columns, one column on staff_details, one table, nine functions, one trigger. No existing function is redefined, so
-- telegram-expense, notify-cleaner-payment (create) and the Finance Telegram taps keep working unchanged.
--
--   staff_pay_requests.proof_path / paid_notified_at   where the web-uploaded screenshot is stored; the once-only "we told her" stamp.
--   staff_details.payout_bank_label                     the bank name used in the notice ("MariBank"). Not a secret. Set by SQL once per person.
--   staff_push_subscriptions                            one row per phone that turned on "Tell me on this phone when I am paid". RLS: own rows only.
--   staff_push_subscribe_v1                             upsert by endpoint (a shared phone moves to the person signed in now), keeps the newest 5.
--   staff_pay_admin_list_v1       owner/admin/finance   open requests and the last 14 days of paid ones. No QR payload, no guest data.
--   staff_pay_payout_qr_v1        owner/admin/finance   the ONE reader of staff_details.payout_qrph for the browser. Open requests only.
--   staff_pay_admin_step_v1       owner/admin/finance   I am paying / sent / not sent / cancel: the Telegram step RPC with the signed-in actor.
--   staff_pay_admin_settle_v1     owner/admin/finance   PAID only with a stored screenshot (object exists), its sha256, amount and reference.
--   staff_pay_my_requests_v1      the cleaner           HER last 10 requests: status, ref, total, dates, bank reference. Nobody else's.
--   staff_pay_notice_v1           service_role          claim / release the once-only paid notice; returns what the notice sentences need.
--   staff_pay_notify_paid_trg     trigger               on status -> paid, asks notify-cleaner-payment (pg_net + vault secret) to tell her.
--                                                       Skipped silently where pg_net or the vault secret is absent (rehearsals).
-- The rule that a request cannot become PAID without a stored screenshot stays in the table (staff_pay_paid_needs_proof).

begin;

alter table public.staff_pay_requests add column if not exists proof_path text
  check (proof_path is null or (char_length(proof_path) <= 300 and proof_path ~ '^6ae230f4-c189-4547-84b1-cb6e0b2cc9bd/[0-9a-f-]{36}/' and position('..' in proof_path) = 0));
alter table public.staff_pay_requests add column if not exists paid_notified_at timestamptz;
comment on column public.staff_pay_requests.proof_path is 'Lane C: object in the private cleaning-photos bucket holding the payment screenshot uploaded in the Staff app. Telegram-settled requests keep proof_file_id instead.';
comment on column public.staff_pay_requests.paid_notified_at is 'Lane C: set once by staff_pay_notice_v1(claim) so the staff member is told she was paid at most once per channel run.';

alter table public.staff_details add column if not exists payout_bank_label text
  check (payout_bank_label is null or char_length(btrim(payout_bank_label)) between 2 and 40);
comment on column public.staff_details.payout_bank_label is 'Lane C: the name of the bank or e-wallet of payout_qrph, as it reads in the paid notice ("MariBank"). Set by SQL; null reads "your account".';

-- Web Push subscriptions ------------------------------------------------------------------------------------------------------------
create table if not exists public.staff_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.staff_access_profiles(user_id) on delete cascade,
  endpoint text not null unique check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  p256dh text not null check (char_length(p256dh) between 80 and 120),
  auth text not null check (char_length(auth) between 16 and 40),
  user_agent text check (user_agent is null or char_length(user_agent) <= 200),
  created_at timestamptz not null default now(),
  last_ok_at timestamptz
);
create index if not exists staff_push_subscriptions_user_idx on public.staff_push_subscriptions(user_id);
alter table public.staff_push_subscriptions enable row level security;
revoke all on public.staff_push_subscriptions from public, anon, authenticated;
grant select, delete on public.staff_push_subscriptions to authenticated;
grant select, update, delete on public.staff_push_subscriptions to service_role;
drop policy if exists staff_push_own_select on public.staff_push_subscriptions;
create policy staff_push_own_select on public.staff_push_subscriptions for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists staff_push_own_delete on public.staff_push_subscriptions;
create policy staff_push_own_delete on public.staff_push_subscriptions for delete to authenticated using (user_id = (select auth.uid()));
drop policy if exists staff_push_service_all on public.staff_push_subscriptions;
create policy staff_push_service_all on public.staff_push_subscriptions for all to service_role using (true) with check (true);
comment on table public.staff_push_subscriptions is 'Lane C: Web Push endpoints. A person reads and deletes only her own rows; rows are written through staff_push_subscribe_v1. The sender (service role) deletes an endpoint the push service answers 404 or 410 for.';

create or replace function public.staff_push_subscribe_v1(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not exists (select 1 from public.staff_access_profiles where user_id = v_uid and disabled_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  if coalesce(p_endpoint, '') !~ '^https://' or char_length(p_endpoint) > 1000
     or char_length(coalesce(p_p256dh, '')) not between 80 and 120 or char_length(coalesce(p_auth, '')) not between 16 and 40 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
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

-- Admin side -----------------------------------------------------------------------------------------------------------------------------
create or replace function public.staff_pay_admin_list_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'; v_rows jsonb;
begin
  if auth.uid() is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', q.id, 'ref', q.ref, 'status', q.status, 'payee_name', q.payee_name, 'total', q.total_amount, 'created_at', q.created_at,
      'paying_by_name', q.paying_by_name, 'paying_at', q.paying_at, 'sent_said_at', q.sent_said_at, 'paid_at', q.paid_at,
      'has_proof', q.proof_file_unique_id is not null, 'bank_reference', q.proof_reference,
      'has_qr', exists (select 1 from public.staff_details d where d.user_id = q.payee_user_id and d.payout_qrph is not null),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('kind', l ->> 'kind', 'date', l ->> 'date', 'type', l ->> 'type',
                                                              'description', l ->> 'description', 'amount', l -> 'amount') order by l ->> 'date'), '[]'::jsonb)
                  from jsonb_array_elements(q.lines) l)
    ) order by (q.status in ('requested', 'paying')) desc, q.created_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.staff_pay_requests r
           where r.property_id = c_prop
             and (r.status in ('requested', 'paying') or (r.status = 'paid' and r.paid_at > now() - interval '14 days'))
           order by (r.status in ('requested', 'paying')) desc, r.created_at desc limit 30) q;
  return jsonb_build_object('ok', true, 'requests', v_rows);
end $$;
revoke all on function public.staff_pay_admin_list_v1() from public, anon, service_role;
grant execute on function public.staff_pay_admin_list_v1() to authenticated;

-- The one browser reader of staff_details.payout_qrph. Owner/admin/finance only, open requests only, never cached by the caller.
create or replace function public.staff_pay_payout_qr_v1(p_request_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'; v_r public.staff_pay_requests%rowtype; v_qr text;
begin
  if auth.uid() is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  select * into v_r from public.staff_pay_requests where id = p_request_id and property_id = c_prop;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_r.status not in ('requested', 'paying') then return jsonb_build_object('ok', false, 'reason', 'not_open', 'status', v_r.status); end if;
  select d.payout_qrph into v_qr from public.staff_details d where d.user_id = v_r.payee_user_id;
  return jsonb_build_object('ok', true, 'id', v_r.id, 'ref', v_r.ref, 'status', v_r.status, 'payee_name', v_r.payee_name,
                            'total', v_r.total_amount, 'payout_qrph', v_qr);
end $$;
revoke all on function public.staff_pay_payout_qr_v1(uuid) from public, anon, service_role;
grant execute on function public.staff_pay_payout_qr_v1(uuid) to authenticated;
comment on function public.staff_pay_payout_qr_v1(uuid) is 'Lane C: returns staff_details.payout_qrph to owner/admin/finance for an OPEN request. The browser builds the amount QR from it on the device and keeps it only in memory.';

-- I am paying / payment sent / not sent / cancel: the existing Telegram step with the signed-in person as the actor. Proof is a different RPC.
create or replace function public.staff_pay_admin_step_v1(p_request_id uuid, p_step text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_name text;
begin
  if auth.uid() is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  if p_step not in ('pay', 'sent', 'not_sent', 'cancel') then return jsonb_build_object('ok', false, 'reason', 'bad_step'); end if;
  if not exists (select 1 from public.staff_pay_requests where id = p_request_id and property_id = c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')), 'Finance')
    into v_name from auth.users u where u.id = auth.uid();
  return public.telegram_staff_pay_step_v1(p_request_id, p_step, null, left(coalesce(v_name, 'Finance'), 30), null);
end $$;
revoke all on function public.staff_pay_admin_step_v1(uuid, text) from public, anon, service_role;
grant execute on function public.staff_pay_admin_step_v1(uuid, text) to authenticated;

-- Settle from the Staff app. p_proof = {path, sha256, amount, reference, override?}. The screenshot must already be stored (upload-photo put it
-- under <property>/<this user>/...), and its sha256, the amount read off it and the bank reference are required. An amount that is not the
-- request total is refused unless the person confirms it (override true), exactly like "Amount is right" in Telegram.
create or replace function public.staff_pay_admin_settle_v1(p_request_id uuid, p_proof jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_uid uuid := auth.uid();
  v_r public.staff_pay_requests%rowtype;
  v_path text; v_sha text; v_ref text; v_amt numeric; v_verdict text; v_other text; v_name text; v_res jsonb; v_prefix text;
begin
  if v_uid is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  select * into v_r from public.staff_pay_requests where id = p_request_id and property_id = c_prop for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if v_r.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', v_r.status, 'ref', v_r.ref); end if;

  if p_proof is null or jsonb_typeof(p_proof) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'bad_proof'); end if;
  v_path := btrim(coalesce(p_proof ->> 'path', ''));
  v_sha := lower(coalesce(p_proof ->> 'sha256', ''));
  v_ref := nullif(regexp_replace(upper(coalesce(p_proof ->> 'reference', '')), '[^A-Z0-9]', '', 'g'), '');
  v_prefix := c_prop::text || '/' || v_uid::text || '/';
  if v_sha !~ '^[0-9a-f]{64}$' or v_ref is null or char_length(v_ref) not between 4 and 64
     or coalesce(jsonb_typeof(p_proof -> 'amount'), '') <> 'number' or char_length(v_path) not between 40 and 300
     or left(v_path, length(v_prefix)) <> v_prefix or position('..' in v_path) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_proof');
  end if;
  v_amt := round((p_proof ->> 'amount')::numeric, 2);
  if v_amt <= 0 or v_amt > 10000000 then return jsonb_build_object('ok', false, 'reason', 'bad_proof'); end if;

  -- stored proof: the object must exist in the private bucket
  if not exists (select 1 from storage.objects o where o.bucket_id = 'cleaning-photos' and o.name = v_path) then
    return jsonb_build_object('ok', false, 'reason', 'no_stored_proof', 'ref', v_r.ref);
  end if;

  select o.ref into v_other from public.staff_pay_requests o
   where o.id <> v_r.id and (o.proof_sha256 = v_sha or o.proof_file_unique_id = 'web:' || v_path or o.proof_reference = v_ref) limit 1;
  if found then return jsonb_build_object('ok', false, 'reason', 'duplicate_proof', 'other_ref', v_other, 'ref', v_r.ref); end if;

  if abs(v_amt - v_r.total_amount) < 0.5 then v_verdict := 'match';
  elsif coalesce(p_proof ->> 'override', '') = 'true' then v_verdict := 'override';
  else return jsonb_build_object('ok', false, 'reason', 'amount_mismatch', 'typed', v_amt, 'total', v_r.total_amount, 'ref', v_r.ref);
  end if;

  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')), 'Finance')
    into v_name from auth.users u where u.id = v_uid;
  v_name := left(coalesce(v_name, 'Finance'), 30) || ' (Staff app)';

  begin
    v_res := public.staff_pay_settle_v1(v_r.id, null, v_name, v_verdict,
      jsonb_build_object('file_unique_id', 'web:' || v_path, 'file_id', v_path, 'sha256', v_sha, 'amount', v_amt, 'reference', v_ref,
                         'read', jsonb_build_object('source', 'staff_app', 'typed_by', v_uid)));
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_proof', 'ref', v_r.ref);
  end;
  if coalesce((v_res ->> 'ok')::boolean, false) then
    update public.staff_pay_requests
       set proof_path = v_path, paid_by_user_id = v_uid, sent_said_at = coalesce(sent_said_at, now())
     where id = v_r.id;
  end if;
  return v_res;
end $$;
revoke all on function public.staff_pay_admin_settle_v1(uuid, jsonb) from public, anon, service_role;
grant execute on function public.staff_pay_admin_settle_v1(uuid, jsonb) to authenticated;

-- Staff side: HER requests only ----------------------------------------------------------------------------------------------------
create or replace function public.staff_pay_my_requests_v1() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd'; v_uid uuid := auth.uid(); v_label text; v_rows jsonb;
begin
  if v_uid is null or not public.current_staff_authorized('submit_cleaning', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  select nullif(btrim(d.payout_bank_label), '') into v_label from public.staff_details d where d.user_id = v_uid;
  select coalesce(jsonb_agg(jsonb_build_object(
      'ref', q.ref, 'status', q.status, 'total', q.total_amount, 'created_at', q.created_at, 'paying_at', q.paying_at, 'paid_at', q.paid_at,
      'bank_reference', case when q.status = 'paid' then q.proof_reference end,
      'first_name', split_part(btrim(q.payee_name), ' ', 1),
      'date_from', (select min((l ->> 'date')::date) from jsonb_array_elements(q.lines) l),
      'date_to', (select max((l ->> 'date')::date) from jsonb_array_elements(q.lines) l),
      'bank_label', v_label) order by q.created_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.staff_pay_requests r where r.payee_user_id = v_uid order by r.created_at desc limit 10) q;
  return jsonb_build_object('ok', true, 'requests', v_rows);
end $$;
revoke all on function public.staff_pay_my_requests_v1() from public, anon, service_role;
grant execute on function public.staff_pay_my_requests_v1() to authenticated;
comment on function public.staff_pay_my_requests_v1() is 'Lane C: the caller''s own last 10 payment requests (payee_user_id = auth.uid()). No payout QR, no paying person, no one else''s row.';

-- Notice bookkeeping (service role: notify-cleaner-payment) ------------------------------------------------------------------------
create or replace function public.staff_pay_notice_v1(p_request_id uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_r public.staff_pay_requests%rowtype; v_label text;
begin
  if p_action = 'release' then
    update public.staff_pay_requests set paid_notified_at = null where id = p_request_id and paid_notified_at is not null;
    return jsonb_build_object('ok', true);
  end if;
  if p_action <> 'claim' then return jsonb_build_object('ok', false, 'reason', 'bad_action'); end if;
  update public.staff_pay_requests set paid_notified_at = now()
   where id = p_request_id and status = 'paid' and paid_notified_at is null returning * into v_r;
  if not found then
    select * into v_r from public.staff_pay_requests where id = p_request_id;
    if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
    return jsonb_build_object('ok', false, 'reason', case when v_r.status <> 'paid' then 'not_paid' else 'already_sent' end);
  end if;
  select nullif(btrim(d.payout_bank_label), '') into v_label from public.staff_details d where d.user_id = v_r.payee_user_id;
  return jsonb_build_object('ok', true, 'request_id', v_r.id, 'ref', v_r.ref, 'payee_user_id', v_r.payee_user_id, 'payee_name', v_r.payee_name,
    'first_name', split_part(btrim(v_r.payee_name), ' ', 1), 'total', v_r.total_amount, 'paid_at', v_r.paid_at, 'bank_reference', v_r.proof_reference,
    'bank_label', v_label, 'paid_by_tg', v_r.paid_by_tg, 'ops_chat_id', v_r.ops_chat_id, 'ops_message_id', v_r.ops_message_id,
    'date_from', (select min((l ->> 'date')::date) from jsonb_array_elements(v_r.lines) l),
    'date_to', (select max((l ->> 'date')::date) from jsonb_array_elements(v_r.lines) l));
end $$;
revoke all on function public.staff_pay_notice_v1(uuid, text) from public, anon, authenticated;
grant execute on function public.staff_pay_notice_v1(uuid, text) to service_role;

-- On status -> paid, ask the Edge Function to tell her. A failure here must never block a settle, so everything is guarded and dynamic:
-- where pg_net or the vault secret is absent (a rehearsal copy) the trigger does nothing. The function claims the notice, so a second ask is harmless.
create or replace function public.staff_pay_notify_paid_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_secret text;
begin
  if to_regnamespace('net') is null or to_regclass('vault.decrypted_secrets') is null then return null; end if;
  begin
    execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret' limit 1$q$ into v_secret;
    if coalesce(v_secret, '') = '' then return null; end if;
    perform net.http_post(
      url := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/notify-cleaner-payment',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cascade-cron-secret', v_secret),
      body := jsonb_build_object('action', 'paid', 'request_id', new.id),
      timeout_milliseconds := 20000);
  exception when others then
    raise warning 'staff_pay_notify_paid_trg: could not queue the paid notice (%)', sqlstate;
  end;
  return null;
end $$;
revoke all on function public.staff_pay_notify_paid_trg() from public, anon, authenticated, service_role;
drop trigger if exists staff_pay_notify_paid on public.staff_pay_requests;
create trigger staff_pay_notify_paid after update of status on public.staff_pay_requests
  for each row when (new.status = 'paid' and old.status is distinct from 'paid') execute function public.staff_pay_notify_paid_trg();

-- forward check: everything this release adds is present and closed to the API roles that must not have it
do $$
begin
  if to_regclass('public.staff_push_subscriptions') is null then raise exception 'staff_push_subscriptions missing'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.staff_push_subscriptions'::regclass) then raise exception 'staff_push_subscriptions RLS not enabled'; end if;
  if has_function_privilege('anon', 'public.staff_pay_payout_qr_v1(uuid)', 'execute') then raise exception 'anon can read a payout QR'; end if;
  if has_function_privilege('authenticated', 'public.staff_pay_notice_v1(uuid,text)', 'execute') then raise exception 'authenticated can run the notice claim'; end if;
  if not exists (select 1 from pg_trigger where tgname = 'staff_pay_notify_paid' and tgrelid = 'public.staff_pay_requests'::regclass) then raise exception 'paid trigger missing'; end if;
end $$;

commit;
