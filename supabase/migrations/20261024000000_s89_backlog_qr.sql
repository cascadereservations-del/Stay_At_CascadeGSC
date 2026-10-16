-- 20261024000000_s89_backlog_qr.sql
-- Session 89, lane backlog-sql: release s89_backlog_20261024, part 1 (payout QR). Three changes, one function replaced:
-- (1) qrph_crc16_v1(text): CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF), the same algorithm as staff-app/pay/C_qrph.js C_crc16. Pure, internal.
-- (2) save_staff_details_v1: a payout_qrph that does not end with 6304 + four capital hex characters, or whose CRC does not match, is refused with 22023
--     and a readable message, not a raw 23514 from the table CHECK (staff_details.payout_qrph, 20261005110000). Printable ASCII only, like the client.
-- (3) save_staff_details_v1: when the QR or the bank name really changes, one row goes to staff_payout_change_notices with the sentences for the Finance
--     Telegram group (NOT OPS, D-306) and for the staff member's own phone. Rows only; the sender is an Edge Function (see the table comment). No QR
--     payload and no account number is ever stored in or sent from that row.
-- Guard: the live save_staff_details_v1 must be the s85 body this was cut from (md5 of prosrc, CR stripped, 1f528a60b24632ecf6cead5b47b38903, read live
-- 2026-10-16), else 55000 and nothing changes. Single shot; to undo apply supabase/rollbacks/20261024_s89_backlog.sql.

begin;

do $$
declare v_got text;
begin
  select md5(replace(p.prosrc, chr(13), '')) into v_got from pg_proc p where p.oid = to_regprocedure('public.save_staff_details_v1(uuid,jsonb,integer,text)');
  if v_got is distinct from '1f528a60b24632ecf6cead5b47b38903' then
    raise exception 's89 backlog qr: save_staff_details_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', v_got using errcode = '55000';
  end if;
end $$;

create or replace function public.qrph_crc16_v1(p_text text)
returns text language plpgsql immutable set search_path = '' as $$
declare v_c integer := 65535; v_b bytea := convert_to(p_text, 'UTF8'); i integer; j integer;
begin
  for i in 0 .. length(v_b) - 1 loop
    v_c := v_c # (get_byte(v_b, i) << 8);
    for j in 1 .. 8 loop
      if (v_c & 32768) <> 0 then v_c := ((v_c << 1) # 4129) & 65535; else v_c := (v_c << 1) & 65535; end if;
    end loop;
  end loop;
  return upper(lpad(to_hex(v_c), 4, '0'));
end $$;
revoke all on function public.qrph_crc16_v1(text) from public, anon, authenticated, service_role;
comment on function public.qrph_crc16_v1(text) is 'S89: CRC-16/CCITT-FALSE of the bytes of the text, four capital hex characters. Same as C_crc16 in staff-app/pay/C_qrph.js. Internal: called by save_staff_details_v1.';

create table if not exists public.staff_payout_change_notices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.staff_access_profiles(user_id) on delete cascade,
  changed_by uuid,
  changed_what text not null check (changed_what in ('qr', 'bank_label', 'both')),
  finance_text text not null check (char_length(finance_text) <= 300),
  staff_text text not null check (char_length(staff_text) <= 300),
  created_at timestamptz not null default now(),
  finance_sent_at timestamptz,
  staff_sent_at timestamptz
);
create index if not exists staff_payout_change_notices_pending_idx on public.staff_payout_change_notices(created_at) where finance_sent_at is null or staff_sent_at is null;
alter table public.staff_payout_change_notices enable row level security;
revoke all on public.staff_payout_change_notices from public, anon, authenticated;
grant select on public.staff_payout_change_notices to service_role;
grant update (finance_sent_at, staff_sent_at) on public.staff_payout_change_notices to service_role;
comment on table public.staff_payout_change_notices is 'S89: one row each time save_staff_details_v1 really changes a person''s payout QR or bank name. finance_text goes to the Finance Telegram group (never OPS); staff_text goes to that person''s phones that hold the paid topic (staff_push_subscriptions). The sender (service role) reads the unsent rows and stamps finance_sent_at / staff_sent_at. The texts hold first names only: no QR payload, no account number.';

create or replace function public.save_staff_details_v1(p_user_id uuid, p_patch jsonb, p_expected_version integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_before jsonb; v_row public.staff_details%rowtype; v_label text; v_qr text; v_old_qr text; v_old_label text;
  v_qr_changed boolean; v_label_changed boolean; v_who text; v_by text; v_what text;
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
    -- s89: the same two checks the table CHECK and the admin page make, answered with a readable error instead of a raw 23514.
    v_qr := btrim(p_patch->>'payout_qrph');
    if v_qr !~ '^[ -~]+  end if;
  insert into public.staff_details(user_id) values (p_user_id) on conflict (user_id) do nothing;
  select * into v_row from public.staff_details where user_id = p_user_id for update;
  if p_expected_version is not null and v_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'stale version: staff details changed since they were loaded';
  end if;
  v_old_qr := v_row.payout_qrph; v_old_label := v_row.payout_bank_label;
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
  -- s89: a changed payout QR or bank label is queued for the Finance group and for her own phone. The text names people only: never the payload, never an account number.
  v_qr_changed := p_patch ? 'payout_qrph' and v_row.payout_qrph is distinct from v_old_qr;
  v_label_changed := p_patch ? 'payout_bank_label' and v_row.payout_bank_label is distinct from v_old_label;
  if v_qr_changed or v_label_changed then
    select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''), initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')))
      into v_who from auth.users u where u.id = p_user_id;
    select coalesce(nullif(btrim(u.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''), initcap(replace(split_part(coalesce(u.email, ''), '@', 1), '.', ' ')))
      into v_by from auth.users u where u.id = auth.uid();
    v_who := coalesce(nullif(left(split_part(btrim(coalesce(v_who, '')), ' ', 1), 30), ''), 'A staff member');
    v_by := coalesce(nullif(left(split_part(btrim(coalesce(v_by, '')), ' ', 1), 30), ''), 'an admin');
    v_what := case when v_qr_changed and v_label_changed then 'QR and bank name' when v_qr_changed then 'QR' else 'bank name' end;
    insert into public.staff_payout_change_notices(user_id, changed_by, changed_what, finance_text, staff_text)
    values (p_user_id, auth.uid(),
            case when v_qr_changed and v_label_changed then 'both' when v_qr_changed then 'qr' else 'bank_label' end,
            case when v_qr_changed and v_row.payout_qrph is null
                 then v_who || '''s payout QR was removed by ' || v_by || '. Add a new one before the next payment.'
                 else v_who || '''s payout ' || v_what || ' was changed by ' || v_by || '. Check it before the next payment.' end,
            'Your payout ' || v_what || ' was changed by ' || v_by || '. If this is not right, tell ' || v_by || '.');
  end if;
  return jsonb_build_object('ok', true, 'userId', p_user_id, 'version', v_row.version, 'updatedAt', v_row.updated_at);
end;
$$; or v_qr !~ '6304[0-9A-F]{4}  end if;
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
$$; then
      raise exception using errcode = '22023', message = 'QR code text must end with 6304 and four capital hex characters (0 to 9, A to F)';
    end if;
    if public.qrph_crc16_v1(left(v_qr, -4)) <> right(v_qr, 4) then
      raise exception using errcode = '22023', message = 'QR code check characters do not match: copy the QR text again';
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

commit;
