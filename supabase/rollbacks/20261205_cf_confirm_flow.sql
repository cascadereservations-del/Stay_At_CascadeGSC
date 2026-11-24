-- Compensating rollback for release cf_confirm_flow_20261205 (D-418, confirm flow, server side).
-- Roll the Cascade-Staff push and the guest-messages deploy back FIRST: the new Staff reads the new columns and calls concierge_waiting_v1 and
-- the four-argument decline; the new guest-messages answers the declined key.
--   * notices_v1 goes back to the s91 body by the reverse anchored replace (md5 pinned: 7906db74... original or this release's body; 55000 on a body that is neither);
--   * concierge_waiting_v1 and the four helper functions s_cf_* are dropped;
--   * concierge_conversations_v1, staff_inquiry_payments_v1 and the three-argument staff_decline_direct_booking_v1 go back to their live bodies
--     (md5 61cfed09..., 2f7bdf2f..., 5b80a68b...), grants as before; the four-argument decline is dropped;
--   * the guest_message_log CHECK goes back to the six scheduled keys ONLY when no 'declined' row exists. With one, the wider CHECK stays
--     (harmless: nothing scheduled writes it) and a NOTICE says so. Count first:  select count(*) from public.guest_message_log where message_key = 'declined';
-- KEPT: every guest_message_log row and every booking decision the decline wrote.
begin;

-- 1. guard: this release is what is installed
do $g$
declare v text;
begin
  if to_regprocedure('public.s_cf_waiting_v1()') is null or to_regprocedure('public.concierge_waiting_v1()') is null then
    raise exception 'cf_confirm_flow rollback: the release is not installed' using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.notices_v1(uuid)');
  if v is distinct from '7906db742100f93a2b56d33bbdb43baf' and v is distinct from '06204588643539a7a6b0e01df58a1d2a' then
    raise exception 'cf_confirm_flow rollback: notices_v1 is neither the s91 body nor this release (md5 %)', v using errcode = '55000';
  end if;
end $g$;

-- 2. notices_v1 back to the s91 body (it calls s_cf_waiting_v1, dropped below)
do $n$
declare
  v_def text;
  v_new constant text := 'select count(*)::int into v_inbox from public.concierge_handoffs h where h.status = ''open'';';
  v_old constant text := 'select count(*)::int into v_inbox from public.s_cf_waiting_v1() w where w.needs_reply;';
  v_n int;
begin
  v_def := pg_get_functiondef(to_regprocedure('public.notices_v1(uuid)'));
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_n = 1 then
    execute replace(v_def, v_old, v_new);
  elsif v_n <> 0 then
    raise exception 'cf_confirm_flow rollback: the inbox_open line appears % times', v_n using errcode = '55000';
  end if;
end $n$;
revoke all on function public.notices_v1(uuid) from public, anon;
grant execute on function public.notices_v1(uuid) to authenticated, service_role;

-- 3. the new count function and the conversations list as they were
drop function public.concierge_waiting_v1();
drop function public.concierge_conversations_v1(int);
create function public.concierge_conversations_v1(p_limit int default 30)
returns table (
  psid text, psid_short text, guest_name text, updated_at timestamptz,
  last_role text, last_text text, last_guest_at timestamptz,
  open_handoffs int, human_until timestamptz, last_risk text
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
         oh.n, t.human_until, t.last_risk
    from public.concierge_threads t
    cross join lateral (select count(*)::int as n from public.concierge_handoffs h where h.psid = t.psid and h.status = 'open') oh
   where jsonb_typeof(t.history) = 'array'
   order by (oh.n > 0) desc, t.updated_at desc
   limit greatest(1, least(coalesce(p_limit, 30), 100));
end;
$$;
-- ACL exactly as before cf (20261006130000: revoke from public, anon; authenticated granted; service_role kept its default-privilege execute). cf had revoked service_role.
revoke all on function public.concierge_conversations_v1(int) from public, anon;
grant execute on function public.concierge_conversations_v1(int) to authenticated, service_role;
comment on function public.concierge_conversations_v1(int) is
  'SPEC-42 s7: Conversations panel list. Owner/admin only (42501 otherwise). One row per Cassy thread, open handoffs first then newest; last_guest_at drives the 7-day HUMAN_AGENT reply window.';

-- 4. decline: the three-argument function gets its live body back, the four-argument one goes
create or replace function public.staff_decline_direct_booking_v1(p_booking_id uuid, p_reason text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b public.booking_inquiries%rowtype;
  v_dec public.booking_decisions%rowtype;
  v_comparison uuid;
  v_review uuid;
  v_key text;
  v_reason text := left(nullif(btrim(coalesce(p_reason, '')), ''), 500);
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
            jsonb_build_object('finance_review_id', v_review, 'comparison_id', v_comparison))
    on conflict (idempotency_key) do nothing;
  end if;
  return v_base || v_res || jsonb_build_object('finance_review_id', v_review, 'comparison_id', v_comparison);
end $$;
revoke all on function public.staff_decline_direct_booking_v1(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function public.staff_decline_direct_booking_v1(uuid, text, text) to authenticated;
comment on function public.staff_decline_direct_booking_v1(uuid, text, text) is null;
drop function public.staff_decline_direct_booking_v1(uuid, text, text, text);

-- 5. the Inquiries list with its 12 columns
drop function public.staff_inquiry_payments_v1(uuid);
create function public.staff_inquiry_payments_v1(p_property_id uuid)
returns table (
  id uuid, booking_ref text, guest_name text, checkin_date date, checkout_date date, pax integer,
  expected_amount numeric, comparison_id uuid, candidate_amount numeric, reference text,
  receipt_image_path text, hold_expires_at timestamptz
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
         rc.comparison_id, rc.amount::numeric, rc.reference, b.receipt_image_path, h.expires_at
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
   where b.property_id = p_property_id and b.source = 'direct' and b.status = 'pending'
   order by b.checkin_date, b.submitted_at, b.id;
end $$;
revoke all on function public.staff_inquiry_payments_v1(uuid) from public, anon, authenticated, service_role;
grant execute on function public.staff_inquiry_payments_v1(uuid) to authenticated;
comment on function public.staff_inquiry_payments_v1(uuid) is null;

-- 6. helpers (nothing calls them any more)
drop function public.s_cf_waiting_v1();
drop function public.s_cf_contact_channel_v1(uuid);
drop function public.s_cf_receipt_sent_v1(uuid);
drop function public.s_cf_ts_v1(text);

-- 7. the CHECK, only when no declined row exists
do $c$
begin
  if exists (select 1 from public.guest_message_log where message_key = 'declined') then
    raise notice 'cf_confirm_flow rollback: guest_message_log holds declined rows, so the wider message_key CHECK stays (harmless)';
  else
    alter table public.guest_message_log drop constraint guest_message_log_message_key_check;
    alter table public.guest_message_log add constraint guest_message_log_message_key_check
      check (message_key = any (array['confirmation', 'pre_arrival', 'door_code', 'mid_stay', 'checkout_reminder', 'after_departure']));
  end if;
end $c$;

commit;
