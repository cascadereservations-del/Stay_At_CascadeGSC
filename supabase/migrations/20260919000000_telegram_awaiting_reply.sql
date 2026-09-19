-- Telegram reply surface (session 37, SPEC-16, D-196). When the finance bot asks someone a question it
-- now records who it asked, in which chat and for what, as a telegram_pending row of kind 'awaiting_reply',
-- instead of writing a marker into the message text that Telegram strips on the way back (D-195).
-- The pending-card kinds are a CHECK, so a new kind is a migration (B53). The thirteen existing values are
-- copied from production (pg_constraint, 2026-09-19), not from an older migration.
begin;

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice',
  'inventory_count', 'awaiting_reply'
]));

commit;
