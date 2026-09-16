-- Telegram Finance tap (session 27, booking PRD C2, D-160 #3): a tap on the receipt card's
-- [Confirm]/[Decline] must be a NAMED review. record_payment_finance_review needs auth.uid(), which a
-- bot cannot present, so this definer maps the tapper's Telegram user id to a staff profile, records
-- the review under that user, and runs the same decide_direct_booking the dashboard uses. Unmapped or
-- unauthorized ids are refused (jsonb, no exception). Also: the hourly releaser's 2 h nudge needs to see
-- payment_finance_reviews, which service_role cannot read - hence unreviewed_booking_receipts_v1.
begin;

alter table public.staff_access_profiles add column if not exists telegram_user_id bigint;
create unique index if not exists staff_access_profiles_telegram_user_id_key
  on public.staff_access_profiles (telegram_user_id) where telegram_user_id is not null;
comment on column public.staff_access_profiles.telegram_user_id is
  'Telegram user id allowed to act as this staff profile from the Finance group (session 27). Null = no Telegram taps.';

-- Lloyd (admin profile, rocloyd87) = Telegram 497550740 (FACTS). Others are mapped from the dashboard later.
update public.staff_access_profiles set telegram_user_id = 497550740
 where user_id = 'fea44ac5-61b0-41a6-8616-d7823e99151b' and telegram_user_id is null;

create or replace function public.telegram_finance_decide_booking_v1(
  p_telegram_user_id bigint, p_comparison_id uuid, p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p public.staff_access_profiles%rowtype;
  c public.payment_evidence_comparisons%rowtype;
  v_existing public.payment_finance_reviews%rowtype;
  v_review uuid; v_outcome text; v_res jsonb;
begin
  if p_action not in ('confirm', 'decline') then return jsonb_build_object('ok', false, 'reason', 'bad_action'); end if;
  if p_telegram_user_id is null then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  select * into p from public.staff_access_profiles where telegram_user_id = p_telegram_user_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unmapped_telegram_user'); end if;
  select * into c from public.payment_evidence_comparisons where id = p_comparison_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'comparison_not_found'); end if;
  if not public.staff_access_allowed(p.role, 'approve_payment', p.disabled_at, null)
     or not (p.role = 'owner' or exists (
       select 1 from public.staff_property_access s where s.user_id = p.user_id and s.property_id = c.property_id)) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;

  v_outcome := case p_action when 'confirm' then 'approved' else 'rejected' end;
  select * into v_existing from public.payment_finance_reviews
   where comparison_id = c.id and outcome in ('approved', 'rejected') for share;
  if found then
    if v_existing.outcome <> v_outcome then
      return jsonb_build_object('ok', false, 'reason', 'already_reviewed', 'outcome', v_existing.outcome);
    end if;
    v_review := v_existing.id;
  else
    insert into public.payment_finance_reviews (property_id, booking_id, comparison_id, reviewer_user_id, outcome, reason)
    values (c.property_id, c.booking_id, c.id, p.user_id, v_outcome,
            coalesce(nullif(btrim(p_reason), ''), 'Telegram tap ' || p_telegram_user_id::text))
    returning id into v_review;
  end if;

  v_res := public.decide_direct_booking(c.booking_id, p_action,
             'telegram-tap:' || c.booking_id::text || ':' || p_action || ':' || v_review::text, v_review);
  return v_res || jsonb_build_object('reviewer_user_id', p.user_id, 'reviewer_role', p.role, 'finance_review_id', v_review);
end $$;
revoke all on function public.telegram_finance_decide_booking_v1(bigint, uuid, text, text) from public, anon, authenticated;
grant execute on function public.telegram_finance_decide_booking_v1(bigint, uuid, text, text) to service_role;

-- Pending direct requests whose receipt has sat unreviewed for between p_min_hours and p_max_hours.
create or replace function public.unreviewed_booking_receipts_v1(p_min_hours numeric, p_max_hours numeric)
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'guest_name', b.guest_name, 'checkin_date', b.checkin_date, 'checkout_date', b.checkout_date,
           'deposit_amount', b.deposit_amount, 'total_amount', b.total_amount, 'updated_at', b.updated_at)
         order by b.updated_at), '[]'::jsonb)
    from public.booking_inquiries b
   where b.source = 'direct' and b.status = 'pending' and b.receipt_image_path is not null
     and b.updated_at <= now() - (p_min_hours * interval '1 hour')
     and b.updated_at >  now() - (p_max_hours * interval '1 hour')
     and not exists (select 1 from public.payment_finance_reviews r
                      where r.booking_id = b.id and r.outcome in ('approved', 'rejected'));
$$;
revoke all on function public.unreviewed_booking_receipts_v1(numeric, numeric) from public, anon, authenticated;
grant execute on function public.unreviewed_booking_receipts_v1(numeric, numeric) to service_role;

commit;
