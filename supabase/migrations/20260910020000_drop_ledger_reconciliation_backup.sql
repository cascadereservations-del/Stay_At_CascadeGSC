-- Drop the pre-reconciliation ledger backup taken before D-047.
--
-- supabase_migrations.schema_migrations_backup_20260908 is a 77-row copy of the
-- ledger as it stood before the 2026-09-09 reconciliation. It was insurance
-- while the repaired ledger proved itself. It has now done so: 84 rows, zero
-- MCP-assigned version strings, and every release since has applied cleanly
-- through the contract path.
--
-- The guards below refuse to remove the safety net unless the thing it was
-- protecting is demonstrably healthy.

do $$
declare
  live_rows integer;
  mcp_era integer;
begin
  select count(*) into live_rows from supabase_migrations.schema_migrations;
  if live_rows < 84 then
    raise exception 'ledger has % rows, expected at least 84 - refusing to remove the backup', live_rows;
  end if;

  -- A reconciled ledger carries a filename-shaped version for every row.
  -- Anything else is the MCP-assigned drift that D-047 repaired.
  select count(*) into mcp_era
  from supabase_migrations.schema_migrations
  where version !~ '^[0-9]{14}$';
  if mcp_era > 0 then
    raise exception 'ledger still holds % non-filename version string(s) - refusing to remove the backup', mcp_era;
  end if;

  if to_regclass('supabase_migrations.schema_migrations_backup_20260908') is null then
    raise notice 'backup table already absent - nothing to remove';
  end if;
end $$;

drop table if exists supabase_migrations.schema_migrations_backup_20260908;
