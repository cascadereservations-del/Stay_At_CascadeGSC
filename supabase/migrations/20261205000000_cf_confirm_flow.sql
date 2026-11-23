-- Release cf_confirm_flow_20261205 (D-418, Lloyd 2026-11-24). Confirm flow in Cascade Staff, server side. Contract: docs/plans/PLAN-confirm-flow.md "Revision 1" (R1.7).
--   1. guest_message_log.message_key CHECK gains 'declined' (the decline notice is a logged guest message like the six scheduled ones).
--   2. staff_inquiry_payments_v1: drop + create. The 12 existing columns stay in place, then receipt_sent, receipt_at, contact_channel;
--      order = receipt sent first (newest receipt first), then by the soonest hold end.
--   3. staff_decline_direct_booking_v1 gains p_reason_code. The 3-argument function stays as a wrapper (Staff 3.4.53 keeps working).
--      A decline queues guest-messages {booking_id, key:'declined', reason_code, receipt_sent, tapped:true} exactly like a confirm
--      (same pg_net wrapper, same 'raise warning' on failure); the code 'duplicate' queues nothing.
--      The Telegram decline (telegram_inquiry_decide_v1) is NOT hooked: telegram-expense/inquiry-flow.ts already sends the guest the
--      decline line itself (sendAndLog, purpose decline), so a SQL hook would send two messages. See the lane report.
--   4. concierge_conversations_v1: drop + create with needs_reply and waiting_since; new concierge_waiting_v1(); notices_v1 inbox_open
--      counts threads that need a reply (one anchored replace of the live body). The rule is written once, in s_cf_waiting_v1().
-- Internal helpers (no grants, the definer functions call them as owner): s_cf_ts_v1, s_cf_receipt_sent_v1, s_cf_contact_channel_v1,
-- s_cf_waiting_v1. Expand only: no table, column or row changes; one CHECK is widened.

begin;

-- 0. Guard: the live bodies about to be replaced are the ones this release was written against (ML-45).
do $g$
declare
  r record;
begin
  for r in
    select * from (values
      ('public.staff_inquiry_payments_v1(uuid)',                     '2f7bdf2fcca038b99be2e6754cbd8a55'),
      ('public.staff_decline_direct_booking_v1(uuid,text,text)',     '5b80a68bca479f9d61733652d3503be8'),
      ('public.concierge_conversations_v1(integer)',                 '61cfed096abddb0316509f03d10f8d30'),
      ('public.notices_v1(uuid)',                                    '7906db742100f93a2b56d33bbdb43baf')
    ) v(f, m)
  loop
    if to_regprocedure(r.f) is null then
      raise exception 'cf_confirm_flow: % is missing', r.f using errcode = '55000';
    end if;
    if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure(r.f)) is distinct from r.m then
      raise exception 'cf_confirm_flow: % is not the body this release was written against (md5 %)', r.f,
        (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p where p.oid = to_regprocedure(r.f)) using errcode = '55000';
    end if;
  end loop;
end $g$;

-- 1. The decline notice is a logged message: one row per (booking, key) keeps a retry from sending it twice.
alter table public.guest_message_log drop constraint guest_message_log_message_key_check;
alter table public.guest_message_log add constraint guest_message_log_message_key_check
  check (message_key = any (array['confirmation', 'pre_arrival', 'door_code', 'mid_stay', 'checkout_reminder', 'after_departure', 'declined']));

-- 2. Helpers. Internal: no client grants (restated at the end of the file).
-- 2.1 A text timestamp from a chat history entry; anything that is not an ISO timestamp is null, never an error.
create or replace function public.s_cf_ts_v1(p text)
returns timestamptz language plpgsql stable set search_path = '' as $$
begin
  if p is null or p !~ '^\d{4}-\d{2}-\d{2}T' then return null; end if;
  return p::timestamptz;
exception when others then
  return null;
end $$;

