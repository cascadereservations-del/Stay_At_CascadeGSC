-- Compensating rollback for release staff_pay_requests_20261005 (session 70, SPEC-37). Safe until the first request is paying or paid:
-- after that the ledger rows and the Finance cards point at the table, so roll forward instead. The payout QR column is dropped with
-- its value (Honey's QR can be decoded again from the Drive file). Redeploy the previous notify-cleaner-payment and telegram-expense
-- first: the new telegram-expense selects pay_request_id and the poster calls the create RPC.
begin;

do $$
begin
  if exists (select 1 from public.staff_pay_requests where status in ('paying', 'paid')) then
    raise exception 'a staff pay request is paying or paid; roll forward instead of back';
  end if;
end $$;

drop trigger if exists cleaning_sessions_pay_request_guard on public.cleaning_sessions;
drop function if exists public.cleaning_sessions_pay_request_guard();

drop function if exists public.telegram_staff_pay_step_v1(uuid, text, bigint, text, jsonb);
drop function if exists public.staff_pay_settle_v1(uuid, bigint, text, text, jsonb);
drop function if exists public.staff_pay_request_create_v1(jsonb, uuid[], jsonb, text);
drop function if exists public.staff_pay_candidates_v1();
drop function if exists public.staff_pay_rate_v1(date);

alter table public.cleaning_sessions drop column if exists pay_request_id;
alter table public.cleaning_expense_claims drop column if exists pay_request_id;
alter table public.cleaning_expense_claims drop column if exists receipt_path;
drop table if exists public.staff_pay_requests;

-- the previous save_staff_details_v1 body (20260914230000_staff_details.sql, md5(prosrc) aff77cec89cc6b9130a6e41c0014819a)
create or replace function public.save_staff_details_v1(p_user_id uuid, p_patch jsonb, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_row public.staff_details%rowtype;
begin
  if not public.current_staff_authorized('manage_staff') then
    raise exception using errcode = '42501', message = 'manage_staff denied';
  end if;
  if not exists (select 1 from public.staff_access_profiles where user_id = p_user_id) then
    raise exception using errcode = 'P0002', message = 'staff member not found';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception using errcode = '22023', message = 'patch must be an object'; end if;
  insert into public.staff_details(user_id) values (p_user_id) on conflict (user_id) do nothing;
  select * into v_row from public.staff_details where user_id = p_user_id for update;
  if p_expected_version is not null and v_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'stale version: staff details changed since they were loaded';
  end if;
  v_before := to_jsonb(v_row);
  update public.staff_details set
    contact_number = case when p_patch ? 'contact_number' then nullif(btrim(p_patch->>'contact_number'), '') else contact_number end,
    alternate_contact = case when p_patch ? 'alternate_contact' then nullif(btrim(p_patch->>'alternate_contact'), '') else alternate_contact end,
    address = case when p_patch ? 'address' then nullif(btrim(p_patch->>'address'), '') else address end,
    id_type = case when p_patch ? 'id_type' then nullif(p_patch->>'id_type', '') else id_type end,
    id_number = case when p_patch ? 'id_number' then nullif(btrim(p_patch->>'id_number'), '') else id_number end,
    id_drive_url = case when p_patch ? 'id_drive_url' then nullif(btrim(p_patch->>'id_drive_url'), '') else id_drive_url end,
    emergency_contact_name = case when p_patch ? 'emergency_contact_name' then nullif(btrim(p_patch->>'emergency_contact_name'), '') else emergency_contact_name end,
    emergency_contact_number = case when p_patch ? 'emergency_contact_number' then nullif(btrim(p_patch->>'emergency_contact_number'), '') else emergency_contact_number end,
    start_date = case when p_patch ? 'start_date' then nullif(p_patch->>'start_date', '')::date else start_date end,
    fee_turnover = case when p_patch ? 'fee_turnover' then nullif(p_patch->>'fee_turnover', '')::numeric else fee_turnover end,
    fee_transport = case when p_patch ? 'fee_transport' then nullif(p_patch->>'fee_transport', '')::numeric else fee_transport end,
    fee_deep_clean = case when p_patch ? 'fee_deep_clean' then nullif(p_patch->>'fee_deep_clean', '')::numeric else fee_deep_clean end,
    updated_by = auth.uid(), updated_at = now(), version = version + 1
  where user_id = p_user_id returning * into v_row;
  insert into public.staff_details_history(user_id, changed_by, before_state, after_state, reason) values (p_user_id, auth.uid(), v_before, to_jsonb(v_row), p_reason);
  return jsonb_build_object('ok', true, 'userId', p_user_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;
revoke all on function public.save_staff_details_v1(uuid, jsonb, integer, text) from public, anon, service_role;
grant execute on function public.save_staff_details_v1(uuid, jsonb, integer, text) to authenticated;

alter table public.staff_details drop column if exists payout_qrph;

delete from public.cleaner_rate_schedule
 where property_id = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd' and effective_from = date '2026-09-30' and note like 'D-296.4 / D-298.1%';
alter table public.cleaner_rate_schedule drop column if exists transport_rate;

commit;
