-- Session 70 (SPEC-38, D-297 item 2, D-300): decide a direct-booking request before payment, from Telegram.
--
-- 1. telegram_pending_kind_check is re-created with the 17 production values (read from pg_constraint 2026-10-05) PLUS three:
--      refund_confirm  the live /refund (telegram-expense) inserts this kind and has been refused by the CHECK since it shipped
--      inquiry_reply   a Cassy draft waiting for a tap (SPEC-38: reply to a guest, or a decline with a message)
--      lock_code       reserved for wave 2 (TTLock); harmless until a function writes it
-- 2. booking_lifecycle_events_event_type_check gains guest_replied (the audit row for a message sent to a guest from Telegram).
-- 3. Three service_role-only definer RPCs, built like telegram_finance_decide_booking_v1:
--      telegram_inquiry_view_v1          read: the open (unpaid) requests, or one request whatever its status
--      telegram_inquiry_decide_v1        hold the dates 24 h, or decline with a reason code; the Finance tapper by Telegram id, idempotent
--      telegram_inquiry_message_logged_v1 audit row for a guest message (hold line, decline line, Cassy reply)
-- Who may decide (D-302.2): anyone in the Finance group - the Edge function only calls decide from the Finance chat. No staff-profile
-- mapping is needed; the tapper's Telegram id is recorded on every audit row, and actor_user_id is filled when that id is mapped.
-- No table, column or grant change on existing objects. Nothing is dropped.
begin;

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice',
  'inventory_count', 'awaiting_reply', 'llm_house', 'guest_pick', 'guest_save',
  'refund_confirm', 'inquiry_reply', 'lock_code'
]));

alter table public.booking_lifecycle_events drop constraint if exists booking_lifecycle_events_event_type_check;
alter table public.booking_lifecycle_events add constraint booking_lifecycle_events_event_type_check check (event_type = any (array[
  'hold_created', 'hold_expired', 'amended', 'cancelled', 'no_show', 'refund_authorized', 'calendar_reconciled',
  'rate_policy_published', 'rate_promotion_saved', 'rate_promotion_ended',
  'guest_replied'
]));

-- 4.1 The open requests (source 'direct', pending, no receipt yet), oldest first, at most 5; or one request by id whatever its status,
-- so a stale card can say why it closed. Read only. guest_email / guest_phone are returned: the caller (telegram-expense, service
-- role) decides what each chat sees, OPS never gets them.
create or replace function public.telegram_inquiry_view_v1(p_booking_id uuid default null)
returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id,
           'ref', upper(left(b.id::text, 8)),
           'guest_name', b.guest_name,
           'guest_email', b.guest_email,
           'guest_phone', b.guest_phone,
           'checkin_date', b.checkin_date,
           'checkout_date', b.checkout_date,
           'nights', b.nights,
           'pax', b.pax,
           'total_amount', b.total_amount,
           'deposit_amount', b.deposit_amount,
           'notes', b.notes,
           'submitted_at', b.submitted_at,
           'status', b.status,
           'has_receipt', b.receipt_image_path is not null,
           'hold_expires_at', h.expires_at,
           'held_by', hb.note,
           'held_at', hb.created_at,
           'conflict', (
             exists (select 1 from public.calendar_events c
                      where c.property_id = b.property_id and c.status in ('confirmed', 'blocked')
                        and c.checkin_date < b.checkout_date and c.checkout_date > b.checkin_date
                        and c.uid not in ('direct:' || b.id::text, 'cascade-direct-' || b.id::text))
             or exists (select 1 from public.booking_holds o
                         where o.property_id = b.property_id and o.status = 'active' and o.expires_at > now()
                           and o.booking_id <> b.id
                           and o.checkin_date < b.checkout_date and o.checkout_date > b.checkin_date))
         ) order by b.submitted_at, b.id), '[]'::jsonb)
    from (select x.* from public.booking_inquiries x
           where x.source = 'direct'
             and ((p_booking_id is null and x.status = 'pending' and x.receipt_image_path is null) or x.id = p_booking_id)
           order by x.submitted_at, x.id
           limit 5) b
    left join lateral (select max(k.expires_at) as expires_at from public.booking_holds k
                        where k.booking_id = b.id and k.status = 'active') h on true
    left join lateral (select e.created_at, coalesce(p.note, e.after_state ->> 'actor_name') as note
                         from public.booking_lifecycle_events e
                         left join public.staff_access_profiles p on p.user_id = e.actor_user_id
                        where e.idempotency_key = 'tg-inquiry-hold:' || b.id::text
                        limit 1) hb on true;