-- 2.2 Did the guest send a receipt? A stored receipt image, or a comparison over guest-sent evidence (paid-outside attempts do not count).
create or replace function public.s_cf_receipt_sent_v1(p_booking_id uuid)
returns boolean language sql stable set search_path = '' as $$
  select coalesce((select nullif(btrim(coalesce(b.receipt_image_path, '')), '') is not null
                     from public.booking_inquiries b where b.id = p_booking_id), false)
      or exists (select 1
                   from public.payment_evidence_candidates e
                   join public.payment_evidence_comparisons cmp on cmp.booking_id = e.booking_id and e.id = any (cmp.evidence_candidate_ids)
                  where e.booking_id = p_booking_id and e.source_type <> 'manual_evidence');
$$;

-- 2.3 How would guest-messages reach this guest for a tapped message? Messenger only while the guest's last chat message leaves at least
--     one hour of the 167 h window (HUMAN_AGENT, templates.ts channelFor); else e-mail when one is on file; else none. Never the contact itself.
create or replace function public.s_cf_contact_channel_v1(p_booking_id uuid)
returns text language sql stable set search_path = '' as $$
  select case
    when exists (
           select 1
             from (select t.history from public.concierge_threads t
                    where t.booking_flow ->> 'booking_id' = p_booking_id::text
                    order by t.updated_at desc limit 1) th
            where jsonb_typeof(th.history) = 'array'
              and (select max(public.s_cf_ts_v1(e ->> 'at')) from jsonb_array_elements(th.history) e where e ->> 'role' = 'guest')
                  >= now() - interval '166 hours')
      then 'messenger'
    when exists (select 1 from public.booking_inquiries b
                  where b.id = p_booking_id and nullif(btrim(coalesce(b.guest_email, '')), '') is not null)
      then 'email'
    else 'none'
  end;
$$;

-- 2.4 The "guest waiting for a reply" rule, written once: an open hand-off, or the host holds the chat (human_until in the future) and
--     the last turn is the guest's. waiting_since = the oldest open hand-off, else the guest's last turn (the thread's update time when
--     that turn has no usable timestamp); null when no reply is needed. One row per thread with an array history.
create or replace function public.s_cf_waiting_v1()
returns table (psid text, needs_reply boolean, waiting_since timestamptz)
language sql stable set search_path = '' as $$
  select t.psid, x.needs_reply,
         case when not x.needs_reply then null
              when oh.n > 0 then oh.oldest
              else coalesce((select max(public.s_cf_ts_v1(e ->> 'at')) from jsonb_array_elements(t.history) e where e ->> 'role' = 'guest'), t.updated_at)
         end
    from public.concierge_threads t
    cross join lateral (select count(*)::int as n, min(h.created_at) as oldest
                          from public.concierge_handoffs h where h.psid = t.psid and h.status = 'open') oh
    cross join lateral (select coalesce(oh.n > 0 or (t.human_until > now() and (t.history -> -1) ->> 'role' = 'guest'), false) as needs_reply) x
   where jsonb_typeof(t.history) = 'array';
$$;

-- 3. The Inquiries list. RETURNS TABLE changes, so drop and create.
drop function public.staff_inquiry_payments_v1(uuid);
create function public.staff_inquiry_payments_v1(p_property_id uuid)
returns table (
  id uuid, booking_ref text, guest_name text, checkin_date date, checkout_date date, pax integer,
  expected_amount numeric, comparison_id uuid, candidate_amount numeric, reference text,
  receipt_image_path text, hold_expires_at timestamptz,
  receipt_sent boolean, receipt_at timestamptz, contact_channel text
)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if not (coalesce(public.current_staff_authorized('read_finance', p_property_id), false)
          or coalesce(public.current_staff_authorized('approve_payment', p_property_id), false)) then
    raise exception using errcode = '42501', message = 'read_finance or approve_payment is required';
  end if;
  return query
  select b.id, upper(left(b.id::text, 8)), b.guest_name, b.checkin_date, b.checkout_date, b.pax,
         (case when b.deposit_amount > 0 then b.deposit_amount else b.total_amount end)::numeric,
         rc.comparison_id, rc.amount::numeric, rc.reference, b.receipt_image_path, h.expires_at,
         public.s_cf_receipt_sent_v1(b.id), ra.at, public.s_cf_contact_channel_v1(b.id)
    from public.booking_inquiries b
    left join lateral (
      select cmp.id as comparison_id, e.normalized_amount as amount, e.normalized_reference as reference
        from public.payment_evidence_candidates e
        join public.payment_evidence_comparisons cmp on cmp.booking_id = b.id and e.id = any (cmp.evidence_candidate_ids)
       where e.booking_id = b.id and e.source_type <> 'manual_evidence'
       order by cmp.created_at desc, e.created_at desc, cmp.id
       limit 1) rc on true
    left join lateral (
      select max(k.expires_at) as expires_at from public.booking_holds k where k.booking_id = b.id and k.status = 'active') h on true
    left join lateral (
      select max(e.created_at) as at from public.payment_evidence_candidates e
       where e.booking_id = b.id and e.source_type <> 'manual_evidence') ra on true
   where b.property_id = p_property_id and b.source = 'direct' and b.status = 'pending'
   order by public.s_cf_receipt_sent_v1(b.id) desc, ra.at desc nulls last, h.expires_at asc nulls last, b.checkin_date, b.submitted_at, b.id;
