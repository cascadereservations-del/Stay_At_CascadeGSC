-- Session 71, Finance > Transactions: select, hide, archive and restore ledger rows from the admin dashboard.
-- Lloyd: "hide voided transactions, add a button to select, add, hide, edit, delete / archive transactions".
-- Add and edit already exist (admin_save_transaction_v1); void already exists (admin_soft_delete_v1). This release adds the rest:
--   hide     hidden_at / hidden_by. List-only: status is untouched, so every money total keeps counting the row. Unhide clears it.
--   archive  archived_at / archived_by / archived_prev_status, and status becomes 'void'. Every reader of the ledger already leaves
--            void rows out of its totals (overview, monthly totals, book, health checks, statements), so an archived row drops out
--            of the totals exactly like a voided one without touching those readers. archived_at is what tells an archived row
--            from one the Telegram bot or an admin voided. Restore puts status back to archived_prev_status. Never a hard delete.
--   One RPC, admin_transactions_bulk_v1(property, ids, action, reason), is atomic over the selection, authorised by the same
--   admin_require('approve_payment') the other transaction writes use, and audited per row through admin_audit_row_v1 (archive is
--   labelled soft_delete; hide, unhide and restore are plain updates), so every change is undoable from Settings > Audit history.
-- A direct_booking row linked to a booking is refused for archive: voiding it fires fn_direct_booking_cascade, which cancels the
-- guest booking. Cancel the booking instead.
-- Expand only: five nullable columns, one check constraint (archived_at implies status void), one function. No data change.
-- Rollback: supabase/rollbacks/20261005_transactions_hide_archive.sql

begin;

alter table public.transactions
  add column if not exists hidden_at timestamptz,
  add column if not exists hidden_by uuid,
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid,
  add column if not exists archived_prev_status text;

alter table public.transactions drop constraint if exists transactions_archived_is_void_check;
alter table public.transactions add constraint transactions_archived_is_void_check check (archived_at is null or status = 'void');

comment on column public.transactions.hidden_at is 'Set when the row is hidden from the admin Transactions list. Display only: the row still counts in every total.';
comment on column public.transactions.archived_at is 'Set when the row is archived from the admin dashboard. Archived rows are status void (out of every total); archived_prev_status is what Restore puts back.';

create or replace function public.admin_transactions_bulk_v1(p_property_id uuid, p_ids uuid[], p_action text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[]; v_reason text := btrim(coalesce(p_reason, '')); r public.transactions%rowtype;
  v_changed int := 0; v_skipped int := 0; v_amount numeric := 0; v_audit uuid[] := '{}'; v_aid uuid;
begin
  perform public.admin_require('approve_payment', p_property_id);
  if p_action is null or p_action not in ('hide', 'unhide', 'archive', 'restore') then
    raise exception using errcode = '22023', message = 'action must be hide, unhide, archive or restore';
  end if;
  select array_agg(distinct x) into v_ids from unnest(p_ids) as x where x is not null;
  if v_ids is null then raise exception using errcode = '22023', message = 'select at least one transaction'; end if;
  if cardinality(v_ids) > 200 then raise exception using errcode = '22023', message = 'at most 200 transactions at a time'; end if;
  if p_action in ('archive', 'restore') and char_length(v_reason) < 3 then
    raise exception using errcode = '22023', message = 'a reason is required';
  end if;
  if (select count(*) from public.transactions where property_id = p_property_id and id = any(v_ids)) <> cardinality(v_ids) then
    raise exception using errcode = 'P0002', message = 'one or more transactions were not found for this property';
  end if;
  perform public.admin_audit_context_v1(coalesce(nullif(v_reason, ''), p_action || ' in admin'), case when p_action = 'archive' then 'soft_delete' end, null);

  for r in select * from public.transactions where property_id = p_property_id and id = any(v_ids) order by id for update loop
    if (p_action = 'hide' and r.hidden_at is not null) or (p_action = 'unhide' and r.hidden_at is null)
       or (p_action = 'archive' and r.archived_at is not null) or (p_action = 'restore' and r.archived_at is null) then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    if p_action = 'hide' then
      update public.transactions set hidden_at = now(), hidden_by = auth.uid(), updated_at = now() where id = r.id;
    elsif p_action = 'unhide' then
      update public.transactions set hidden_at = null, hidden_by = null, updated_at = now() where id = r.id;
    elsif p_action = 'archive' then
      if r.source = 'direct_booking' and r.booking_id is not null and r.status <> 'void' then
        raise exception using errcode = '22023', message = 'a direct booking payment cannot be archived while the booking is live; cancel the booking instead';
      end if;
      update public.transactions set archived_at = now(), archived_by = auth.uid(), archived_prev_status = r.status, status = 'void', updated_at = now() where id = r.id;
    else
      update public.transactions set status = coalesce(archived_prev_status, 'void'), archived_at = null, archived_by = null, archived_prev_status = null, updated_at = now() where id = r.id;
    end if;
    v_changed := v_changed + 1;
    v_amount := v_amount + r.gross_amount;
    select a.id into v_aid from public.admin_audit_log a where a.entity_table = 'transactions' and a.entity_id = r.id order by a.created_at desc, a.id limit 1;
    if v_aid is not null then v_audit := v_audit || v_aid; end if;
  end loop;

  return jsonb_build_object('ok', true, 'action', p_action, 'changed', v_changed, 'skipped', v_skipped, 'amount', v_amount, 'auditIds', to_jsonb(v_audit));
end;
$$;
revoke all on function public.admin_transactions_bulk_v1(uuid, uuid[], text, text) from public, anon, service_role;
grant execute on function public.admin_transactions_bulk_v1(uuid, uuid[], text, text) to authenticated;
comment on function public.admin_transactions_bulk_v1(uuid, uuid[], text, text) is 'Hide, unhide, archive or restore ledger rows in one transaction. approve_payment only; per-row audit; never a hard delete.';

commit;
