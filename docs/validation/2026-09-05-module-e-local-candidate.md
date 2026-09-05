# Module E local candidate validation — 2026-09-05

Module E now has a local-only booking lifecycle candidate. It is not deployed, no scheduler or workflow was activated, and no provider action was taken.

## Implemented boundaries

- Direct-booking holds are idempotent, expire safely, snapshot the effective approved rate-policy version, and serialize with confirmation on the existing property transaction lock.
- An active competing hold blocks confirmation. An expired, cancelled, or no-show booking cannot later transition to confirmed.
- Amendments, cancellations, no-shows, and calendar reconciliation require a named AAL2 owner/admin session and create immutable audit events.
- Cancellation releases calendar occupancy without silently authorizing or executing a refund. Refund authorization is a separate named AAL2 Finance/Admin record and never changes a transaction or payment fact.
- Calendar rows remain projections. Reconciliation repairs one direct-booking projection and queues an inactive internal projection event.
- The legacy booking/calendar key repair remains a separate reviewed expand-contract release.

## Validation

- Node source-boundary suite: 5/5 passed.
- Combined booking and handoff source suite: 24/24 passed.
- Platform-safety suite: 37/37 passed.
- n8n source inventory: all 13 exports remain inactive and valid.
- PostgreSQL/pgTAP: 43/43 passed in one transaction that rolled back the candidate DDL and all synthetic fixtures, including an Asia/Manila-to-UTC expiry boundary.
- Two-session collision proof: the losing overlapping hold waited 2,152 ms for the property lock, failed closed, and the disposable database contained exactly one active hold. The disposable database and dump were removed by the validation script.
- The collision test uses `scripts/validation/verify-booking-hold-collision.ps1` and never touches the production project.

Production remains frozen behind Module A. Module B/C/D/E are local release candidates only.
