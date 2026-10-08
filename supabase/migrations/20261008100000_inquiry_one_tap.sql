-- Session 76 (SPEC-44 Revision 1, the contract): release inquiry_one_tap_20261008. One-tap inquiry approval.
--
-- Why: Confirm needed a Finance review that only existed when a guest image reached upload-booking-receipt. A Messenger in-app
-- GCash transfer never does, so BD296460 was confirmed from the Finance queue by flipping the income row: fn_direct_booking_cascade
-- confirmed the booking with no review, no overlap recheck, no DIRECT: reservation, no booking_decisions row and no calendar rename.
--
--   _confirm_direct_booking_core        review + decide in one transaction, for a receipt (comparison id) or "paid outside" (a
--                                       manual_evidence candidate derived from the idempotency key). No grants.
--   staff_confirm_direct_booking_v1     authenticated; approve_payment on the booking's property; actor = auth.uid().
--   telegram_confirm_direct_booking_v1  service_role; maps the tapper's Telegram id exactly as telegram_finance_decide_booking_v1.
--   staff_decline_direct_booking_v1     authenticated; approve_payment; rejected review + decide, or the no-review decline engine.
--   staff_inquiry_payments_v1           read_finance or approve_payment; one row per pending direct booking (plain row set).
--   guard_direct_booking_income_confirm BEFORE UPDATE OF status ON transactions: an income-row flip to confirmed while the booking is
--                                       still pending raises confirm_from_inquiries. No exception block (the cascade's would swallow it).
--   fn_direct_booking_cascade           loses its confirm leg (and the confirmEmail it sent); the void leg is unchanged.
--   _repair_bypass_confirmed_v1         DIRECT: reservation, calendar link + rename and one booking_decisions row for every direct
--                                       booking confirmed through the bypass; run once below. No transactions write, no review
--                                       invented, no guest message. Idempotent.
--   concierge_resume_cassy_v1           manage_operations; clears concierge_threads.human_until; audited in admin_audit_log.
-- Outcomes: confirmed | conflict | invalid_state | reference_reused | not_linked | amount_required | reference_required |
--           note_required | denied (decline adds declined; resume uses resumed | not_found | denied).
-- Rollback: supabase/rollbacks/20261008_inquiry_one_tap.sql (restores the live cascade body; repair rows are kept).
begin;

-- 1. The core. Called only by the definer wrappers below (owner), so it carries no grant at all.
create or replace function public._confirm_direct_booking_core(
  p_actor uuid, p_booking_id uuid, p_method text, p_reference text, p_amount numeric, p_note text,
  p_comparison_id uuid, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b public.booking_inquiries%rowtype;
  c public.payment_evidence_comparisons%rowtype;
  v_review public.payment_finance_reviews%rowtype;
  v_dec public.booking_decisions%rowtype;
  v_key text;
  v_method text := nullif(lower(btrim(coalesce(p_method, ''))), '');
  v_ref text := nullif(regexp_replace(upper(btrim(coalesce(p_reference, ''))), '[^A-Z0-9]', '', 'g'), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_amount numeric(12,2);
  v_hash text;
  v_candidate uuid;
  v_comparison uuid;
  v_prior uuid;
  v_reason text;
  v_res jsonb;
  v_secret text;
  v_base jsonb;
  v_reattest boolean := false;
  v_inserted boolean := false;
begin
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 120 then
    raise exception using errcode = '22023', message = 'idempotency key must be 16 to 120 characters';
  end if;
  if p_actor is null then
    raise exception using errcode = '42501', message = 'a named staff actor is required';
  end if;
  v_key := 'onetap:' || p_idempotency_key;

  -- Retries serialize on the key; a key that already decided answers with the stored outcome and writes nothing.
  perform pg_advisory_xact_lock(hashtextextended('cascade-onetap-confirm:' || p_idempotency_key, 0));
  select * into b from public.booking_inquiries where id = p_booking_id and source = 'direct' for update;
  if not found then
    return jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'not_found', 'booking_id', p_booking_id);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-property:' || b.property_id::text, 0));
  v_base := jsonb_build_object('booking_id', b.id, 'booking_ref', upper(left(b.id::text, 8)), 'guest_name', b.guest_name,
                               'checkin', b.checkin_date, 'checkout', b.checkout_date);

  select * into v_dec from public.booking_decisions where idempotency_key = v_key;
  if found then
    return v_base || jsonb_build_object('ok', v_dec.outcome = 'confirmed', 'outcome', v_dec.outcome, 'already_processed', true,
                                        'finance_review_id', v_dec.finance_review_id);
  end if;

  -- State before input: a booking that is no longer pending answers not_pending whatever was typed.
  if b.status <> 'pending' then
    return v_base || jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'not_pending', 'status', b.status);
  end if;

  if p_amount is null or p_amount <= 0 then
    return v_base || jsonb_build_object('ok', false, 'outcome', 'amount_required');
  end if;
  v_amount := round(p_amount, 2);
  if v_method is not null and v_method not in ('messenger_gcash', 'gcash_qr', 'bank', 'cash', 'other') then
    raise exception using errcode = '22023', message = 'method must be messenger_gcash, gcash_qr, bank, cash or other';
  end if;
  -- Optional on the receipt and cash paths: a malformed reference there is dropped, not stored.
  if v_ref is not null and v_ref !~ '^[A-Z0-9]{4,64}$' and (p_comparison_id is not null or v_method = 'cash') then
    v_ref := null;
  end if;
  if p_comparison_id is null then
    if v_method is null then
      raise exception using errcode = '22023', message = 'how it was paid (method) is required';
    end if;
    if v_method = 'cash' then
      if v_note is null or char_length(v_note) < 3 then
        return v_base || jsonb_build_object('ok', false, 'outcome', 'note_required');
      end if;
    elsif v_ref is null or v_ref !~ '^[A-Z0-9]{4,64}$' then
      return v_base || jsonb_build_object('ok', false, 'outcome', 'reference_required');
    end if;
  end if;

  if p_comparison_id is not null then
    select * into c from public.payment_evidence_comparisons where id = p_comparison_id;
    if not found or c.booking_id <> b.id then
      return v_base || jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'comparison_not_for_booking');
    end if;
    select * into v_review from public.payment_finance_reviews
     where comparison_id = c.id and outcome in ('approved', 'rejected')
     order by created_at desc, id limit 1 for share;
    if found then
      if v_review.outcome <> 'approved' then
        return v_base || jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'already_rejected', 'comparison_id', c.id);
      end if;
      if exists (select 1 from public.booking_decisions d where d.finance_review_id = v_review.id and d.outcome = 'confirmed') then
        -- Defensive only: a confirmed decision means a confirmed booking, which not_pending has already answered.
        return v_base || jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'review_already_used', 'comparison_id', c.id);
      end if;
      if exists (select 1 from public.booking_decisions d where d.finance_review_id = v_review.id) then
        -- The approval was spent on an attempt that did not confirm (a calendar conflict). A comparison takes one final review
        -- (payment_finance_review_one_final_idx) and a review one decision, so the receipt is re-attested: a key-derived
        -- manual_evidence candidate joins the receipt's candidates in a NEW comparison, and the fresh review below goes on that.
        v_reattest := true;
        v_hash := encode(extensions.digest('onetap-reattest-v1|' || b.id::text || '|' || p_idempotency_key, 'sha256'), 'hex');
        v_candidate := public.record_payment_evidence_candidate(
          b.id, 'manual_evidence', 'reattest:' || md5(p_idempotency_key)::uuid::text, v_hash, 'onetap-reattest:' || p_idempotency_key,
          'onetap-v1', now(), v_amount, 'PHP', v_ref, null, array['reattest', coalesce(v_method, 'receipt')], 'not_applicable', null);
        v_comparison := public.compare_booking_payment_evidence(b.id, c.evidence_candidate_ids[1:7] || v_candidate);
        select * into c from public.payment_evidence_comparisons where id = v_comparison;
        v_review := null;
      end if;
    end if;
  else
    -- A typed reference already seen on another booking of the property is refused (the receipt path keeps prior use advisory).
    if v_ref is not null then
      select e.booking_id into v_prior from public.payment_evidence_candidates e
       where e.property_id = b.property_id and e.booking_id <> b.id and e.normalized_reference = v_ref
       order by e.created_at desc limit 1;
      if found then
        return v_base || jsonb_build_object('ok', false, 'outcome', 'reference_reused', 'prior_ref', upper(left(v_prior::text, 8)));
      end if;
    end if;
    -- Deterministic from the key: a retry finds the same candidate and the same comparison.
    v_hash := encode(extensions.digest('onetap-manual-v1|' || b.id::text || '|' || p_idempotency_key, 'sha256'), 'hex');
    v_candidate := public.record_payment_evidence_candidate(
      b.id, 'manual_evidence', 'manual:' || md5(p_idempotency_key)::uuid::text, v_hash, 'onetap-manual:' || p_idempotency_key,
      'onetap-v1', now(), v_amount, 'PHP', v_ref, null, array['paid_outside', v_method], 'not_applicable', null);
    v_comparison := public.compare_booking_payment_evidence(b.id, array[v_candidate]);
    select * into c from public.payment_evidence_comparisons where id = v_comparison;
    -- A paid-outside comparison is new to this key, so a final review on it can only be this key's own, from an earlier
    -- attempt that did not decide (none survives a 23P01, see below); reject anything else.
    select * into v_review from public.payment_finance_reviews
     where comparison_id = c.id and outcome in ('approved', 'rejected')
     order by created_at desc, id limit 1 for share;
    if found and v_review.outcome <> 'approved' then
      return v_base || jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'already_rejected', 'comparison_id', c.id);
    end if;
    if found and exists (select 1 from public.booking_decisions d where d.finance_review_id = v_review.id) then
      return v_base || jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'review_already_used', 'comparison_id', c.id);
    end if;
  end if;

  v_reason := left(concat_ws(' / ', 'One-tap confirm', coalesce(v_method, 'receipt'), 'ref ' || v_ref,
                             'PHP ' || to_char(v_amount, 'FM999999990.00'), 'note ' || v_note), 500);
  -- The review insert and the decision share one subtransaction: an active-hold refusal (23P01) leaves neither behind, so a
  -- retry with a new key records a fresh review on the same comparison. A calendar conflict is a stored decision (the engine's
  -- audit row) holding its review; the re-attest branch above handles the retry.
  begin
    if v_review.id is null then
      insert into public.payment_finance_reviews (property_id, booking_id, comparison_id, reviewer_user_id, outcome, reason)
      values (c.property_id, c.booking_id, c.id, p_actor, 'approved', v_reason)
      returning * into v_review;
      v_inserted := true;
    end if;
    v_res := public.decide_direct_booking(b.id, 'confirm', v_key, v_review.id);
  exception when sqlstate '23P01' then
    -- guard_direct_booking_lifecycle_transition: another request's active hold overlaps. Nothing of the decision persists.
    v_res := jsonb_build_object('ok', false, 'outcome', 'conflict', 'reason', 'active_hold', 'already_processed', false);
    if v_inserted then v_review := null; end if;
  end;

  if v_res ->> 'outcome' = 'confirmed' and coalesce((v_res ->> 'already_processed')::boolean, false) is not true then
    -- The host decided, so guest-messages sends even under a D-317 hold (tapped). Queued by pg_net only if this commits.
    -- A missing pg_net/Vault (rehearsal, CI) or a failed enqueue never blocks the confirmation.
    begin
      if to_regnamespace('net') is not null and to_regclass('vault.decrypted_secrets') is not null then
        select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'cascade_cron_shared_secret';
        if coalesce(length(v_secret), 0) > 0 then
          perform net.http_post(
            url     := 'https://qkgfhsdppslwunarczeq.supabase.co/functions/v1/guest-messages',
            headers := jsonb_build_object('Content-Type', 'application/json', 'x-cascade-cron-secret', v_secret),
            body    := jsonb_build_object('booking_id', b.id, 'tapped', true),
            timeout_milliseconds := 45000);
        end if;
      end if;
    exception when others then
      raise warning '_confirm_direct_booking_core: guest-messages not queued: %', sqlerrm;
    end;
  end if;

  return v_base || v_res || jsonb_build_object('booking_id', b.id, 'comparison_id', c.id, 'comparison_outcome', c.comparison_outcome,
                                               'reattested', v_reattest,
                                               'finance_review_id', v_review.id, 'reviewer_user_id', v_review.reviewer_user_id);
