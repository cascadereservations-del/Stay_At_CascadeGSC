-- Session 68 (D-291 fix): release telegram_pending_guest_kinds_20261003. Cassy /guest stores its pick and confirm cards as
-- telegram_pending rows of kind 'guest_pick' and 'guest_save' (telegram-expense guest-flow.ts). The pending-card kinds are a
-- CHECK (B53), and release telegram_guest_intake_20261002 did not widen it, so the first live /guest (2026-10-02 20:42Z,
-- update 287881787) was refused at the insert and answered "I could not open that card". The fifteen existing values are
-- copied from production (pg_constraint, 2026-10-02 22:00Z), not from an older migration.
begin;

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice',
  'inventory_count', 'awaiting_reply', 'llm_house', 'guest_pick', 'guest_save'
]));

commit;
