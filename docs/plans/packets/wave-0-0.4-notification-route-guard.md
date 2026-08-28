# Wave 0 Task 0.4 Packet — Finance/OPS Route Guard

## Starting point

- Repository: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- Starting commit: `47c6b35`

## Invariant

Finance may receive booking, payment and administrative financial detail. OPS may receive arrival, departure, turnover, cleaning and staff action detail, but no amount, currency, payment state, payout, revenue, expense, balance, receipt URL, bank reference, refund, deposit, fee, rate, price, cost or transaction information—even when nested in metadata or hidden in free text.

## RED

Create `supabase/functions/_shared/notifications.test.ts` before `notifications.ts`. Cover safe OPS rendering, nested forbidden keys, `notes="guest paid PHP 1780"`, unknown fields/arbitrary prose, Finance amount rendering and post-render OPS validation.

Create `supabase/tests/database/notification_route_guard.sql` before migration `20260828000100_notification_route_guard.sql`. Assert route/template columns and constraints, safe OPS insert, nested-amount rejection, free-text payment rejection and Finance acceptance.

```powershell
npx.cmd --yes deno test --no-lock supabase/functions/_shared/notifications.test.ts
```

Expected RED: missing `notifications.ts`. The database test remains pending until a local PostgreSQL/Supabase runtime is available.

## GREEN

- Provide closed route-specific templates; callers cannot send arbitrary message bodies.
- Recursively inspect object keys, arrays and strings before rendering. Recheck the rendered OPS text.
- Add `route_class` and `template_key` to the transactional outbox.
- Add an immutable recursive SQL guard used by an outbox check constraint.
- Preserve existing events with default route `internal`; no current event is silently reclassified as OPS.

## Verification

```powershell
npx.cmd --yes deno test --no-lock supabase/functions/_shared/notifications.test.ts
node scripts/audit/compare-supabase-production.mjs --check
npx.cmd --yes supabase test db supabase/tests/database/notification_route_guard.sql
```

The SQL command is required before deployment. If Docker remains unavailable, record it as an explicit staging gate; do not deploy the migration.

### Current local result

On 2026-08-28 the Deno suite passed 6/6. The current Supabase CLI accepted the positional test path but could not connect to `127.0.0.1:54322` because the local Docker-backed database was not running. The SQL migration and pgTAP file are therefore source-complete but not approved for deployment until that exact test passes on a disposable local/staging database.

## Rollback

Before production, discard the migration. After an approved expand-only deployment, rollback by stopping new writers and dropping only the new check/columns/function after verifying no dependent release uses them. No destructive rollback is automated.

## Commit

```powershell
git add docs/plans/packets/wave-0-0.4-notification-route-guard.md supabase/functions/_shared/notifications.ts supabase/functions/_shared/notifications.test.ts supabase/migrations/20260828000100_notification_route_guard.sql supabase/tests/database/notification_route_guard.sql
git commit -m "feat(cascade): enforce finance and ops message separation"
```
