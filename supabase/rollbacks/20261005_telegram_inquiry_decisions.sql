-- Compensating rollback for 20261005100000_telegram_inquiry_decisions.sql. Redeploy the previous telegram-expense, telegram-cassy and
-- submit-booking FIRST (they stop calling the RPCs and writing inquiry_reply / refund_confirm cards), then apply this.
-- Drops the three functions and narrows telegram_pending_kind_check back to the 17 values before the release. Unconfirmed
-- inquiry_reply, refund_confirm and lock_code cards are deleted first, or the narrowed CHECK cannot be added; they are cards nobody
-- tapped, nothing that was sent or saved. The lifecycle CHECK stays widened: guest_replied is additive and its audit rows are kept.
-- Holds, declines and decisions already written are ordinary audited rows and stay. /refund fails closed again (no card) after this.
begin;

drop function if exists public.telegram_inquiry_message_logged_v1(uuid, bigint, text, text, text, boolean, text, text);
drop function if exists public.telegram_inquiry_decide_v1(bigint, uuid, text, text, integer);
drop function if exists public.telegram_inquiry_view_v1(uuid);

delete from public.telegram_pending where kind in ('inquiry_reply', 'refund_confirm', 'lock_code');

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind = any (array[
  'duplicate', 'large_amount', 'photo_dup', 'inventory_sync', 'advisory_notice', 'advisory_scan',
  'llm_expense', 'llm_notice', 'llm_void_notice', 'llm_void_txn', 'llm_void_txns', 'llm_edit_notice',
  'inventory_count', 'awaiting_reply', 'llm_house', 'guest_pick', 'guest_save'
]));

commit;
