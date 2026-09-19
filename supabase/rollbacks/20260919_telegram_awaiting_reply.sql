-- Compensating rollback for 20260919000000_telegram_awaiting_reply.sql: narrows the pending-card kinds back
-- to the thirteen that existed before. The SPEC-16 bot then cannot ask a question: every prompt fails closed
-- before anything is written, and a reply to a bot card is still refused (that guard is code, not schema).
--
-- Any live 'awaiting_reply' row is deleted first, or the narrowed CHECK cannot be added. Those rows are
-- ephemeral by design (ten minutes); deleting one loses an unanswered question, nothing that was saved.
begin;

delete from public.telegram_pending where kind = 'awaiting_reply';

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice',
  'inventory_count'
]));

commit;
