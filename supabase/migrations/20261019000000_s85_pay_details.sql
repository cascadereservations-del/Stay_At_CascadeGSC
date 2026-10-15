-- 20261019000000_s85_pay_details.sql
-- Session 85, lane pay-details: release s85_pay_details_20261019. The admin Staff page edits a person's payout bank or wallet label and QR Ph payload.
-- (1) save_staff_details_v1: live body (md5 of prosrc, CR stripped, 9605dae1cb79d08cb4e24eb7154623d2, read 2026-10-15) plus payout_bank_label in the patch
--     (trimmed, 2 to 40 chars, empty or null clears) and validation of payout_qrph (null clears; otherwise a string starting 000201, at most 512 chars,
--     else 22023). The gate is unchanged: manage_staff, which only owner and admin hold (finance and cleaner are refused 42501). Version, expected_version
--     and history are unchanged (history already masks the QR; the label is not secret and is stored as is). The table CHECKs stay the last line of defence.
-- (2) staff_payout_details_v1(p_user_id): owner/admin-only read of {payout_bank_label, has_qr, qr_payload} for one person. Definer, empty search_path.
-- Guard: the live save_staff_details_v1 must be the body cut from, else 55000 and nothing changes (single shot; to undo apply the rollback).
-- Rollback: supabase/rollbacks/20261019_s85_pay_details.sql

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.save_staff_details_v1(uuid,jsonb,integer,text)');
  if v_got is distinct from '9605dae1cb79d08cb4e24eb7154623d2' then
    raise exception 's85 pay details: save_staff_details_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

create or replace function public.save_staff_details_v1(p_user_id uuid, p_patch jsonb, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_row public.staff_details%rowtype; v_label text;
begin
  if not public.current_staff_authorized('manage_staff') then
    raise exception using errcode = '42501', message = 'manage_staff denied';
  end if;
  if not exists (select 1 from public.staff_access_profiles where user_id = p_user_id) then
    raise exception using errcode = 'P0002', message = 'staff member not found';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then raise exception using errcode = '22023', message = 'patch must be an object'; end if;
  -- s85: payout fields. Same gate as every other field (manage_staff = owner and admin only; finance and cleaner are refused above).
  if p_patch ? 'payout_bank_label' then
    if jsonb_typeof(p_patch->'payout_bank_label') not in ('string', 'null') then raise exception using errcode = '22023', message = 'bank label must be text'; end if;
    v_label := nullif(btrim(p_patch->>'payout_bank_label'), '');
    if v_label is not null and char_length(v_label) not between 2 and 40 then raise exception using errcode = '22023', message = 'bank label must be 2 to 40 characters'; end if;
  end if;
  if p_patch ? 'payout_qrph' and jsonb_typeof(p_patch->'payout_qrph') <> 'null' then
    if jsonb_typeof(p_patch->'payout_qrph') <> 'string' or btrim(p_patch->>'payout_qrph') not like '000201%' or char_length(btrim(p_patch->>'payout_qrph')) > 512 then
      raise exception using errcode = '22023', message = 'QR code text must be a QR Ph payload (starts 000201, at most 512 characters)';
    end if;
  end if;
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
    payout_bank_label = case when p_patch ? 'payout_bank_label' then v_label else payout_bank_label end,
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

create or replace function public.staff_payout_details_v1(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_row public.staff_details%rowtype;
begin
  if not public.current_staff_authorized('manage_staff') then
    raise exception using errcode = '42501', message = 'manage_staff denied';
  end if;
  select * into v_row from public.staff_details where user_id = p_user_id;
  return jsonb_build_object('payout_bank_label', v_row.payout_bank_label, 'has_qr', v_row.payout_qrph is not null, 'qr_payload', v_row.payout_qrph);
end;
$$;
revoke all on function public.staff_payout_details_v1(uuid) from public, anon, service_role;
grant execute on function public.staff_payout_details_v1(uuid) to authenticated;

commit;