end $$;
revoke all on function public._confirm_direct_booking_core(uuid, uuid, text, text, numeric, text, uuid, text)
  from public, anon, authenticated, service_role;
comment on function public._confirm_direct_booking_core(uuid, uuid, text, text, numeric, text, uuid, text) is
  'SPEC-44: approved review + decide_direct_booking in one transaction, for a receipt comparison or a paid-outside manual_evidence candidate. Called only by staff_/telegram_confirm_direct_booking_v1.';

-- 2. Staff session gate.
create or replace function public.staff_confirm_direct_booking_v1(
  p_booking_id uuid, p_method text, p_reference text, p_amount numeric, p_note text, p_comparison_id uuid, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_property uuid;
begin
  select property_id into v_property from public.booking_inquiries where id = p_booking_id and source = 'direct';
  if not found then
    return jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'not_found', 'booking_id', p_booking_id);
  end if;
  if auth.uid() is null or not coalesce(public.current_staff_authorized('approve_payment', v_property), false) then
    return jsonb_build_object('ok', false, 'outcome', 'denied', 'booking_id', p_booking_id);
  end if;
  return public._confirm_direct_booking_core(auth.uid(), p_booking_id, p_method, p_reference, p_amount, p_note,
                                             p_comparison_id, p_idempotency_key);
