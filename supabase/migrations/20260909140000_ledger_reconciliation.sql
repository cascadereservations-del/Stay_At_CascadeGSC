-- Ledger reconciliation (D-041). Applying the 2026-09-08 releases through the
-- Supabase MCP recorded nine migrations under MCP-assigned version strings
-- instead of their source filenames. The content is identical (proved by md5 of
-- the stored statements against the repo files; two differ only by a stripped
-- leading comment block). Rewrite the nine versions so the ledger names the
-- files that are actually applied. This migration records its own row through
-- the normal release path, so the repair itself is in the ledger.
--
-- Deliberately NOT done here: dropping the pre-change copy
-- supabase_migrations.schema_migrations_backup_20260908 (rollback evidence), and
-- any row for 20260824045800_dispatch_w01_to_n8n, which stays unrecorded by
-- design (D-022, D-028).
--
-- Every assertion is relative, so this runs identically against a restored
-- rehearsal copy and against production.

do $$
declare
  m record;
  n int;
  rewritten int := 0;
  before_count int;
  after_count int;
begin
  select count(*) into before_count from supabase_migrations.schema_migrations;

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
    -- Idempotent: if the row already carries the source version, nothing to do.
    if exists (select 1 from supabase_migrations.schema_migrations
                where version = m.new_version and name = m.mig_name) then
      continue;
    end if;
    if exists (select 1 from supabase_migrations.schema_migrations
                where version = m.new_version) then
      raise exception 'target version % already exists with a different name', m.new_version;
    end if;
    update supabase_migrations.schema_migrations
       set version = m.new_version
     where version = m.old_version and name = m.mig_name;
    get diagnostics n = row_count;
    if n <> 1 then
      raise exception 'expected 1 row for % / %, got %', m.old_version, m.mig_name, n;
    end if;
    rewritten := rewritten + 1;
  end loop;

  select count(*) into after_count from supabase_migrations.schema_migrations;
  if after_count <> before_count then
    raise exception 'ledger row count changed from % to %', before_count, after_count;
  end if;

  -- Post-state: all nine source versions present under their names.
  select count(*) into n from supabase_migrations.schema_migrations
   where (version, name) in (
     ('20260831010000','privacy_requests_and_holds'),
     ('20260901010000','canonical_booking_decision'),
     ('20260905010000','payment_evidence_finance_review'),
     ('20260905020000','payment_review_queue'),
     ('20260905030000','booking_lifecycle'),
     ('20260905050000','cleaning_meter_verification'),
     ('20260905060000','inventory_forecast_purchase_review'),
     ('20260905070000','finance_reconciliation_analytics'),
     ('20260908000200','staff_users_service_grants'));
  if n <> 9 then
    raise exception 'expected 9 reconciled rows, found %', n;
  end if;

  raise notice 'ledger reconciliation: % rows rewritten, % rows total', rewritten, after_count;
end $$;
