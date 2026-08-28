# Cascade personal-data inventory

Status: working inventory for the unregistered Cascade business. It is not legal advice and must be reviewed against current Philippine privacy requirements before production activation.

| Data category | Purpose | Primary storage | Access | Proposed retention | Notes |
|---|---|---|---|---|---|
| Guest name, phone, email, stay dates, pax | Reservation, check-in, service recovery | Supabase booking/guest records | Owner/admin; service functions | 5 years after last completed stay unless dispute/legal hold | Do not send full records to OPS Telegram. |
| Payment receipt object, hash, OCR candidates | Payment review and fraud/duplicate detection | Private Supabase Storage + payment evidence tables | Owner/admin/finance; audited service functions | 5 years after financial close unless hold | OCR is advisory; never mark paid automatically. |
| Bank notification metadata/reference | Correlate declared payment with notification | Supabase payment evidence | Owner/admin/finance | 5 years after financial close unless hold | Store minimum parsed fields; never raw email body. |
| Airbnb reservation/payout data | Calendar projection, reconciliation, analytics | Supabase | Owner/admin/finance | 5 years after financial close unless hold | Airbnb remains its own payment channel. |
| Cleaning photos, meter readings, checklist | Turnover quality, utility verification, maintenance | Supabase Storage + operations records | Cleaner scoped access; inspector; owner/admin | 2 years after submission unless incident/hold | Photos are operational evidence, not marketing assets. |
| Staff identity, role, device/session events | Access control and audit | Supabase Auth + staff-access tables | Owner/admin | Employment + 2 years; longer only for legal/accounting need | Named accounts only; no permanent shared code. |
| Telegram automation identifiers/results | Delivery audit and operational coordination | Supabase outbox/delivery logs | Route-specific owner/admin/service | 1 year unless linked to incident/financial record | OPS payloads contain no financial data. |
| Site funnel events | Aggregate conversion improvement | Supabase analytics | Owner/admin | 13 months | Do not collect receipt, payment, access-code, or message-body data. |

## Processors and boundaries

- **Supabase:** canonical database, Auth, Storage and Edge Functions.
- **Existing Portainer n8n:** signed event delivery only; Cascade folder/project and dedicated credentials.
- **Google/Gmail and Apps Script:** narrow payment-notification or legacy relay integration; raw message bodies are not stored in the system.
- **OpenRouter:** future advisory OCR/chat tasks only with approved, pinned models and data minimization.
- **Telegram:** delivery channel; Finance and OPS receive different, closed templates.

Before adding a processor or data field, update this inventory, confirm the purpose, define access and retention, and add a deletion/hold path.
