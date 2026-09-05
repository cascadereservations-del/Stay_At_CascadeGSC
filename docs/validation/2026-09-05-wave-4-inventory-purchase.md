# Wave 4 inventory forecast and purchase review — 2026-09-05

Status: local candidate verified. Not deployed.

Git baseline was branch `codex/cascade-waves-0-1-sol`, HEAD `799a692`, following Wave 3 completion `ab39695`. The pre-existing Task Master files and modified `.gitignore` were preserved and excluded from this feature commit.

## Authority and behavior

- Named AAL2 owner/admin users with current property access record movements, reconcile counts, create forecasts, and review proposed shopping quantities. Finance alone, OPS, anonymous clients, and service integrations cannot use these RPCs or browse the new private records.
- Movement quantities use canonical item units and two decimal places. Receipts are positive; usage is negative; reconciliations set a verified absolute count. Every movement records before/after quantities, actor, reason and idempotency key and updates canonical stock in the same transaction.
- The initial balance and any drift from legacy writes require an explicit reconciliation. Legacy writers are unchanged. This is a guarded local foundation, not a completed legacy inventory cutover.
- Forecast v1 sums recorded usage over the selected 1–365 day window, divides by window days, multiplies by the 1–90 day horizon, subtracts stock, and rounds a positive shortfall up. It snapshots its inputs and latest movement. Missing/unrecorded history can understate demand: a zero recommendation is not assurance of sufficient stock. Booking-demand models and provider adapters are outside this candidate.
- Human review records the exact selected quantity, outcome, reason, identity and forecast. Approval is a shopping-list decision only: `order_authorized=false`. It does not purchase stock, approve an expense, create a financial transaction, queue delivery or invoke a supplier.
- Item locks serialize movements, forecast creation and review. Changed stock, changed movement, changed property, inactive items or snapshots older than 24 hours block new review. Retries must match original inputs and actor. Review rows cannot be edited through client/service grants.

## Verification evidence

- `node --test tests/inventory/inventory-forecast-boundary.test.mjs`: 5/5 passed.
- `npm.cmd run test:platform-safety`: 37/37 passed.
- `node scripts/check-n8n-workflows.mjs`: 13 inactive exports validated.
- `node scripts/audit/scan-secrets.mjs`: passed.
- `git diff --check`: passed before staging; staged files checked separately before commit.
- `powershell -File scripts/validation/verify-inventory-forecast.ps1`: 31/31 pgTAP assertions passed against the local Supabase container. Candidate DDL and synthetic fixtures ran in one transaction ending in `ROLLBACK`; a post-check confirmed the three candidate tables were absent.
- `powershell -File scripts/validation/verify-inventory-concurrency.ps1`: passed in a disposable restored database. A stock receipt held the canonical item lock; simultaneous purchase review waited 5,063 ms, observed the committed stock change, and failed closed as stale. Final pre-rollback state was stock `7.00` and zero purchase reviews.
- The same disposable run executed the compensating rollback. All three Wave 4 tables and the authority function were removed without `CASCADE`, after which the disposable database and dump were removed.

## Remaining release boundary

The fixed local pgTAP target is `supabase_db_direct-booking`. Neither validation runner accepts a production connection string. No migration was applied to the active local ledger, and no local fixture or Wave 4 object persisted.

The compensating rollback is `supabase/rollbacks/20260905060000_inventory_forecast_purchase_review.sql`. It removes only Wave 4 objects, with no cascading deletion or legacy grant changes. Before any future approved release rollback, preserve the new audit records. It intentionally does not undo recorded physical stock changes; restoring prior facts blindly would be unsafe.

Production remains frozen behind Module A. No deployment, workflow activation, provider setup, order, message or production change occurred.
