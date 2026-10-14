-- Rollback for release s84_calendar_20261017. Compensating, not a restore.
--   * puts admin_stays_v1 back to its pre-release body (md5 e2f41dcc6de28ba1ebe23b4534b6443d, read from production 2026-10-14), i.e.
--     with NO role check (the privacy hole returns: re-apply the fix as soon as possible);
--   * puts staff_pay_admin_step_v1 back to the body in 20261014010000_s81_staff_pay_push.sql (md5 ee76bfac5542808058969b731940f343);
--   * drops staff_calendar_history_v1 and the gate admin_stays_gate_v1 (nothing else calls them).
-- The staff app probes staff_calendar_history_v1 and hides the past-months view when it is gone. Safe until: any time. No data is written.
begin;

create or replace function public.admin_stays_v1(p_property_id uuid)
returns table (
  stay_kind text, stay_id uuid, code text, guest_id uuid, guest_name text,
  checkin date, checkout date, nights integer, status text,
  accommodation_total numeric, allocation_method text, booking_created date, payout_date date, host_payout numeric
) language sql stable security definer set search_path = '' as $$
  select 'airbnb', r.id, r.confirmation_code, r.guest_id, r.guest_name, r.checkin_date, r.checkout_date,
         (r.checkout_date - r.checkin_date), r.status,
         case
           when t.gross_earnings is not null then round(t.gross_earnings - coalesce(t.cleaning_fee, 0), 2)
           when r.host_payout is not null then round(r.host_payout + coalesce(r.host_service_fee, 0), 2)
           else null end,
         case
           when t.gross_earnings is not null then 'airbnb_transactions_gross_less_cleaning'
           when r.host_payout is not null then 'host_payout_plus_host_fee'
           else 'missing' end,
         t.booking_date, r.payout_date, r.host_payout
  from public.airbnb_reservations r
  left join lateral (
    select max(x.gross_earnings) gross_earnings, max(x.cleaning_fee) cleaning_fee, min(x.booking_date) booking_date
    from public.airbnb_transactions x
    where x.property_id = r.property_id and x.confirmation_code = r.confirmation_code and x.row_type = 'reservation'
  ) t on true
  where r.property_id = p_property_id and r.checkin_date is not null and r.checkout_date is not null
  union all
  select 'direct', i.id, 'DIR-' || upper(left(i.id::text, 8)), i.guest_id, i.guest_name, i.checkin_date, i.checkout_date,
         (i.checkout_date - i.checkin_date),
         case when i.status in ('confirmed','completed') then i.status when i.status in ('cancelled','declined') then 'cancelled' else 'inquiry' end,
         i.total_amount, case when i.total_amount is not null then 'direct_quoted_total' else 'missing' end,
         i.submitted_at::date, null, null
  from public.booking_inquiries i
  where i.property_id = p_property_id;
$$;
revoke all on function public.admin_stays_v1(uuid) from public, anon, service_role;
grant execute on function public.admin_stays_v1(uuid) to authenticated;

create or replace function public.staff_pay_admin_step_v1(p_request_id uuid, p_step text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_prop constant uuid := '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
  v_uid uuid := auth.uid();
  v_name text; v_r public.staff_pay_requests%rowtype; v_res jsonb;
begin
  if v_uid is null or not public.current_staff_authorized('approve_payment', c_prop) then
    return jsonb_build_object('ok', false, 'reason', 'not_authorized');
  end if;
  if p_step not in ('pay', 'sent', 'takeover', 'not_sent', 'cancel') then return jsonb_build_object('ok', false, 'reason', 'bad_step'); end if;
  select * into v_r from public.staff_pay_requests where id = p_request_id and property_id = c_prop for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                  initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')), 'Finance')
    into v_name from auth.users u where u.id = v_uid;
  v_name := left(coalesce(v_name, 'Finance'), 30);

  if p_step = 'pay' and v_r.status = 'paying' and v_r.paying_by_user_id = v_uid then -- opening my own payment again
    return jsonb_build_object('ok', true, 'status', 'paying', 'ref', v_r.ref, 'total', v_r.total_amount, 'paying_by_user_id', v_uid);
  end if;
  if p_step = 'sent' then -- the payer has scanned, copied or saved: from now on a take-over or a Telegram cancel is refused (money_may_be_sent)
    if v_r.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', v_r.status, 'ref', v_r.ref); end if;
    if v_r.paying_by_user_id is distinct from v_uid then return jsonb_build_object('ok', false, 'reason', 'not_yours', 'status', v_r.status, 'ref', v_r.ref, 'paying_by_name', v_r.paying_by_name); end if;
    update public.staff_pay_requests set sent_said_at = coalesce(sent_said_at, now()) where id = v_r.id;
    return jsonb_build_object('ok', true, 'status', 'paying', 'ref', v_r.ref, 'total', v_r.total_amount, 'paying_by_user_id', v_uid, 'sent', true);
  end if;
  if p_step = 'takeover' then -- "I am paying it instead": only while nobody has said the money was sent
    if v_r.status <> 'paying' then return jsonb_build_object('ok', false, 'reason', 'not_paying', 'status', v_r.status, 'ref', v_r.ref); end if;
    if v_r.paying_by_user_id = v_uid then return jsonb_build_object('ok', true, 'status', 'paying', 'ref', v_r.ref, 'total', v_r.total_amount, 'paying_by_user_id', v_uid); end if;
    if v_r.sent_said_at is not null or v_r.proof_file_unique_id is not null then
      return jsonb_build_object('ok', false, 'reason', 'money_may_be_sent', 'status', v_r.status, 'ref', v_r.ref);
    end if;
    perform set_config('cascade.audit_reason', 'staff pay ' || v_r.ref || ' taken over from ' || coalesce(v_r.paying_by_name, 'Telegram') || ' by ' || v_name, true);
    update public.staff_pay_requests set paying_by_user_id = v_uid, paying_by_tg = null, paying_by_name = v_name, paying_at = now() where id = v_r.id;
    return jsonb_build_object('ok', true, 'status', 'paying', 'ref', v_r.ref, 'total', v_r.total_amount, 'paying_by_user_id', v_uid, 'took_over_from', v_r.paying_by_name);
  end if;
  if p_step = 'not_sent' and v_r.status = 'paying' and v_r.paying_by_user_id is distinct from v_uid then -- unpay is for my own paying state only
    return jsonb_build_object('ok', false, 'reason', 'not_yours', 'status', v_r.status, 'ref', v_r.ref, 'paying_by_name', v_r.paying_by_name);
  end if;

  v_res := public.telegram_staff_pay_step_v1(p_request_id, p_step, null, v_name, null);
  if coalesce((v_res ->> 'ok')::boolean, false) then
    if p_step = 'pay' then update public.staff_pay_requests set paying_by_user_id = v_uid where id = v_r.id; v_res := v_res || jsonb_build_object('paying_by_user_id', v_uid);
    else update public.staff_pay_requests set paying_by_user_id = null where id = v_r.id; end if;
  end if;
  return v_res;
end $$;
revoke all on function public.staff_pay_admin_step_v1(uuid, text) from public, anon, service_role;
grant execute on function public.staff_pay_admin_step_v1(uuid, text) to authenticated;

drop function if exists public.staff_calendar_history_v1(date, date, uuid);
drop function if exists public.admin_stays_gate_v1(uuid);

commit;
