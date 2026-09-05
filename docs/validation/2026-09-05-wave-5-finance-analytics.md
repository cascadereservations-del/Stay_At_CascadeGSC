# Wave 5 Finance reconciliation and management analytics — 2026-09-05

Status: local candidate verified. Not deployed.

Named AAL2 Finance/Admin users record paired, opaque source references and normalized values. The database deterministically classifies exact, mismatched, missing, and duplicate sources. Missing or duplicate candidates cannot become facts. For a mismatch, a named reviewer may select only one of the compared values, with a reason; follow-up creates no fact. Only immutable approved facts feed reports.

The internal report calculates gross booking income, operating expenses/profit, cost per available and occupied night, ADR, RevPAR, occupancy, and daily electricity/water use and cost. It shows data freshness, effective owner targets, and non-operating exclusions. It explicitly returns `internal_management_only=true` and `statutory_or_tax_compliance=false`. The business remains unregistered; this is not tax, BIR, filing, or statutory output.

Effective-dated targets require a named AAL2 owner. Overlapping versions and changed idempotent retries fail closed. OPS, anonymous users, and service integrations cannot browse or mutate the new Finance records or execute review.

Validation passed:

- Node source-boundary suite: 5/5.
- PostgreSQL/pgTAP: 50/50 in one transaction ending in `ROLLBACK`.
- Compensating rollback: passed in a disposable restored database; all Wave 5 tables and functions were removed without `CASCADE`.
- Platform-safety suite: 37/37.
- n8n inventory: all 13 exports remained inactive.
- Secret scan and Git whitespace checks passed.

No migration ledger entry, fixture, candidate object, provider action, workflow activation, production data, or production configuration changed. Production remains frozen behind Module A.