end $$;
revoke all on function public.staff_inquiry_payments_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.staff_inquiry_payments_v1(uuid) to authenticated;
comment on function public.staff_inquiry_payments_v1(uuid) is
  'One row per pending direct booking. receipt_sent: a stored receipt image or a guest-sent comparison; receipt_at: newest guest-sent evidence time (null when the image was never read); contact_channel: messenger, email or none (a word, never the contact). Order: receipt sent first (newest receipt first), then the soonest hold end.';

-- 4. Decline with a reason code. The body is the live body of the three-argument function plus the code, the receipt flag and the guest-messages post.
create function public.staff_decline_direct_booking_v1(p_booking_id uuid, p_reason text, p_idempotency_key text, p_reason_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b public.booking_inquiries%rowtype;
  v_dec public.booking_decisions%rowtype;
  v_comparison uuid;
  v_review uuid;
  v_key text;
  v_reason text := left(nullif(btrim(coalesce(p_reason, '')), ''), 500);
  v_code text := case when p_reason_code in ('dates', 'payment', 'guest_cancel', 'duplicate', 'other') then p_reason_code else 'other' end;
  v_receipt boolean;
  v_secret text;
  v_base jsonb;
  v_res jsonb;
begin
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 120 then
    raise exception using errcode = '22023', message = 'idempotency key must be 16 to 120 characters';
  end if;
  v_key := 'onetap-decline:' || p_idempotency_key;
  select * into b from public.booking_inquiries where id = p_booking_id and source = 'direct';
  if not found then
    return jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'not_found', 'booking_id', p_booking_id);
  end if;
  if auth.uid() is null or not coalesce(public.current_staff_authorized('approve_payment', b.property_id), false) then
    return jsonb_build_object('ok', false, 'outcome', 'denied', 'booking_id', p_booking_id);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-onetap-decline:' || p_idempotency_key, 0));
  select * into b from public.booking_inquiries where id = p_booking_id for update;
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-property:' || b.property_id::text, 0));
  v_base := jsonb_build_object('booking_id', b.id, 'booking_ref', upper(left(b.id::text, 8)), 'guest_name', b.guest_name,
                               'checkin', b.checkin_date, 'checkout', b.checkout_date);

  select * into v_dec from public.booking_decisions where idempotency_key = v_key;
  if found then
    return v_base || jsonb_build_object('ok', v_dec.outcome = 'declined', 'outcome', v_dec.outcome, 'already_processed', true);
  end if;
  if v_reason is null or char_length(v_reason) < 3 then
    return v_base || jsonb_build_object('ok', false, 'outcome', 'note_required');
  end if;
  if b.status <> 'pending' then
    return v_base || jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'not_pending', 'status', b.status);
  end if;
  v_receipt := public.s_cf_receipt_sent_v1(b.id);

  -- The newest comparison that no approval has claimed; its rejected review is reused when one exists.
  select c.id into v_comparison from public.payment_evidence_comparisons c
   where c.booking_id = b.id
     and not exists (select 1 from public.payment_finance_reviews r where r.comparison_id = c.id and r.outcome = 'approved')
   order by c.created_at desc, c.id limit 1;
  if v_comparison is not null then
    select r.id into v_review from public.payment_finance_reviews r where r.comparison_id = v_comparison and r.outcome = 'rejected';
    if v_review is null then
      insert into public.payment_finance_reviews (property_id, booking_id, comparison_id, reviewer_user_id, outcome, reason)
      values (b.property_id, b.id, v_comparison, auth.uid(), 'rejected', 'Declined: ' || v_reason)
      returning id into v_review;
    end if;
    v_res := public.decide_direct_booking(b.id, 'decline', v_key, v_review);
  else
    v_res := public.decide_direct_booking_without_finance_review(b.id, 'decline', v_key);
  end if;

  if v_res ->> 'outcome' = 'declined' then
    insert into public.booking_lifecycle_events(property_id, booking_id, event_type, actor_user_id, reason, idempotency_key, after_state)
    values (b.property_id, b.id, 'cancelled', auth.uid(), left('Declined in the admin: ' || v_reason, 2000),
            'onetap-decline-audit:' || p_idempotency_key,
            jsonb_build_object('finance_review_id', v_review, 'comparison_id', v_comparison, 'reason_code', v_code))
    on conflict (idempotency_key) do nothing;

    -- The guest is told by guest-messages (key declined), exactly as a confirm is. A duplicate request sends nothing: the guest's other
    -- request is still live. The host decided, so tapped:true sends even under a D-317 hold. Queued by pg_net only if this commits;
    -- a missing pg_net/Vault (rehearsal, CI) or a failed enqueue never blocks the decline.
    if v_code <> 'duplicate' and coalesce((v_res ->> 'already_processed')::boolean, false) is not true then
      begin
        if to_regnamespace('net') is not null and to_regclass('vault.decrypted_secrets') is not null then
          select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret';
          if coalesce(length(v_secret), 0) > 0 then
            perform net.http_post(
              url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/guest-messages',
              headers := jsonb_build_object('Content-Type', 'application/json', 'x-cascade-cron-secret', v_secret),
              body    := jsonb_build_object('booking_id', b.id, 'key', 'declined', 'reason_code', v_code, 'receipt_sent', v_receipt, 'tapped', true),
              timeout_milliseconds := 45000);
          end if;
        end if;
      exception when others then
        raise warning 'staff_decline_direct_booking_v1: guest-messages not queued: %', sqlerrm;
      end;
    end if;
  end if;
  return v_base || v_res || jsonb_build_object('finance_review_id', v_review, 'comparison_id', v_comparison);
