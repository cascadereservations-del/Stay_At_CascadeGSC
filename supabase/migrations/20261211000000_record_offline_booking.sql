-- Release record_offline_booking_20261211 (lane A, phase 1 of "record booking"). Contract: docs/record-booking-20261128/contract.md B1, B2, B3.
-- A booking agreed outside the site (Messenger chat, walk-in, phone call) is recorded by an owner or admin in one call, and it
-- is confirmed in the same transaction by the existing one-tap core, so the guest, the calendar, the ledger, the DIRECT: reservation
-- and the outbox are written exactly as for a site booking.
--   0. Guard      the live body of decide_direct_booking_without_finance_review(uuid,text,text) must be the body this release was cut from
--                 (md5 of prosrc, CR stripped), else 55000 and nothing changes.
--   1. Column     booking_inquiries.channel text not null default 'site' (check: site, messenger, facebook, walk_in, phone, other). No backfill.
--   2. Engine     ONE predicate added to the conflict query of the engine (pg_get_functiondef + one anchored replace, refuses unless the
--                 anchor is found exactly once, then re-hashes the new body). An Airbnb block counts as no conflict only when it is
--                 labelled 'direct', carries THIS booking's own DIR <REF8> note, and the transaction-local setting
--                 cascade.offline_booking_id names this booking. Site, Telegram and Staff confirms never set it: unchanged.
--   3. Function   record_offline_booking_v1 (authenticated; owner or admin with approve_payment on the property). One transaction:
--                 property lock, replay by key, validation, thread routing, conflict classification, then one begin..exception
--                 sub-block of writes that any refusal of the core undoes in full.
-- Grants restated (ML-21). The migration carries no begin/commit (the runner wraps it).
-- Rollback: supabase/rollbacks/20261211_record_offline_booking.sql (puts the engine body back, drops the function and, when every booking is 'site', the column;
-- keeps the column, with a NOTICE, while a booking carries a channel other than 'site'). Bookings the function recorded stay, like any confirmed booking.

-- 0. Guard: the engine is the body this release was written against (20260901010000_canonical_booking_decision.sql, renamed at 20260905010000:428).
--    No later migration redefines it (grep of supabase/migrations, 2026-11-28).
do $g$
declare
  v_oid oid := to_regprocedure('public.decide_direct_booking_without_finance_review(uuid,text,text)');
  v_md5 text;
begin
  if v_oid is null then
    raise exception 'record_offline_booking: decide_direct_booking_without_finance_review(uuid,text,text) is missing' using errcode = '55000';
  end if;
  select md5(replace(p.prosrc, chr(13), '')) into v_md5 from pg_proc p where p.oid = v_oid;
  if v_md5 is distinct from '8f9384913791779afd0cd38ed5152220' then
    raise exception 'record_offline_booking: the engine is not the body this release was written against (md5 %)', v_md5 using errcode = '55000';
  end if;
  if to_regprocedure('public._confirm_direct_booking_core(uuid,uuid,text,text,numeric,text,uuid,text)') is null then
    raise exception 'record_offline_booking: _confirm_direct_booking_core is missing' using errcode = '55000';
  end if;
end $g$;

-- 1. The channel a booking came from. Constant default: metadata only, no table rewrite.
alter table public.booking_inquiries
  add column if not exists channel text not null default 'site';
alter table public.booking_inquiries
  add constraint booking_inquiries_channel_check
  check (channel in ('site', 'messenger', 'facebook', 'walk_in', 'phone', 'other'));
comment on column public.booking_inquiries.channel is
  'Where the booking was agreed. site = the booking page (default, every row before 2026-12-11); facebook, walk_in, phone, other = recorded by record_offline_booking_v1; messenger = reserved for the Messenger concierge.';

-- 2. The engine: one predicate, one anchored replace.
do $p$
declare
  v_def text;
  v_old text;
  v_to  text;
  v_md5 text;
