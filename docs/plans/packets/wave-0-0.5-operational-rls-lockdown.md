# Wave 0 Task 0.5 Packet — Operational RLS Lockdown

## Starting point

- Repository: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- Starting commit: `955eaf8`

## Compatibility finding

The August booking migrations already removed public booking/calendar reads, but the historical schema still contains anonymous full access for inventory and anonymous read/write paths for cleaning sessions and meter readings. `inventory_items` also lacks `property_id`, violating the one-to-three-property boundary.

## RED

Create `supabase/tests/database/operational_rls_lockdown.sql` first. Assert property ownership on inventory, no anonymous privileges, scoped authenticated privileges, service-role continuity, safe public availability boundaries and runtime property isolation for cleaner/owner JWT fixtures.

Current local PostgreSQL is unavailable, so RED execution is a documented Docker gate. Do not deploy to obtain a failing test.

## GREEN

- Add and backfill `inventory_items.property_id` only when unscoped rows can be assigned to exactly one active property; otherwise abort migration.
- Revoke anonymous access to inventory, cleaning and meters.
- Grant authenticated table operations only where closed RLS policies restrict role and property.
- Owner/admin have property-wide management; Finance/inspector/maintenance receive read scopes; cleaners receive property-scoped operational scopes.
- Preserve service-role access and the public availability Edge Function boundary.

## Deployment gate

This migration must not be deployed until the cleaner and inventory clients use named authenticated/scoped server sessions and pass compatibility tests. Source completion is not cutover authorization.

## Verification

```powershell
npx.cmd --yes supabase test db supabase/tests/database/operational_rls_lockdown.sql
node scripts/audit/compare-supabase-production.mjs --check
```

## Rollback

Use expand/backfill/verify before revoking legacy paths. If compatibility fails before the revoke release, stop. After revocation, restore only narrowly reviewed grants/policies temporarily; do not drop `property_id` or discard property assignments.

## Commit

```powershell
git add docs/plans/packets/wave-0-0.5-operational-rls-lockdown.md supabase/migrations/20260828000200_operational_rls_lockdown.sql supabase/tests/database/operational_rls_lockdown.sql
git commit -m "fix(cascade): lock down operational tables"
```
