-- Rollback of release s136_followups_20261206. Restores the cf_confirm_flow four-argument decline body (md5 42905864d5b773d0503a2e518ec26a50) and the CURRENT_DATE default of inventory_purchases.purchased_at.
-- Guard: the live decline must be this release (md5 7cf6e1a294db9ede851253de7c93f4f9) or already the cf body; the default must be manila_today() or current_date; 55000 on anything else. Grants restated (same signature).
-- run-sql-on-host.sh does NOT wrap a file: this script carries its own begin/commit, so a failed guard or statement leaves nothing half-rolled-back.

begin;

do $g$
declare v text; d text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure('public.staff_decline_direct_booking_v1(uuid,text,text,text)');
  if v is null then raise exception 's136 rollback: staff_decline_direct_booking_v1(uuid,text,text,text) is missing' using errcode = '55000'; end if;
  if v is distinct from '7cf6e1a294db9ede851253de7c93f4f9' and v is distinct from '42905864d5b773d0503a2e518ec26a50' then
    raise exception 's136 rollback: staff_decline_direct_booking_v1 is neither this release nor the cf body (md5 %)', v using errcode = '55000';
  end if;
  select pg_get_expr(ad.adbin, ad.adrelid) into d from pg_attrdef ad join pg_attribute a on a.attrelid = ad.adrelid and a.attnum = ad.adnum
   where ad.adrelid = 'public.inventory_purchases'::regclass and a.attname = 'purchased_at';
  if d is null or (d !~* '^(current_date|public\.manila_today\(\)|manila_today\(\))$') then
    raise exception 's136 rollback: inventory_purchases.purchased_at default is unexpected (%)', coalesce(d, 'none') using errcode = '55000';
  end if;
end $g$;

create or replace function public.staff_decline_direct_booking_v1(p_booking_id uuid, p_reason text, p_idempotency_key text, p_reason_code text)
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

alter table public.inventory_purchases alter column purchased_at set default current_date;

commit;
