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

| Guest conversation threads and messages | Stay service, booking support, service recovery | Supabase `guest_conversations`, `guest_conversation_messages`, `guest_reply_drafts`, `guest_conversation_audit` | Owner/admin at AAL2 via `manage_guest_inbox`; no anon or authenticated read | 2 years after the conversation is resolved unless incident/hold | Message and draft bodies are stored as ciphertext with a separately redacted preview; the external thread identifier is stored only as a SHA-256 hash. No reply is ever sent by this system. |
| CRM guest contact hashes | Recognize a returning guest without storing raw contact details | Supabase `crm_guest_profiles` | Owner/admin at AAL2; no anon or authenticated read | Follows the completed booking/guest identity period | Email and phone are stored **only** as SHA-256 hashes and indexed as hashes. At least one of the two must be present. |
| Guest consent events | Evidence that consent for a purpose was granted or withdrawn at a point in time | Supabase `crm_consent_events` | Owner/admin at AAL2; no anon or authenticated read | Retain for the life of the profile plus the applicable limitation period | Append-only evidence. Purpose is one of operational, service_recovery, marketing. Never delete as part of a rollback -- these rows are the proof of what the guest agreed to and when. |
| Guest lifecycle events | Stay history and preference signals, and marketing suppression | Supabase `crm_lifecycle_events` | Owner/admin at AAL2; no anon or authenticated read | 5 years after last completed stay unless dispute/legal hold | Free-text values are stored only as hashes. Opening a service recovery forces `suppress_marketing`. |
| Guest retention decisions | Record a retain/restrict/delete-due/legal-hold decision against a profile | Supabase `crm_retention_decisions` | Owner/admin at AAL2; no anon or authenticated read | Retain for the life of the profile plus the applicable limitation period | This is the machine-readable form of this schedule. A legal hold carries no end date by construction. |
| Marketing drafts and their reviews | Draft and review guest-directed marketing before any human decision to publish | Supabase `marketing_drafts`, `marketing_draft_reviews` | Owner/admin at AAL2; no anon or authenticated read | 1 year after the review decision | Content and subject are ciphertext plus hash. Consent eligibility is asserted at draft and re-checked at review. `publication_authorized` carries a `check (not publication_authorized)` constraint, so **the database cannot record send authority at all**. Eligibility is not send authority. |

## Processors and boundaries

- **Supabase:** canonical database, Auth, Storage and Edge Functions.
- **Existing Portainer n8n:** signed event delivery only; Cascade folder/project and dedicated credentials.
- **Google/Gmail and Apps Script:** narrow payment-notification or legacy relay integration; raw message bodies are not stored in the system.
- **OpenRouter:** future advisory OCR/chat tasks only with approved, pinned models and data minimization.
- **Telegram:** delivery channel; Finance and OPS receive different, closed templates.

Before adding a processor or data field, update this inventory, confirm the purpose, define access and retention, and add a deletion/hold path.
