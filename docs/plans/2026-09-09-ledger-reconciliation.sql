-- Cascade migration-ledger reconciliation. Prepared 2026-09-09, NOT YET APPLIED.
-- Blocked on 2026-09-09 by the Claude Code auto-mode permission classifier.
--
-- Why: applying the 2026-09-08 releases through the Supabase MCP assigned fresh
-- version strings, so production records 9 migrations under timestamps that do
-- not match their source filenames. `supabase migration list --linked` therefore
-- shows those 9 files as UNAPPLIED, which invites a re-apply. Re-applying the
-- privacy migration after P8 would silently strip staff_access_allowed actions
-- (D-038). Aligning the ledger to the filenames closes that trap.
--
-- Evidence the mapping is exact (checked 2026-09-09): for 7 of the 9, md5 of the
-- stored statements equals md5 of the repo file with its trailing newline
-- stripped. The other 2 differ only by a stripped leading comment block --
-- booking_lifecycle by 155 bytes, staff_users_service_grants by 165 -- both
-- verified as comment-only.
--
-- A full copy of the pre-change ledger already exists as
-- supabase_migrations.schema_migrations_backup_20260908 (77 rows, taken
-- 2026-09-09 before any write).

begin;

do $$
declare
  m record;
  n int;
begin
  for m in select * from (values
    ('20260908130108','20260831010000','privacy_requests_and_holds'),
    ('20260908130955','20260901010000','canonical_booking_decision'),
    ('20260908131435','20260905010000','payment_evidence_finance_review'),
    ('20260908131602','20260905020000','payment_review_queue'),
    ('20260908131746','20260905030000','booking_lifecycle'),
    ('20260908131938','20260905050000','cleaning_meter_verification'),
    ('20260908132035','20260905060000','inventory_forecast_purchase_review'),
    ('20260908132249','20260905070000','finance_reconciliation_analytics'),
    ('20260908021745','20260908000200','staff_users_service_grants')
  ) as t(old_version, new_version, mig_name)
  loop
    if exists (select 1 from supabase_migrations.schema_migrations
                where version = m.new_version) then
      raise exception 'target version % already exists', m.new_version;
    end if;
    update supabase_migrations.schema_migrations
       set version = m.new_version
     where version = m.old_version and name = m.mig_name;
    get diagnostics n = row_count;
    if n <> 1 then
      raise exception 'expected 1 row for % / %, got %', m.old_version, m.mig_name, n;
    end if;
  end loop;
end $$;

-- Post-check: the ledger must still hold 77 rows and every rewritten version
-- must now be present under its source filename's timestamp.
do $$
declare c int;
begin
  select count(*) into c from supabase_migrations.schema_migrations;
  if c <> 77 then raise exception 'ledger row count changed: %', c; end if;

  select count(*) into c from supabase_migrations.schema_migrations
   where version in ('20260831010000','20260901010000','20260905010000',
                     '20260905020000','20260905030000','20260905050000',
                     '20260905060000','20260905070000','20260908000200');
  if c <> 9 then raise exception 'expected 9 rewritten rows, found %', c; end if;
end $$;

commit;