end $$;
revoke all on function public.staff_decline_direct_booking_v1(uuid, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.staff_decline_direct_booking_v1(uuid, text, text, text) to authenticated;
comment on function public.staff_decline_direct_booking_v1(uuid, text, text, text) is
  'Decline a pending direct request (cancel, release the dates, void the income row) and tell the guest through guest-messages (key declined). p_reason_code: dates, payment, guest_cancel, duplicate (nothing is sent) or other; null or unknown reads as other. The staff note is never sent to the guest.';

-- The old three-argument call (Staff 3.4.53) is the same decline with no code. Invoker: the four-argument function does the gating.
create or replace function public.staff_decline_direct_booking_v1(p_booking_id uuid, p_reason text, p_idempotency_key text)
returns jsonb language sql security invoker set search_path = '' as $$
  select public.staff_decline_direct_booking_v1(p_booking_id, p_reason, p_idempotency_key, null::text);
$$;
revoke all on function public.staff_decline_direct_booking_v1(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.staff_decline_direct_booking_v1(uuid, text, text) to authenticated;
comment on function public.staff_decline_direct_booking_v1(uuid, text, text) is
  'Wrapper kept for Staff 3.4.53: the same decline with reason code other.';

-- 5. Conversations: needs_reply and waiting_since (RETURNS TABLE changes, so drop and create). The ten existing columns and the order stay.
drop function public.concierge_conversations_v1(int);
create function public.concierge_conversations_v1(p_limit int default 30)
returns table (
  psid text, psid_short text, guest_name text, updated_at timestamptz,
  last_role text, last_text text, last_guest_at timestamptz,
  open_handoffs int, human_until timestamptz, last_risk text,
  needs_reply boolean, waiting_since timestamptz
)
language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.current_staff_active(array['owner', 'admin']) then
    raise exception 'only an owner or admin can read conversations' using errcode = '42501';
  end if;
  return query
  select t.psid, left(md5(t.psid), 8), t.guest_name, t.updated_at,
         (t.history -> -1) ->> 'role',
         left((t.history -> -1) ->> 'text', 160),
         (select max(case when e ->> 'at' ~ '^\d{4}-\d{2}-\d{2}T' then (e ->> 'at')::timestamptz end)
            from jsonb_array_elements(t.history) e where e ->> 'role' = 'guest'),
         oh.n, t.human_until, t.last_risk,
         w.needs_reply, w.waiting_since
    from public.concierge_threads t
    cross join lateral (select count(*)::int as n from public.concierge_handoffs h where h.psid = t.psid and h.status = 'open') oh
    join public.s_cf_waiting_v1() w on w.psid = t.psid
   where jsonb_typeof(t.history) = 'array'
   order by (oh.n > 0) desc, t.updated_at desc
   limit greatest(1, least(coalesce(p_limit, 30), 100));
end;
$$;
revoke all on function public.concierge_conversations_v1(int) from public, anon, authenticated, service_role;
grant execute on function public.concierge_conversations_v1(int) to authenticated;
comment on function public.concierge_conversations_v1(int) is
  'SPEC-42 s7: Conversations panel list. Owner/admin only (42501 otherwise). One row per Cassy thread, open handoffs first then newest; last_guest_at drives the 7-day HUMAN_AGENT reply window; needs_reply and waiting_since follow s_cf_waiting_v1 (an open hand-off, or the host holds the chat and the guest wrote last).';

-- 6. The count for the Manage card: threads that need a reply, and the oldest one.
create function public.concierge_waiting_v1()
returns table (waiting integer, oldest_at timestamptz)
language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.current_staff_active(array['owner', 'admin']) then
    raise exception 'only an owner or admin can read conversations' using errcode = '42501';
  end if;
  return query
  select (count(*) filter (where w.needs_reply))::int, min(w.waiting_since) filter (where w.needs_reply)
    from public.s_cf_waiting_v1() w;
end;
$$;
revoke all on function public.concierge_waiting_v1() from public, anon, authenticated, service_role;
grant execute on function public.concierge_waiting_v1() to authenticated;
comment on function public.concierge_waiting_v1() is
  'Guests waiting for a reply: how many threads need one (s_cf_waiting_v1) and the oldest wait. Owner/admin only (42501 otherwise).';

-- 7. notices_v1: Home's guest-message count follows the same rule (Lloyd D-418: one number on Home and in Manage). One anchored replace of
--    the live body (guarded by its md5 above); every other line is untouched.
do $n$
declare
  v_def text;
  v_old constant text := 'select count(*)::int into v_inbox from public.concierge_handoffs h where h.status = ''open'';';
  v_new constant text := 'select count(*)::int into v_inbox from public.s_cf_waiting_v1() w where w.needs_reply;';
begin
  v_def := pg_get_functiondef(to_regprocedure('public.notices_v1(uuid)'));
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) is distinct from 1 then
    raise exception 'cf_confirm_flow: the inbox_open line of notices_v1 was not found exactly once' using errcode = '55000';
  end if;
  execute replace(v_def, v_old, v_new);
end $n$;
revoke all on function public.notices_v1(uuid) from public, anon;
grant execute on function public.notices_v1(uuid) to authenticated, service_role;

-- 8. Internal helpers: no client roles (ML-21). The definer functions above call them as their owner.
revoke all on function public.s_cf_ts_v1(text) from public, anon, authenticated, service_role;
revoke all on function public.s_cf_receipt_sent_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.s_cf_contact_channel_v1(uuid) from public, anon, authenticated, service_role;
revoke all on function public.s_cf_waiting_v1() from public, anon, authenticated, service_role;

commit;
