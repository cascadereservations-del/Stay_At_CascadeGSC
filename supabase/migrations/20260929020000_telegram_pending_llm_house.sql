-- Session 60, D-282: release telegram_pending_llm_house_20260929. Cassy's teach card inserts a telegram_pending row of kind
-- 'llm_house' (tap: llm_house_confirm in telegram-expense). The pending-card kinds are a CHECK, so a new kind is a migration
-- (B53). Found by the first live teach on 2026-09-29 07:47Z: telegram_pending_kind_check refused the row. The fourteen
-- existing values are copied from production (pg_constraint, 2026-09-29), not from an older migration.
begin;

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice',
  'inventory_count', 'awaiting_reply', 'llm_house'
]));

commit;
