-- Compensating rollback for 20261003010000_telegram_pending_guest_kinds.sql: narrows the pending-card kinds back to the
-- fifteen before it. Cassy /guest then fails closed again (no card, nothing saved). Live guest_pick / guest_save rows are
-- deleted first, or the narrowed CHECK cannot be added; they are unconfirmed cards, nothing that was saved.
begin;

delete from public.telegram_pending where kind in ('guest_pick', 'guest_save');

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice',
  'inventory_count', 'awaiting_reply', 'llm_house'
]));

commit;
