# ADR-001 — Use the existing Portainer n8n runtime initially

**Status:** Superseded for future Cascade hosting by ADR-002 on 2026-09-06; retained as the historical initial-runtime decision

## Decision

Cascade will use the existing Portainer-managed n8n instance initially. All Cascade work must live in a dedicated `Cascade` folder/project with dedicated Cascade credentials, workflow names, tags, access permissions, and source-controlled exports in `automation/n8n/workflows/`.

Supabase remains the booking, payment, calendar, identity and audit authority. n8n only consumes signed outbox events, delivers external actions, and reports normalized outcomes. Google Apps Script remains a narrow Google integration/legacy relay, never the authority for bookings or payments.

## Required boundaries

- No Cascade workflow may use Alfred/Alex credentials, folders, webhooks, data stores, or workflow IDs.
- All credentials are named `Cascade — <provider/purpose>` and are visible only to authorized Cascade owner/admin users.
- Import/export and fixture runs begin inactive. Activation, real messages, OAuth setup, and credential creation require action-time owner approval.
- Workflows must preserve the Finance/OPS route boundary: OPS receives no payment, amount, receipt, bank, payout, or balance information.

## Superseded Docker migration direction

`infrastructure/cascade-n8n/` is retained as a tested migration path. The read-only 2026-09-06 Portainer review found that the existing n8n service is coupled to Alfred's project, network, storage, and LifeVault host files. ADR-002 now directs this migration to a separate Cascade VPS while preserving Alfred unchanged.

The original reconsideration triggers were:

1. The shared n8n runtime has recurring outages that affect Cascade.
2. Credential/access separation from Alfred/Alex cannot be enforced or audited.
3. Cascade workload materially degrades Alfred/Alex execution reliability.
4. Cascade expands to multiple properties or staff teams and needs independent scaling, recovery, or change windows.

The isolation trigger is now met. Do not run the standalone Compose stack automatically; procurement and every infrastructure action remain separately gated.
