-- Compensating rollback for release admin_modernisation_backend_20260913.
-- Refuses when accounting or movement data exists: once new writers are
-- authoritative, rollback must not reactivate incompatible legacy behaviour.
begin;
do $$ begin
  if exists (select 1 from public.acct_journals) then raise exception 'journals exist; do not roll back the accounting foundation'; end if;
  if exists (select 1 from public.inventory_items where movement_controlled_at is not null) then raise exception 'movement-controlled items exist; do not restore the legacy usage writer'; end if;
end $$;
-- Restore record_inventory_usage v1 (20260908000100).
create or replace function public.record_inventory_usage(p_property_id uuid, p_session_date date, p_logged_by text, p_notes text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row jsonb; v_item uuid; v_qty numeric; v_count integer := 0;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not public.current_staff_authorized('submit_cleaning', p_property_id) then raise exception using errcode = '42501', message = 'staff access denied'; end if;
  if p_session_date is null then raise exception using errcode = '22023', message = 'session_date required'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception using errcode = '22023', message = 'rows required'; end if;
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_item := (v_row ->> 'item_id')::uuid; v_qty := (v_row ->> 'used_qty')::numeric;
    if v_item is null or v_qty is null or v_qty <= 0 then raise exception using errcode = '22023', message = 'each row needs item_id and a positive used_qty'; end if;
    if not exists (select 1 from public.inventory_items i where i.id = v_item and i.property_id = p_property_id) then raise exception using errcode = '22023', message = 'unknown item for property'; end if;
    insert into public.inventory_usage(item_id, used_qty, session_date, logged_by, notes, property_id, submitted_by_user_id)
    values (v_item, v_qty, p_session_date, nullif(btrim(coalesce(p_logged_by, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''), p_property_id, auth.uid());
    update public.inventory_items set qty_on_hand = greatest(0, coalesce(qty_on_hand, 0) - v_qty) where id = v_item;
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('ok', true, 'rows', v_count);
end; $$;
drop function if exists public.get_inventory_catalogue_v1(uuid), public.save_shopping_item_v1(uuid,jsonb,text), public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text), public.inventory_apply_event_v1(uuid,text,numeric,text,text,text), public.reconcile_inventory_baseline_v1(uuid,numeric,text,text);
drop table if exists public.inventory_shopping_list;
alter table public.inventory_items drop column if exists movement_controlled_at, drop column if exists baseline_reviewed_by, drop column if exists baseline_note;
drop function if exists public.post_consumable_usage_v1(uuid,date,date,text), public.stock_wa_cost_v1(uuid,date), public.review_stock_valuation_v1(uuid,date,numeric,numeric,text), public.run_depreciation_v1(uuid,date,text), public.save_fixed_asset_v1(uuid,jsonb), public.reopen_accounting_period_v1(uuid,date,text), public.close_accounting_period_v1(uuid,date,jsonb,text), public.get_financial_statement_v1(uuid,text,date,date,uuid,text), public.acct_balances_v1(uuid,date,date), public.approve_opening_balances_v1(uuid,text,text), public.save_opening_balance_batch_v1(uuid,jsonb), public.prepare_simple_entry_v1(uuid,text,jsonb), public.acct_line_v1(text,numeric,numeric,text), public.reverse_journal_v1(uuid,text,date,text), public.post_journal_v1(uuid,date,text,jsonb,text,text,text,text,text,text), public.acct_seed_chart_v1(uuid), public.acct_period_status_v1(uuid,date), public.acct_require_post(uuid);
drop table if exists public.acct_depreciation_runs, public.acct_fixed_assets, public.acct_stock_valuations, public.acct_close_snapshots, public.acct_opening_balance_batches, public.acct_journal_lines, public.acct_journals, public.acct_periods, public.acct_settings, public.acct_accounts;
drop function if exists public.acct_journal_immutable(), public.acct_lines_immutable();
drop function if exists public.merge_guests_v1(uuid,uuid,text,text), public.preview_guest_merge_v1(uuid,uuid), public.review_property_readiness_v1(uuid,date,text,text,uuid,text), public.save_work_order_v1(uuid,jsonb,text), public.save_follow_up_v1(uuid,jsonb,text), public.save_guest_profile_v1(uuid,jsonb,integer,text), public.get_guest_timeline_v1(uuid), public.get_admin_overview_v1(uuid), public.get_report_drilldown_v1(uuid,text), public.get_hospitality_metrics_v1(uuid,date,date), public.metric_v1(text,text,text,date,date,text,text,timestamptz,text,integer,integer,text[],text), public.allocate_nightly_v1(numeric,integer), public.admin_stays_v1(uuid), public.manila_today(), public.admin_require(text,uuid);
drop table if exists public.guest_merge_history, public.guest_profile_history, public.guest_profile_details, public.readiness_reviews, public.work_orders, public.follow_up_tasks;
alter table public.ops_notices drop column if exists audience, drop column if exists expires_at;
commit;