end $$;
revoke all on function public.staff_confirm_direct_booking_v1(uuid, text, text, numeric, text, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_confirm_direct_booking_v1(uuid, text, text, numeric, text, uuid, text) to authenticated;

-- 3. Telegram gate: the tapper's Telegram id -> staff profile with approve_payment and property access, as
--    telegram_finance_decide_booking_v1 maps it. A confirm needs a named reviewer, so an unmapped id is not_linked.
create or replace function public.telegram_confirm_direct_booking_v1(
  p_telegram_user_id bigint, p_booking_id uuid, p_method text, p_reference text, p_amount numeric, p_note text,
  p_comparison_id uuid, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p public.staff_access_profiles%rowtype;
  v_property uuid;
begin
  if p_telegram_user_id is null then return jsonb_build_object('ok', false, 'outcome', 'not_linked'); end if;
  select * into p from public.staff_access_profiles where telegram_user_id = p_telegram_user_id;
  if not found then return jsonb_build_object('ok', false, 'outcome', 'not_linked'); end if;
  select property_id into v_property from public.booking_inquiries where id = p_booking_id and source = 'direct';
  if not found then
    return jsonb_build_object('ok', false, 'outcome', 'invalid_state', 'reason', 'not_found', 'booking_id', p_booking_id);
  end if;
  if not public.staff_access_allowed(p.role, 'approve_payment', p.disabled_at, null)
     or not (p.role = 'owner' or exists (
       select 1 from public.staff_property_access s where s.user_id = p.user_id and s.property_id = v_property)) then
    return jsonb_build_object('ok', false, 'outcome', 'denied', 'booking_id', p_booking_id);
  end if;
  return public._confirm_direct_booking_core(p.user_id, p_booking_id, p_method, p_reference, p_amount, p_note,
                                             p_comparison_id, p_idempotency_key)
         || jsonb_build_object('reviewer_role', p.role);
end $$;
revoke all on function public.telegram_confirm_direct_booking_v1(bigint, uuid, text, text, numeric, text, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.telegram_confirm_direct_booking_v1(bigint, uuid, text, text, numeric, text, uuid, text) to service_role;

-- 4. Decline. With a comparison still open to a decision: a rejected review by the caller, then decide decline. Without one: the
--    no-review decline engine the Telegram request card uses. One audit row either way.
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

-- 5. The Inquiries payment line: one row per pending direct booking. comparison_id is the newest comparison over a guest-sent
--    receipt (paid-outside attempts are left out, so "receipt present" means a real receipt).
create or replace function public.staff_inquiry_payments_v1(p_property_id uuid)
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

-- 6. Close the bypass. The guard is its own BEFORE trigger with no exception block: the cascade's EXCEPTION WHEN OTHERS would
--    swallow a raise. decide_direct_booking confirms the booking BEFORE it flips the income row, so its flip passes; a second
--    income row on an already-confirmed booking passes; void is untouched.
create or replace function public.guard_direct_booking_income_confirm()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.booking_inquiries b
              where b.status = 'pending'
                and (b.id = new.booking_id or (new.booking_id is null and b.id::text = new.external_ref))) then
    raise exception using errcode = '55000', hint = 'confirm_from_inquiries',
      message = 'Confirm the booking from Inquiries; it records the payment and the booking together.';
  end if;
  return new;
end $$;
revoke all on function public.guard_direct_booking_income_confirm() from public, anon, authenticated, service_role;
drop trigger if exists trg_guard_direct_booking_income_confirm on public.transactions;
create trigger trg_guard_direct_booking_income_confirm
before update of status on public.transactions
for each row
when (new.source = 'direct_booking' and new.status = 'confirmed' and old.status is distinct from 'confirmed')
execute function public.guard_direct_booking_income_confirm();

-- The live body (md5 934f4b40af823ca3e74b144698c3910e, read 2026-10-08) without its confirm leg: no booking/calendar confirm and no
-- confirmEmail. The void leg is byte-for-byte the same statements.
create or replace function public.fn_direct_booking_cascade()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.booking_id is null then return new; end if;

  -- SPEC-44: confirming happens only in decide_direct_booking (which flips the income row itself), so a confirmed row is a no-op.
  if new.status = 'void' and old.status is distinct from 'void' then
    update public.booking_inquiries
       set status = 'cancelled'
     where id = new.booking_id and status <> 'cancelled';
    update public.calendar_events
       set status = 'cancelled'
     where uid = 'direct:' || new.booking_id::text and status <> 'cancelled';
  end if;

  return new;
exception when others then
  -- never block the ledger update because of a cascade hiccup
  raise warning 'fn_direct_booking_cascade error: %', sqlerrm;
  return new;
end $$;
revoke all on function public.fn_direct_booking_cascade() from public, anon, authenticated, service_role;

-- 7. Repair the bookings the bypass confirmed (live 2026-10-08: BD296460 and 92F94D0E): what decide_direct_booking would have
--    written for the reservation, the calendar and the decision. Nothing else.
create or replace function public._repair_bypass_confirmed_v1()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  b public.booking_inquiries%rowtype;
  v_res uuid;
  v_cal uuid;
  n integer := 0;
begin
  for b in
    select x.* from public.booking_inquiries x
     where x.source = 'direct' and x.status = 'confirmed'
       and not exists (select 1 from public.airbnb_reservations r where r.confirmation_code = 'DIRECT:' || x.id::text)
       and not exists (select 1 from public.booking_decisions d where d.booking_id = x.id and d.outcome = 'confirmed')
     order by x.checkin_date, x.id
     for update
  loop
    insert into public.airbnb_reservations (
      property_id, confirmation_code, source, status, guest_id, guest_name,
      guest_count, checkin_date, checkout_date, guest_paid, cancelled_at
    ) values (
      b.property_id, 'DIRECT:' || b.id::text, 'direct', 'confirmed', b.guest_id, b.guest_name,
      b.pax, b.checkin_date, b.checkout_date, b.total_amount, null
    ) on conflict (confirmation_code) do nothing;
    select r.id into v_res from public.airbnb_reservations r where r.confirmation_code = 'DIRECT:' || b.id::text;

    -- Prefer a row already renamed; otherwise rename the direct: row (both at once would collide on (uid, property_id)).
    select ce.id into v_cal from public.calendar_events ce
     where ce.property_id = b.property_id and ce.uid in ('cascade-direct-' || b.id::text, 'direct:' || b.id::text)
     order by case when ce.uid = 'cascade-direct-' || b.id::text then 0 else 1 end
     limit 1 for update;
    if v_cal is null then
      insert into public.calendar_events (
        property_id, uid, source, status, checkin_date, checkout_date, guest_name, guest_phone, linked_reservation_id, recon_status
      ) values (
        b.property_id, 'cascade-direct-' || b.id::text, 'direct', 'confirmed', b.checkin_date, b.checkout_date,
        b.guest_name, b.guest_phone, v_res, 'matched'
      ) returning id into v_cal;
    else
      update public.calendar_events set
        uid = 'cascade-direct-' || b.id::text, status = 'confirmed', linked_reservation_id = v_res,
        recon_status = 'matched', updated_at = now()
      where id = v_cal;
    end if;

    insert into public.booking_decisions (booking_id, action, outcome, idempotency_key, calendar_event_id)
    values (b.id, 'confirm', 'confirmed', 'repair:bypass:' || b.id::text, v_cal)
    on conflict (idempotency_key) do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public._repair_bypass_confirmed_v1() from public, anon, authenticated, service_role;
comment on function public._repair_bypass_confirmed_v1() is
  'SPEC-44 repair: DIRECT: reservation, calendar link/rename and a repair:bypass:<id> booking_decisions row for direct bookings confirmed by an income-row flip. No transactions write, no review, no guest message. Idempotent; returns the count repaired.';

select public._repair_bypass_confirmed_v1();

-- 8. Hand-back (Lloyd 2026-10-08): Let Cassy answer again on a thread the host paused. Audited (entity id = md5(psid) as uuid,
--    states carry psid_short only).
create or replace function public.concierge_resume_cassy_v1(p_psid text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prop uuid;
  t public.concierge_threads%rowtype;
begin
  select p.id into v_prop from public.properties p
   where auth.uid() is not null and public.current_staff_authorized('manage_operations', p.id)
   order by (p.id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd') desc, p.id limit 1;
  if v_prop is null then return jsonb_build_object('ok', false, 'outcome', 'denied'); end if;
  select * into t from public.concierge_threads where psid = p_psid for update;
  if not found then return jsonb_build_object('ok', false, 'outcome', 'not_found'); end if;
  if t.human_until is null then
    return jsonb_build_object('ok', true, 'outcome', 'resumed', 'already', true, 'psid_short', left(md5(t.psid), 8));
  end if;
  update public.concierge_threads set human_until = null where psid = t.psid;
  insert into public.admin_audit_log(property_id, entity_table, entity_id, action, before_state, after_state, reason, actor_user_id)
  values (v_prop, 'concierge_threads', md5(t.psid)::uuid, 'update',
          jsonb_build_object('psid_short', left(md5(t.psid), 8), 'human_until', t.human_until),
          jsonb_build_object('psid_short', left(md5(t.psid), 8), 'human_until', null),
          'Let Cassy answer again', auth.uid());
  return jsonb_build_object('ok', true, 'outcome', 'resumed', 'already', false, 'psid_short', left(md5(t.psid), 8),
                            'was_paused_until', t.human_until);
end $$;
revoke all on function public.concierge_resume_cassy_v1(text) from public, anon, authenticated, service_role;
grant execute on function public.concierge_resume_cassy_v1(text) to authenticated;

commit;