begin
  v_def := pg_get_functiondef(to_regprocedure('public.decide_direct_booking_without_finance_review(uuid,text,text)'));
  v_old := $a$and ce.uid not in ('direct:' || v_booking.id::text, 'cascade-direct-' || v_booking.id::text)$a$;
  v_to  := v_old || $a$
      and not (ce.source = 'airbnb' and ce.status = 'blocked' and ce.block_reason = 'direct'
               and coalesce(current_setting('cascade.offline_booking_id', true), '') = v_booking.id::text
               and position(upper(left(v_booking.id::text, 8)) in upper(coalesce(ce.block_note, ''))) > 0)$a$;
  if v_def is null or (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'record_offline_booking: engine conflict-query anchor not found exactly once; re-cut from the live body' using errcode = '55000';
  end if;
  execute replace(v_def, v_old, v_to);
  select md5(replace(p.prosrc, chr(13), '')) into v_md5
    from pg_proc p where p.oid = to_regprocedure('public.decide_direct_booking_without_finance_review(uuid,text,text)');
  if v_md5 is distinct from '7b6bc2ccdf2fefddc0e21c36d7a7590c' then
    raise exception 'record_offline_booking: the patched engine body is not the expected one (md5 %)', v_md5 using errcode = '55000';
  end if;
end $p$;
-- The patch keeps the grants and the owner the function has live (create or replace changes neither); restated for ML-21.
revoke all on function public.decide_direct_booking_without_finance_review(uuid, text, text) from public, anon, authenticated, service_role;

-- 3. record_offline_booking_v1
create or replace function public.record_offline_booking_v1(
  p_property_id uuid, p_checkin date, p_checkout date,
  p_channel text,
  p_guest_name text, p_guest_phone text, p_guest_email text, p_pax integer,
  p_total numeric, p_paid numeric,
  p_method text,
  p_reference text, p_note text,
  p_psid text,
  p_send_confirmation boolean,
  p_override_block_uids text[],
  p_idempotency_key text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_id uuid;
  v_ref text;
  v_name text := nullif(btrim(coalesce(p_guest_name, '')), '');
  v_phone text := nullif(btrim(coalesce(p_guest_phone, '')), '');
  v_email text := nullif(btrim(coalesce(p_guest_email, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_psid text := nullif(btrim(coalesce(p_psid, '')), '');
  v_method text := nullif(lower(btrim(coalesce(p_method, ''))), '');
  v_total numeric(12,2);
  v_paid numeric(12,2);
  v_deposit numeric(12,2);
  v_digits text;
  v_phone_e164 text;
  v_email_norm text;
  v_override text[] := array_remove(coalesce(p_override_block_uids, '{}'::text[]), null);
  v_exist public.booking_inquiries%rowtype;
  v_flow jsonb;
  v_flow_b public.booking_inquiries%rowtype;
  v_flow_id uuid;
  v_labelled jsonb;
  v_relabelled text[] := '{}'::text[];
  v_guest uuid;
  v_core jsonb;
  v_refused jsonb;
  v_review uuid;
  v_replay boolean := false;
  v_in date;
  v_out date;
  v_stamp text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  v_prep integer;
begin
  -- Gate: owner or admin, and approve_payment on the property (that action alone also admits finance; this gate does not).
  if v_uid is null
     or not coalesce(public.current_staff_active(array['owner', 'admin']), false)
     or not coalesce(public.current_staff_authorized('approve_payment', p_property_id), false) then
    return jsonb_build_object('ok', false, 'outcome', 'denied');
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 100 then
    return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'idempotency_key');
  end if;
  if p_property_id is null or not exists (select 1 from public.properties x where x.id = p_property_id) then
    return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'property_id');
  end if;

  -- The same property lock the core takes: a confirm, a site hold and this call never interleave on the dates.
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-property:' || p_property_id::text, 0));

  v_id := md5('offline-v1|' || p_idempotency_key)::uuid;
  v_ref := upper(left(v_id::text, 8));

  -- Replay: a booking with this id answers with its stored state and writes nothing.
  select * into v_exist from public.booking_inquiries where id = v_id;
  if found then
    if v_exist.property_id is distinct from p_property_id or v_exist.source is distinct from 'direct' then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'idempotency_key');
    end if;
    if v_exist.status is distinct from 'confirmed' then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'status', v_exist.status, 'booking_id', v_exist.id);
    end if;
    v_replay := true;
    v_in := v_exist.checkin_date;
    v_out := v_exist.checkout_date;
    v_name := v_exist.guest_name;
    v_total := v_exist.total_amount;
    v_deposit := v_exist.deposit_amount;
    select array_agg(ce.uid order by ce.uid) into v_relabelled
      from public.calendar_events ce
     where ce.property_id = p_property_id and ce.source = 'airbnb' and ce.status = 'blocked'
       and ce.block_reason = 'direct' and ce.block_note = 'DIR ' || v_ref || ' confirmed';
    v_relabelled := coalesce(v_relabelled, '{}'::text[]);
    select d.finance_review_id into v_review from public.booking_decisions d
     where d.idempotency_key = 'onetap:' || p_idempotency_key and d.outcome = 'confirmed' limit 1;
  else
    v_in := p_checkin;
    v_out := p_checkout;

    -- 1. Validate. Null is unknown, never zero (ML-05).
    if p_checkin is null or p_checkout is null or p_checkout <= p_checkin then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'dates');
    end if;
    if p_checkout <= v_today then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'checkout');
    end if;
    if p_pax is null or p_pax not between 1 and 4 then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'pax');
    end if;
    if p_total is null or p_total <= 0 or p_total > 99999999 then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'total');
    end if;
    if p_paid is null or p_paid <= 0 then
      return jsonb_build_object('ok', false, 'outcome', 'amount_required');
    end if;
    if p_paid > p_total + 1000 then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'paid');
    end if;
    if v_name is null or char_length(v_name) > 120 then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'guest_name');
    end if;
    if p_channel is null or p_channel not in ('facebook', 'walk_in', 'phone', 'other') then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'channel');
    end if;
    if v_method is null or v_method not in ('messenger_gcash', 'gcash_qr', 'bank', 'cash', 'other') then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'method');
    end if;
    if char_length(coalesce(v_phone, '')) > 40 then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'guest_phone');
    end if;
    if char_length(coalesce(v_email, '')) > 200 then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'guest_email');
    end if;
    if char_length(coalesce(v_note, '')) > 500 then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'note');
    end if;
    if char_length(coalesce(p_reference, '')) > 100 then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'reference');
    end if;
    if char_length(coalesce(v_psid, '')) > 200 then
      return jsonb_build_object('ok', false, 'outcome', 'invalid_input', 'field', 'psid');
    end if;
    v_total := round(p_total, 2);
    v_paid := round(p_paid, 2);
    v_deposit := least(v_paid, v_total);

    -- 2. Thread routing: a thread already in a booking is never overwritten.
    if v_psid is not null then
      select t.booking_flow into v_flow from public.concierge_threads t where t.psid = v_psid for update;
      if v_flow is not null and jsonb_typeof(v_flow) = 'object'
         and (v_flow ->> 'booking_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        v_flow_id := (v_flow ->> 'booking_id')::uuid;
        select * into v_flow_b from public.booking_inquiries b where b.id = v_flow_id and b.source = 'direct';
        if found then
          if v_flow_b.status = 'pending' then
            return jsonb_build_object('ok', false, 'outcome', 'thread_has_pending', 'booking_id', v_flow_b.id);
          elsif v_flow_b.status = 'confirmed' and v_flow_b.checkout_date >= v_today then
            return jsonb_build_object('ok', false, 'outcome', 'thread_linked_other', 'booking_id', v_flow_b.id);
          end if;
        end if;
      end if;
    end if;

    -- 3. Conflicts over the calendar rows that overlap the stay, in the contract's order.
    if exists (select 1 from public.calendar_events ce
                where ce.property_id = p_property_id and ce.status <> 'cancelled'
                  and ce.checkin_date < p_checkout and ce.checkout_date > p_checkin
                  and ce.source = 'airbnb' and ce.status = 'confirmed') then
      return jsonb_build_object('ok', false, 'outcome', 'conflict', 'reason', 'airbnb_stay');
    end if;
    if exists (select 1 from public.calendar_events ce
                where ce.property_id = p_property_id and ce.status <> 'cancelled'
                  and ce.checkin_date < p_checkout and ce.checkout_date > p_checkin
                  and ce.source = 'direct') then
      return jsonb_build_object('ok', false, 'outcome', 'conflict', 'reason', 'direct_booking');
    end if;
    if exists (select 1 from public.calendar_events ce
                where ce.property_id = p_property_id and ce.status <> 'cancelled'
                  and ce.checkin_date < p_checkout and ce.checkout_date > p_checkin
                  and ce.source = 'manual' and ce.uid like 'brownout:%') then
      return jsonb_build_object('ok', false, 'outcome', 'conflict', 'reason', 'brownout_hold');
    end if;
    if exists (select 1 from public.calendar_events ce
                where ce.property_id = p_property_id and ce.status <> 'cancelled'
                  and ce.checkin_date < p_checkout and ce.checkout_date > p_checkin
                  and ce.source = 'manual' and ce.status in ('confirmed', 'blocked')) then
      return jsonb_build_object('ok', false, 'outcome', 'conflict', 'reason', 'manual_block');
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('uid', ce.uid, 'reason', ce.block_reason, 'from', ce.checkin_date, 'to', ce.checkout_date)
                              order by ce.checkin_date, ce.uid), '[]'::jsonb)
      into v_labelled
      from public.calendar_events ce
     where ce.property_id = p_property_id and ce.source = 'airbnb' and ce.status = 'blocked'
       and ce.checkin_date < p_checkout and ce.checkout_date > p_checkin
       and ce.block_reason is not null
       and ce.block_reason <> 'direct'
       and ce.block_reason_source is distinct from 'assumed'
       and not (ce.uid = any (v_override));
    if jsonb_array_length(v_labelled) > 0 then
      return jsonb_build_object('ok', false, 'outcome', 'conflict', 'reason', 'labelled_block', 'blocks', v_labelled);
    end if;

    -- 4. Writes. Any refusal below raises RB001 (or an exclusion violation) and the whole sub-block is undone.
    begin
      -- 4.1 Every overlapping Airbnb block is now this stay's own: the note is byte-for-byte what calendar-sync writes for a
      --     direct booking, so the next sync finds it already so and resets it by itself after a cancel.
      with u as (
        update public.calendar_events ce
           set block_reason = 'direct', block_reason_source = 'auto', recon_status = 'skipped',
               block_note = 'DIR ' || v_ref || ' confirmed', block_answered_by = null, block_answered_at = null, updated_at = now()
         where ce.property_id = p_property_id and ce.source = 'airbnb' and ce.status = 'blocked'
           and ce.checkin_date < p_checkout and ce.checkout_date > p_checkin
        returning ce.uid)
      select coalesce(array_agg(u.uid order by u.uid), '{}'::text[]) into v_relabelled from u;

      -- 4.2 The hold, as submit-booking writes it.
      insert into public.calendar_events (property_id, uid, source, status, recon_status, checkin_date, checkout_date, guest_name, guest_phone, raw_summary)
      values (p_property_id, 'direct:' || v_id::text, 'direct', 'blocked', 'manual_entry', p_checkin, p_checkout, v_name, v_phone,
              'Direct booking (recorded offline) - ' || v_name);

      -- 4.3 The inquiry. deposit_amount = what was paid (capped at the total): the comparison and the guest messages read it as such.
      insert into public.booking_inquiries (id, property_id, guest_id, guest_name, guest_email, guest_phone, checkin_date, checkout_date, pax,
                                            total_amount, deposit_amount, status, source, channel, notes, receipt_image_path)
      values (v_id, p_property_id, null, v_name, v_email, v_phone, p_checkin, p_checkout, p_pax,
              v_total, v_deposit, 'pending', 'direct', p_channel, v_note, null);

      -- 4.4 The guest, resolved as the site resolves it (phone first, then e-mail; a conflict leaves guest_id null).
      v_digits := regexp_replace(coalesce(v_phone, ''), '\D', '', 'g');
      v_phone_e164 := case when v_digits ~ '^09\d{9}$' then '+63' || substr(v_digits, 2)
                           when v_digits ~ '^9\d{9}$' then '+63' || v_digits
                           when v_digits ~ '^639\d{9}$' then '+' || v_digits
                           else null end;
      v_email_norm := case when lower(v_email) ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then lower(v_email) else null end;
      select r.guest_id into v_guest
        from public.upsert_guest_for_booking(p_property_id, v_id, v_name, v_phone_e164, v_email_norm, 'direct') r;

      -- 4.5 The income row at the full total on the check-in date, pending until the core confirms it (G1).
      insert into public.transactions (property_id, txn_type, category, source, status, transaction_date, gross_amount, currency,
                                       payee_name, booking_id, external_ref, notes, tax_treatment, logged_by)
      values (p_property_id, 'income', 'direct_booking', 'direct_booking', 'pending_review', p_checkin, v_total, 'PHP',
              v_name, v_id, v_id::text,
              'Direct booking (recorded offline, ' || p_channel || ') - ' || (p_checkout - p_checkin)::text || 'n, ' || p_pax::text
                || ' pax. Paid PHP ' || to_char(v_deposit, 'FM999999990.00') || ' of PHP ' || to_char(v_total, 'FM999999990.00') || '.',
              'vat_exempt', 'record_offline_booking_v1');

      -- 4.6 Confirmation off: the once-only lock row, so guest-messages and due_guest_messages_v1 never send message 1.
      if p_send_confirmation is not true then
        insert into public.guest_message_log (booking_id, message_key, channel, status, detail)
        values (v_id, 'confirmation', 'card_only', 'skipped', 'recorded offline: host confirmed in the chat');
      end if;

      -- 4.7 The Messenger thread now belongs to this stay (lang kept); the guest's PSID is set only when empty.
      if v_psid is not null then
        insert into public.concierge_threads as t (psid, guest_name, booking_flow, updated_at)
        values (v_psid, v_name,
                jsonb_strip_nulls(jsonb_build_object(
                  'step', 'confirmed', 'booking_id', v_id, 'ref', 'DIR-' || v_ref,
                  'checkin', p_checkin, 'checkout', p_checkout, 'pax', p_pax, 'total', v_total, 'deposit', v_deposit,
                  'name', v_name, 'lang', case when v_flow is not null and jsonb_typeof(v_flow) = 'object' then v_flow ->> 'lang' else null end,
                  'started_at', v_stamp, 'updated_at', v_stamp)),
                now())
        on conflict (psid) do update set booking_flow = excluded.booking_flow, updated_at = now();
        if v_guest is not null then
          insert into public.guest_profile_details as g (guest_id, property_id, messenger_psid)
          values (v_guest, p_property_id, v_psid)
          on conflict (guest_id) do update set messenger_psid = excluded.messenger_psid, updated_at = now()
          where nullif(btrim(coalesce(g.messenger_psid, '')), '') is null;
        end if;
      end if;

      -- 4.8 The core: review + decide + confirm, in this transaction. The setting lets the engine ignore this booking's own labelled blocks.
      perform set_config('cascade.offline_booking_id', v_id::text, true);
      v_core := public._confirm_direct_booking_core(v_uid, v_id, v_method, p_reference, v_paid, p_note, null, p_idempotency_key);
      perform set_config('cascade.offline_booking_id', '', true);

      -- 4.9 Anything but confirmed undoes 4.1 to 4.8 and answers with the core's outcome.
      if v_core ->> 'outcome' is distinct from 'confirmed' then
        raise exception using errcode = 'RB001', message = v_core::text;
      end if;
      -- The core answers a key it already holds as confirmed + already_processed: that key belongs to another confirm, and nothing here may stay.
      if coalesce((v_core ->> 'already_processed')::boolean, false) then
        raise exception using errcode = 'RB001',
          message = jsonb_build_object('outcome', 'invalid_input', 'field', 'idempotency_key')::text;
      end if;
    exception
      when sqlstate 'RB001' then
        v_refused := sqlerrm::jsonb;
      when exclusion_violation then
        v_refused := jsonb_build_object('outcome', 'conflict', 'reason', 'direct_booking');
    end;
    perform set_config('cascade.offline_booking_id', '', true);

    if v_refused is not null then
      -- Keys that name rows the rollback just removed are dropped.
      return (v_refused - 'booking_id' - 'comparison_id' - 'comparison_outcome' - 'reattested' - 'finance_review_id'
                        - 'reviewer_user_id' - 'calendar_event_id' - 'already_processed')
             || jsonb_build_object('ok', false, 'already_processed', false);
    end if;
    v_review := nullif(v_core ->> 'finance_review_id', '')::uuid;
  end if;

  -- app_settings airbnb_prep_nights, read exactly as run_system_verifier_v1 reads it (default 1, never below 0)
  select greatest(coalesce((select case when jsonb_typeof(a.value) = 'number' then floor((a.value #>> '{}')::numeric)::integer end
                              from public.app_settings a where a.key = 'airbnb_prep_nights'), 1), 0) into v_prep;

  return jsonb_build_object(
    'ok', true,
    'outcome', 'recorded',
    'already_processed', v_replay,
    'booking_id', v_id,
    'booking_ref', v_ref,
    'checkin', v_in,
    'checkout', v_out,
    'guest_name', v_name,
    'balance', greatest(v_total - v_deposit, 0),
    'blocks_relabelled', to_jsonb(v_relabelled),
    -- nights of the stay that no Airbnb row covers: Airbnb can still sell them, so the app tells the host to block them there
    'airbnb_nights_uncovered', coalesce((
        select jsonb_agg((v_in + g.n) order by g.n)
          from generate_series(0, v_out - v_in - 1) g(n)
         where not exists (select 1 from public.calendar_events ce
                            where ce.property_id = p_property_id and ce.source = 'airbnb' and ce.status in ('blocked', 'confirmed')
                              and ce.checkin_date <= v_in + g.n and ce.checkout_date > v_in + g.n)), '[]'::jsonb),
    -- a relabelled block that starts or ends more than the Airbnb preparation nights outside the stay: the verifier's V1m rule
    'block_runs_past_stay', exists (select 1 from public.calendar_events ce
                                     where ce.property_id = p_property_id and ce.uid = any (v_relabelled)
                                       and (ce.checkin_date < v_in - v_prep or ce.checkout_date > v_out + v_prep)),
    'finance_review_id', v_review);
end $$;

revoke all on function public.record_offline_booking_v1(uuid, date, date, text, text, text, text, integer, numeric, numeric, text, text, text, text, boolean, text[], text)
  from public, anon, authenticated, service_role;
grant execute on function public.record_offline_booking_v1(uuid, date, date, text, text, text, text, integer, numeric, numeric, text, text, text, text, boolean, text[], text)
  to authenticated;
comment on function public.record_offline_booking_v1(uuid, date, date, text, text, text, text, integer, numeric, numeric, text, text, text, text, boolean, text[], text) is
  'Record a booking agreed outside the site (Messenger, walk-in, phone) and confirm it in the same transaction through _confirm_direct_booking_core. Owner or admin with approve_payment. Replays by idempotency key; a refusal of the core undoes every write.';
