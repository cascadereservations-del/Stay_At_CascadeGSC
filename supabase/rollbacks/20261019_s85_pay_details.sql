-- Rollback for release s85_pay_details_20261019. Compensating: puts save_staff_details_v1 back to the live body this release was cut from
-- (md5 of prosrc, CR stripped: 9605dae1cb79d08cb4e24eb7154623d2, read from production 2026-10-15) and drops staff_payout_details_v1.
-- Saved bank labels and QR payloads stay in staff_details. Apply with run-sql-on-host.sh.

begin;

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
  v_before := (to_jsonb(v_row) - 'payout_qrph') || jsonb_build_object('payout_qrph', case when v_row.payout_qrph is null then null else '[set ' || right(v_row.payout_qrph, 4) || ']' end);
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
    payout_qrph = case when p_patch ? 'payout_qrph' then nullif(btrim(p_patch->>'payout_qrph'), '') else payout_qrph end,
    updated_by = auth.uid(), updated_at = now(), version = version + 1
  where user_id = p_user_id returning * into v_row;
  insert into public.staff_details_history(user_id, changed_by, before_state, after_state, reason)
  values (p_user_id, auth.uid(), v_before,
          (to_jsonb(v_row) - 'payout_qrph') || jsonb_build_object('payout_qrph', case when v_row.payout_qrph is null then null else '[set ' || right(v_row.payout_qrph, 4) || ']' end),
          p_reason);
  return jsonb_build_object('ok', true, 'userId', p_user_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$;
revoke all on function public.save_staff_details_v1(uuid, jsonb, integer, text) from public, anon, service_role;
grant execute on function public.save_staff_details_v1(uuid, jsonb, integer, text) to authenticated;

drop function if exists public.staff_payout_details_v1(uuid);

commit;
