-- Rollback for s110_kpi_supply_laundry_20261112: drops the new functions and tables, puts staff_access_allowed back to its 20260913130000 body, takes laundry out of the
-- manage_staff_access role list, restores the record_inventory_usage gate (submit_cleaning only) and returns the role check to the six roles.
-- Not undone: stock, purchases, items, expenses and follow-up tasks written by staff receipts. Refuses (raises) while an account with the role laundry exists:
-- move those accounts to another role first, or the role check cannot be put back.
begin;

do $$
begin
  if exists (select 1 from public.staff_access_profiles where role = 'laundry') then
    raise exception 's110 rollback: a laundry account still exists; change its role first' using errcode = '55000';
  end if;
end $$;

drop function if exists public.kpi_tab_v1(uuid, date);
drop function if exists public.inventory_receipt_manual_v1(jsonb, date, text, text);
drop function if exists public.inventory_receipt_undo_v1(uuid);
drop function if exists public.inventory_receipt_cancel_v1(uuid);
drop function if exists public.inventory_receipt_confirm_v1(uuid, jsonb, date, text);
drop function if exists public.s_inventory_receipt_confirm_core_v1(uuid, jsonb, date, text, boolean);
drop function if exists public.inventory_receipt_draft_v1(uuid);
drop function if exists public.s_inventory_receipt_apply_v1(uuid, numeric, numeric, text, uuid, date, text, uuid);
drop function if exists public.utility_rate_list_v1(uuid, integer);
drop function if exists public.utility_rate_record_auto_v1(numeric, date, text);
drop function if exists public.utility_rate_set_v1(numeric, date, text);
revoke select (item_id, title) on public.inventory_item_options from service_role;
drop table if exists public.inventory_receipt_drafts;
drop table if exists public.utility_rates;

create or replace function public.staff_access_allowed(
  p_role text,p_action text,p_disabled_at timestamptz,p_aal text
) returns boolean language sql immutable set search_path='' as $$
  select case
    when p_disabled_at is not null then false
    when p_role in ('owner','admin') then p_action in (
      'manage_staff','approve_payment','read_finance','read_operations','manage_operations',
      'inspect_cleaning','submit_cleaning','manage_inventory','manage_maintenance',
      'manage_privacy','manage_booking','approve_refund','publish_rate_policy','manage_guest_inbox'
    )
    when p_role='finance' then p_action in ('approve_payment','read_finance','read_operations','approve_refund')
    when p_role='inspector' then p_action in ('read_operations','inspect_cleaning','submit_cleaning')
    when p_role='cleaner' then p_action in ('read_operations','submit_cleaning')
    when p_role='maintenance' then p_action in ('read_operations','manage_maintenance')
    else false end;
$$;
revoke all on function public.staff_access_allowed(text,text,timestamptz,text) from public, anon, authenticated, service_role;
grant execute on function public.staff_access_allowed(text,text,timestamptz,text) to service_role;

do $$
declare v_def text; v_old text; v_to text;
begin
  v_def := pg_get_functiondef(to_regprocedure('public.manage_staff_access(uuid,text,text,uuid[],text)'));
  v_old := $a$'cleaner','maintenance','laundry')$a$;
  v_to  := $a$'cleaner','maintenance')$a$;
  if position(v_old in v_def) > 0 then execute replace(v_def, v_old, v_to); end if;
  v_def := pg_get_functiondef(to_regprocedure('public.record_inventory_usage(uuid,date,text,text,jsonb)'));
  v_old := $a$if not (public.current_staff_authorized('submit_cleaning', p_property_id) or public.current_staff_authorized('report_supply', p_property_id)) then$a$;
  v_to  := $a$if not public.current_staff_authorized('submit_cleaning', p_property_id) then$a$;
  if position(v_old in v_def) > 0 then execute replace(v_def, v_old, v_to); end if;
end $$;

alter table public.staff_access_profiles drop constraint if exists staff_access_profiles_role_check;
alter table public.staff_access_profiles add constraint staff_access_profiles_role_check
  check (role in ('owner','admin','finance','inspector','cleaner','maintenance'));

commit;
