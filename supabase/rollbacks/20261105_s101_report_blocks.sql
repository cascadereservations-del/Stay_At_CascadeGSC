-- Compensating rollback for release s101_report_blocks_20261105 (migration 20261105000000_s101_report_blocks.sql).
-- Drops the two admin functions. Nothing else was added, so nothing else is undone. NOT undone: held readings an admin already cleared or corrected
-- (vision_resolved_at / _by / _note, corrected numbers and the next stay's re-pointed usage stay as written; the audit history lists each change and can
-- undo it from Settings). Roll the admin dashboard back first if a build that calls these functions is live (the card shows an error, nothing else breaks).
-- Apply with run-sql-on-host.sh.

begin;

drop function if exists public.admin_resolve_report_block_v1(uuid, text, numeric, numeric, text);
drop function if exists public.admin_report_blocks_v1(uuid, integer);

commit;