-- 20260913140000_telegram_pending_llm_kinds.sql (D-105, Cassy session 7)
-- telegram_pending.kind allowed only 4 values since 20260529065052 / 20260529101217, but
-- telegram-expense writes 12 (advisory_*, llm_*), and createPending swallowed the check error,
-- so every LLM/advisory confirm card was dead. Cassy's log_expense hit the same wall live
-- (2026-09-13 14:14Z). Allow every kind the bot writes.
begin;

alter table public.telegram_pending drop constraint if exists telegram_pending_kind_check;
alter table public.telegram_pending add constraint telegram_pending_kind_check check (kind in (
  'duplicate','large_amount','photo_dup','inventory_sync',
  'advisory_notice','advisory_scan',
  'llm_expense','llm_notice','llm_void_notice','llm_void_txn','llm_void_txns','llm_edit_notice'
));

-- forward check: the constraint now lists 12 kinds
do $$
begin
  if (select count(*) from unnest(array['duplicate','large_amount','photo_dup','inventory_sync','advisory_notice','advisory_scan','llm_expense','llm_notice','llm_void_notice','llm_void_txn','llm_void_txns','llm_edit_notice']) k
      where pg_get_constraintdef((select oid from pg_constraint where conname='telegram_pending_kind_check')) like '%''' || k || '''%') <> 12 then
    raise exception 'telegram_pending_kind_check does not list all 12 kinds';
  end if;
end $$;

commit;
