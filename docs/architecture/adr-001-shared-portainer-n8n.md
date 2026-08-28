# ADR-001 — Use the existing Portainer n8n runtime initially

**Status:** Accepted on 2026-08-28

## Decision

Cascade will use the existing Portainer-managed n8n instance initially. All Cascade work must live in a dedicated `Cascade` folder/project with dedicated Cascade credentials, workflow names, tags, access permissions, and source-controlled exports in `automation/n8n/workflows/`.

Supabase remains the booking, payment, calendar, identity and audit authority. n8n only consumes signed outbox events, delivers external actions, and reports normalized outcomes. Google Apps Script remains a narrow Google integration/legacy relay, never the authority for bookings or payments.

## Required boundaries

- No Cascade workflow may use Alfred/Alex credentials, folders, webhooks, data stores, or workflow IDs.
- All credentials are named `Cascade — <provider/purpose>` and are visible only to authorized Cascade owner/admin users.
- Import/export and fixture runs begin inactive. Activation, real messages, OAuth setup, and credential creation require action-time owner approval.
- Workflows must preserve the Finance/OPS route boundary: OPS receives no payment, amount, receipt, bank, payout, or balance information.

## Deferred Docker migration

`infrastructure/cascade-n8n/` is retained as a tested migration path, not an initial deployment target. Reconsider it only if one or more triggers occur:

1. The shared n8n runtime has recurring outages that affect Cascade.
2. Credential/access separation from Alfred/Alex cannot be enforced or audited.
3. Cascade workload materially degrades Alfred/Alex execution reliability.
4. Cascade expands to multiple properties or staff teams and needs independent scaling, recovery, or change windows.

When a trigger occurs, perform a read-only Portainer/VPS inventory and a fresh capacity/backup preflight before proposing migration. Do not run the standalone Compose stack automatically.