$$;

-- 4.2 Hold the dates, or decline. One actor (the Finance tapper, by Telegram id), the property advisory lock the decide_* functions and the
-- guard trigger use, and an idempotency key per effect: a re-tap or a Telegram re-delivery changes nothing.
create or replace function public.telegram_inquiry_decide_v1(
  p_telegram_user_id bigint, p_booking_id uuid, p_action text, p_reason_code text default null, p_hold_hours integer default 24,
  p_actor_name text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  p public.staff_access_profiles%rowtype;
  b public.booking_inquiries%rowtype;
  v_hold public.booking_holds%rowtype;
  v_hold_id uuid;
  v_until timestamptz;
  v_hours integer;
  v_extended boolean := false;
  v_before timestamptz;
  v_held_at timestamptz;
  v_res jsonb;
begin
  if p_action is null or p_action not in ('hold', 'decline') then
    return jsonb_build_object('ok', false, 'reason', 'bad_action');
  end if;
  if p_action = 'decline' and (p_reason_code is null or p_reason_code not in ('taken', 'guests', 'house', 'owner', 'dup', 'other')) then
    return jsonb_build_object('ok', false, 'reason', 'bad_reason');
  end if;
  if p_telegram_user_id is null then return jsonb_build_object('ok', false, 'reason', 'no_tapper'); end if;
  select * into p from public.staff_access_profiles where telegram_user_id = p_telegram_user_id; -- optional (D-302.2)

  select * into b from public.booking_inquiries where id = p_booking_id and source = 'direct' for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-property:' || b.property_id::text, 0));

  if p_action = 'hold' then
    -- A request already held in Telegram answers the second tap with the same facts and writes nothing.
    select e.created_at into v_held_at from public.booking_lifecycle_events e
     where e.idempotency_key = 'tg-inquiry-hold:' || b.id::text;
    if found and b.status = 'pending' then
      return jsonb_build_object('ok', true, 'outcome', 'held', 'already_processed', true, 'held_at', v_held_at,
        'expires_at', (select max(k.expires_at) from public.booking_holds k where k.booking_id = b.id and k.status = 'active'));
    end if;
    if b.status <> 'pending' then return jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', b.status); end if;
    if b.receipt_image_path is not null then return jsonb_build_object('ok', false, 'reason', 'receipt_arrived'); end if;
    -- create_booking_hold's two overlap tests: the calendar (own uids excluded) and other active holds.
    if exists (select 1 from public.calendar_events c
                where c.property_id = b.property_id and c.status in ('confirmed', 'blocked')
                  and c.checkin_date < b.checkout_date and c.checkout_date > b.checkin_date
                  and c.uid not in ('direct:' || b.id::text, 'cascade-direct-' || b.id::text))
       or exists (select 1 from public.booking_holds o
                   where o.property_id = b.property_id and o.status = 'active' and o.expires_at > now()
                     and o.booking_id <> b.id
                     and o.checkin_date < b.checkout_date and o.checkout_date > b.checkin_date) then
      return jsonb_build_object('ok', false, 'reason', 'conflict');
    end if;
    v_hours := greatest(1, least(coalesce(p_hold_hours, 24), 48));
    v_until := now() + make_interval(hours => v_hours);
    select * into v_hold from public.booking_holds
     where booking_id = b.id and status = 'active' order by expires_at desc limit 1;
    if found then
      v_before := v_hold.expires_at;
      v_until := greatest(v_hold.expires_at, v_until);
      update public.booking_holds set expires_at = v_until, updated_at = now() where id = v_hold.id;
      v_hold_id := v_hold.id;
      v_extended := true;
    else
      insert into public.booking_holds(property_id, booking_id, rate_policy_version_id, checkin_date, checkout_date,
                                       expires_at, status, idempotency_key)
      values (b.property_id, b.id,
              (select r.id from public.booking_rate_policy_versions r
                where r.property_id = b.property_id and r.effective_from <= b.checkin_date
                  and (r.effective_to is null or r.effective_to >= b.checkin_date)
                order by r.effective_from desc limit 1),
              b.checkin_date, b.checkout_date, v_until, 'active', 'tg-inquiry-hold:' || b.id::text)
      returning id into v_hold_id;
    end if;
    insert into public.booking_lifecycle_events(property_id, booking_id, event_type, actor_user_id, reason, idempotency_key, before_state, after_state)
    values (b.property_id, b.id, 'hold_created', p.user_id, 'Held in Telegram for ' || v_hours || ' h',
            'tg-inquiry-hold:' || b.id::text,
            jsonb_build_object('hold_expires_at_before', v_before),
            jsonb_build_object('hold_id', v_hold_id, 'expires_at', v_until, 'telegram_user_id', p_telegram_user_id,
                               'actor_name', left(nullif(btrim(p_actor_name), ''), 80)));
    return jsonb_build_object('ok', true, 'outcome', 'held', 'already_processed', false, 'extended', v_extended,
      'expires_at', v_until, 'actor_user_id', p.user_id, 'actor_role', p.role);
  end if;

  -- decline
  if b.status = 'cancelled' and exists (select 1 from public.booking_decisions d where d.idempotency_key = 'tg-inquiry-decline:' || b.id::text) then
    return jsonb_build_object('ok', true, 'outcome', 'declined', 'already_processed', true);
  end if;
  if b.status <> 'pending' then return jsonb_build_object('ok', false, 'reason', 'not_pending', 'status', b.status); end if;
  if b.receipt_image_path is not null then return jsonb_build_object('ok', false, 'reason', 'receipt_arrived'); end if;
  -- The decline engine: request cancelled, calendar cancelled, income void, one booking_decisions row. The guard trigger
  -- releases the booking's active holds when the status becomes cancelled.
  v_res := public.decide_direct_booking_without_finance_review(b.id, 'decline', 'tg-inquiry-decline:' || b.id::text);
  if coalesce((v_res ->> 'ok')::boolean, false) is not true then
    return v_res;
  end if;
  insert into public.booking_lifecycle_events(property_id, booking_id, event_type, actor_user_id, reason, idempotency_key, after_state)
  values (b.property_id, b.id, 'cancelled', p.user_id, 'Declined in Telegram: ' || p_reason_code,
          'tg-inquiry-decline-audit:' || b.id::text,
          jsonb_build_object('reason_code', p_reason_code, 'telegram_user_id', p_telegram_user_id,
                             'actor_name', left(nullif(btrim(p_actor_name), ''), 80)))
  on conflict (idempotency_key) do nothing;
  return v_res || jsonb_build_object('actor_user_id', p.user_id, 'actor_role', p.role, 'reason_code', p_reason_code);
end $$;

-- 4.3 Audit row for a message sent (or not delivered) to a guest from Telegram. Unsigned messages: the row records who tapped.
create or replace function public.telegram_inquiry_message_logged_v1(
  p_booking_id uuid, p_telegram_user_id bigint, p_actor_name text, p_purpose text, p_channel text,
  p_delivered boolean, p_text text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  b public.booking_inquiries%rowtype;
  v_actor uuid;
  v_n integer;
begin
  if p_purpose is null or p_purpose not in ('hold', 'decline', 'reply')
     or p_channel is null or p_channel not in ('messenger', 'email', 'card_only')
     or p_delivered is null
     or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;
  select * into b from public.booking_inquiries where id = p_booking_id and source = 'direct';
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  select p.user_id into v_actor from public.staff_access_profiles p where p.telegram_user_id = p_telegram_user_id;
  insert into public.booking_lifecycle_events(property_id, booking_id, event_type, actor_user_id, reason, idempotency_key, after_state)
  values (b.property_id, b.id, 'guest_replied', v_actor,
          left(p_purpose || ' ' || case when p_delivered then 'sent' else 'NOT delivered' end || ' on ' || p_channel
               || ' by ' || coalesce(nullif(btrim(p_actor_name), ''), 'staff'), 2000),
          p_idempotency_key,
          jsonb_build_object('purpose', p_purpose, 'channel', p_channel, 'delivered', p_delivered,
                             'telegram_user_id', p_telegram_user_id, 'text', left(coalesce(p_text, ''), 1500)))
  on conflict (idempotency_key) do nothing;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'inserted', v_n = 1);
end $$;

revoke all on function public.telegram_inquiry_view_v1(uuid) from public, anon, authenticated;
grant execute on function public.telegram_inquiry_view_v1(uuid) to service_role;
revoke all on function public.telegram_inquiry_decide_v1(bigint, uuid, text, text, integer, text) from public, anon, authenticated;
grant execute on function public.telegram_inquiry_decide_v1(bigint, uuid, text, text, integer, text) to service_role;
revoke all on function public.telegram_inquiry_message_logged_v1(uuid, bigint, text, text, text, boolean, text, text) from public, anon, authenticated;
grant execute on function public.telegram_inquiry_message_logged_v1(uuid, bigint, text, text, text, boolean, text, text) to service_role;

commit;
