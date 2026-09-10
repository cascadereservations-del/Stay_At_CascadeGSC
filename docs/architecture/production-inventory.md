# Cascade Production Contract Inventory

**Captured:** 2026-08-28 (Asia/Manila)

**Canonical Supabase project:** `qkgfhsdppslwunarczeq`

**Mode:** Read-only metadata capture; no deployment, workflow activation or production write.

## Result

- 21 active Edge Functions were returned by Supabase CLI 2.116.0.
- 9 deployed functions had local `index.ts` source at capture time.
- 12 critical deployed functions were missing local source and block the production-contract check.
- `ocr-receipt` is the only deployed function with platform JWT verification enabled. A disabled platform JWT check is not automatically safe; compensating controls are audited separately in Task 0.7.
- Function IDs, temporary entrypoint paths, credentials, database URLs, raw commands and secret values are intentionally excluded.

## Edge Functions

| Function | Version | JWT | Source at capture |
|---|---:|---:|---|
| `airbnb-email-sync` | 17 | off | missing-source |
| `approve-booking` | 11 | off | versioned |
| `automation-callback` | 4 | off | versioned |
| `automation-event-detail` | 4 | off | versioned |
| `availability` | 23 | off | versioned |
| `calendar-sync` | 23 | off | versioned |
| `daily-digest` | 24 | off | missing-source |
| `guest-access` | 3 | off | versioned |
| `last-readings` | 22 | off | missing-source |
| `missed-cleaning-alert` | 6 | off | missing-source |
| `notify-cleaner-payment` | 6 | off | missing-source |
| `ocr-receipt` | 19 | on | missing-source |
| `rain-alert` | 13 | off | missing-source |
| `submit-booking` | 32 | off | versioned |
| `submit-cleaning` | 32 | off | missing-source |
| `telegram-expense` | 61 | off | missing-source |
| `track-site-event` | 3 | off | versioned |
| `turnover-verifier` | 6 | off | missing-source |
| `upload-booking-receipt` | 3 | off | versioned |
| `upload-photo` | 22 | off | missing-source |
| `weather-proxy` | 12 | off | missing-source |

`upload-photo` was absent from the original Wave 0 Task 0.2 list. It is business-critical to cleaning evidence and is now included in recovery.

## Database metadata

The tracked production schema snapshot is `supabase/schemas/000_remote_public_schema.sql`, normalized-LF SHA-256 `ca8f98ff2952a4a6db73ff02d8e8fb6d0f3cf622899c0a0ee7b7259c721af7c6`. The checker extracts 33 table declarations, policy declarations and RLS-enabled table declarations from it and verifies the hash. During the disposable recovery proof, the snapshot's `price_history_by_item` view was proven to recurse into itself in both source and production; the snapshot now contains the intended base-table definition, while migration `20260830070000_fix_price_history_view_recursion.sql` remains undeployed pending a normal production release gate.

This SQL snapshot is not represented as a fresh 2026-08-28 live dump. Later versioned migrations add booking hardening, outbox, CRM identity and calendar projection objects. A fresh read-only dump was attempted using the canonical project reference, but the CLI requires Docker Desktop for its pinned PostgreSQL image and Docker was unavailable. Until a current dump succeeds, table/column/constraint/policy completeness remains an explicit recovery gate rather than a false claim.

## Scheduler contract

The known job-to-function mapping is `turnover-verifier-daily` → `turnover-verifier`. The job was previously observed failing and the live invocation mapping requires repair. Its raw command is not checked in because cron commands may embed privileged URLs or keys. Task 0.6 replaces this with a secret-backed invocation and a monitored heartbeat.

No other schedule is claimed current until safe cron metadata is re-exported. This prevents a stale schedule list from being treated as operational truth.

## Storage contract

| Bucket | Versioned evidence | Live status |
|---|---|---|
| `booking-receipts` | Private bucket and receipt-specific policies in migrations `20260824044700` and `20260824002834` | public=false by deployed migration; live metadata not re-dumped |
| `cleaning-photos` | Object policies in migration `20260528111436` | public setting not reverified |

Storage bucket metadata must be rechecked during the next approved read-only database preflight. No bucket or object was changed during this inventory.

## Guard command

```powershell
node scripts/audit/compare-supabase-production.mjs --check
```

The command exits nonzero while any critical deployed function lacks local source or the tracked schema snapshot hash changes. That block is expected to clear in Task 0.2, not to be waived.
