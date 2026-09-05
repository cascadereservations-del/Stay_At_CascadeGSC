# Modules D–E Local Delivery Implementation Plan

**Goal:** Complete the local Finance review queue, inactive delivery boundary, and booking lifecycle foundations without touching production.

**Architecture:** Supabase remains the sole owner of review and booking transitions. A Finance-only RPC shapes review-queue records for a named AAL2 user, a thin Edge Function exposes that RPC, and pure delivery helpers minimize each workflow payload before inactive n8n consumes it. Module E adds audited, idempotent lifecycle commands around the existing atomic booking transaction while keeping refunds human-authorized and calendar rows projections.

**Tech Stack:** PostgreSQL 17/pgTAP, Supabase Edge Functions on Deno, TypeScript, Node test runner, inactive n8n JSON exports.

---

### Task 1: Finance review queue

**Files:**
- Create: `supabase/migrations/20260905020000_payment_review_queue.sql`
- Create: `supabase/functions/payment-review-queue/logic.ts`
- Create: `supabase/functions/payment-review-queue/index.ts`
- Create: `supabase/functions/payment-review-queue/logic.test.ts`
- Create: `supabase/tests/database/payment_review_queue.sql`
- Create: `tests/bookings/payment-review-queue-boundary.test.mjs`

- [ ] Write tests requiring a bounded property-scoped request, named AAL2 Finance access, OPS denial, provenance, comparison warnings, immutable history, and no direct decision write.
- [ ] Add `get_payment_review_queue(uuid,integer)` as a guarded JSON RPC returning minimized queue records from Module C tables.
- [ ] Add the thin authenticated Edge Function and pure input/parser helpers.
- [ ] Run the Node, Deno, and rollback-only pgTAP tests; commit the files with dated validation evidence.

### Task 2: Inactive delivery boundary

**Files:**
- Create: `supabase/functions/automation-event-detail/logic.ts`
- Create: `supabase/functions/automation-event-detail/logic.test.ts`
- Modify: `supabase/functions/automation-event-detail/index.ts`
- Modify: `supabase/functions/automation-callback/index.ts`
- Modify: `supabase/functions/_shared/automation-delivery.ts`
- Create: `tests/automation/module-d-delivery-boundary.test.mjs`

- [ ] Write tests for a closed workflow/event matrix and audience-specific field allowlists.
- [ ] Build Finance, guest, and internal payloads from explicit allowlists; no workflow receives a general booking row.
- [ ] Make callback retries idempotent by stable workflow/channel/provider identifiers and prevent callbacks from changing business tables.
- [ ] Validate Deno, source boundaries, 13 inactive workflow exports, and secrets; commit with evidence.

### Task 3: Audited booking lifecycle

**Files:**
- Create: `supabase/migrations/20260905030000_booking_lifecycle.sql`
- Create: `supabase/tests/database/booking_lifecycle.sql`
- Create: `tests/bookings/booking-lifecycle-boundary.test.mjs`
- Create: `docs/plans/2026-09-05-legacy-booking-calendar-key-expand-contract.md`

- [ ] Write pgTAP tests for idempotent holds, expiry, amendments, cancellation, no-show, named AAL2 refund authorization, projection reconciliation, and immutable audit history.
- [ ] Add property-scoped lifecycle tables and guarded RPCs that never bypass `decide_direct_booking` for confirmation.
- [ ] Add concurrent-session proof for overlapping decisions and document the separate legacy-key expand/contract release.
- [ ] Run focused and broad local checks; commit with dated validation evidence and stop at the production gate.

### Task 4: Later-wave local foundations

**Files:**
- Create one independently reversible migration and pgTAP suite per wave under `supabase/migrations/` and `supabase/tests/database/`.
- Create one dated validation record per completed wave under `docs/validation/`.

- [ ] Wave 2: consent-aware conversation timeline, drafts, assignment, redaction, and human escalation; no live sends.
- [ ] Wave 3: private cleaning/meter evidence, deterministic correction, inspection, and named override audit.
- [ ] Wave 4: stock reconciliation, demand forecast, recommendation, and human purchase approval; no supplier order.
- [ ] Wave 5: reconciled management metrics and effective-dated targets with freshness/exclusions.
- [ ] Waves 6–7: consent/retention CRM plus exact-content approval; no publication.
- [ ] Wave 8: authority inventory, recovery/incident evidence checklist, ownership map, and final local integration checks.

Production deployment, provider configuration, workflow activation, message sending, and Module A recovery remain separate owner-approved work.
