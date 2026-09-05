# Copy/Paste Resume Prompt for the Next Developer

```text
Continue the Cascade Hideaway business-system project from:
C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol

Read these files in order before editing:
1. HANDOFF.md
2. docs/handoff/README.md
3. docs/handoff/COMPLETE-HANDOFF-2026-09-05.md
4. docs/handoff/CURRENT-STATE.md
5. docs/handoff/DEVELOPMENT-PLAYBOOK.md
6. docs/handoff/FILE-MAP.md
7. docs/plans/module-execution-queue.md
8. docs/validation/2026-09-05-module-c-local-candidate.md

Context:
- Supabase is canonical for all business facts and state transitions.
- Existing Portainer n8n is used initially in the Cascade Hideaway folder, but all source workflows remain inactive. n8n is delivery/integration only, never booking/payment authority.
- Finance/Admin and OPS are strictly separate. OPS never receives money, payment, receipt, bank, rate, deposit, refund, or guest contact information.
- AI/OpenRouter is advisory only. It cannot confirm payment, post financial decisions, override policy, or approve a booking.
- Human approval is mandatory for payment/booking confirmation, refunds, discounts, exceptions, cleaning overrides, purchase approval, and social publication.
- The business is unregistered; do not claim BIR/tax compliance or automate filing.
- The owner explicitly deferred the Free-plan external backup/restore exercise. Continue local source work only; do not deploy, activate workflows/cron, configure providers, modify Docker/VPS, apply migrations, or send messages without fresh owner approval.

Current branch: codex/cascade-waves-0-1-sol
Run `git log -1 --oneline` for the current handoff commit; do not rely on a copied SHA.

Immediate production gates:
- Dashboard-account MFA is enrolled, but it is not Cascade project Auth MFA/AAL2. Project-owner bootstrap and project TOTP happen only after the staff/RLS migration release is safely applied.
- Supabase Free has no scheduled backups or point-in-time recovery. The owner has chosen to remain on Free; do not apply the staff/cleaner migrations until the owner explicitly approves and proves the selected encrypted external backup/restore process in `docs/runbooks/supabase-external-backup-recovery.md`.
- The selected external backup script is `scripts/recovery/backup-supabase-production.ps1`. It passed syntax/secret/fail-closed checks but has not run against production. It uses the existing `postgres:17` Docker image for `pg_dump`, `pg_restore`, and OpenSSL, with image pulls disabled.
- The owner-only passphrase, empty connection-URL placeholder, and backup destination are already prepared outside Git; see `CURRENT-STATE.md` for paths. Supabase does not display the existing database password. Do not reset it without a separate approved connection-impact plan.
- The release packet is `docs/plans/2026-08-31-module-a-cutover-packet.md`; it is the only approved order for the coordinated staff/RLS/named-cleaner release.

Local Module B/C status:
- `supabase/migrations/20260901010000_canonical_booking_decision.sql` is a local-only candidate. Its `decide_direct_booking(uuid, text, text)` RPC serializes a decision, verifies live overlap, and writes booking/reservation/calendar/ledger/projection-outbox state atomically.
- Module C replaces the exposed signature with `decide_direct_booking(uuid, text, text, uuid)`, requiring a matching immutable Finance review. The earlier transaction engine remains private and has no service-role grant.
- `supabase/functions/approve-booking/index.ts` requires a named AAL2 Finance/Admin session, records the review, then calls only the reviewed RPC. Service-signed approval links were removed.
- Two Node boundary tests and ten local pgTAP assertions passed. The local schema revealed missing usable unique constraints on legacy `booking_inquiries.id` and `calendar_events.id`; do not repair those keys opportunistically—make a separate reviewed expand/contract release.
- Module C source checks, two Deno type checks, and four Deno adapter runtime tests pass. Its 47 pgTAP assertions have not run because local Postgres was stopped. Read the dated Module C validation report for exact evidence.
- Modules B and C are not deployed. Their release remains gated by Module A recovery/cutover proof.

Immediate safe next work: run the Module C pgTAP suite in an approved local/disposable Supabase environment and perform the final release review against that database evidence. If it passes, begin Module D as local Admin review-queue work only. Receipt OCR, OpenRouter output, bank email, and comparison remain advisory; only a named human review may reach `decide_direct_booking`.

Task Master is installed. Its local initialization command succeeded, but the CLI did not create `.taskmaster/tasks/tasks.json`, so manual task creation still failed closed. The prepared PRD was not transmitted to an external model and `tasks.json` was not hand-edited. Repair this through Task Master itself; do not route around the safeguard or add Task Master metadata to generated archives/session mirrors/completed derivative worktrees.

The portable design contract is:
docs/mockups/cascade-experience-mockups.html

The Analytics mockup uses sample values only. Production must calculate gross booking income, approved operating expenses, operating profit, cost per available night, cost per occupied night, electricity/water daily consumption and cost, occupancy, ADR, and RevPAR from reconciled canonical data with owner-approved effective-dated targets.

Work incrementally: read the applicable module plan/runbook, state the authority boundary, implement the smallest reversible change, run focused tests plus secret scan, commit evidence, then stop at the named production gate.
```
