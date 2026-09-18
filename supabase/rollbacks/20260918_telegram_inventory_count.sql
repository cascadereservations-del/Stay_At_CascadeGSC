-- Compensating rollback for 20260918000000_telegram_inventory_count.sql: drops the Telegram count RPC and
-- narrows the pending-card kinds back to the twelve that existed before. Counts already applied stay --
-- they are real stock figures, already audited as telegram_count. /count in the bot then fails closed.
--
-- Any live 'inventory_count' card is deleted first, or the narrowed CHECK cannot be added. Those rows are
-- ephemeral by design (telegram_pending.expires_at); deleting one loses an unapplied draft count, nothing
-- that was saved.
begin;

drop function if exists public.telegram_apply_inventory_count_v1(bigint, jsonb, text);

delete from public.telegram_pending where kind = 'inventory_count';

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice'
]));

commit;
