-- Compensating rollback for 20260929020000_telegram_pending_llm_house.sql: narrows the pending-card kinds back to the
-- fourteen before it. Cassy's teach tool then fails closed (no card, nothing saved). Live 'llm_house' rows are deleted
-- first, or the narrowed CHECK cannot be added; they are unconfirmed teach cards, nothing that was saved.
begin;

delete from public.telegram_pending where kind = 'llm_house';

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice',
  'inventory_count', 'awaiting_reply'
]));

commit;
