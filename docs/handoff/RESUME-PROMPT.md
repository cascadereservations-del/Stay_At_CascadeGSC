# Copy/Paste Resume Prompt for the Next Developer

```text
Continue the Cascade Hideaway business-system project from:
C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol

Read these files in order before editing:
1. HANDOFF.md
2. docs/handoff/README.md
3. docs/handoff/CURRENT-STATE.md
4. docs/handoff/DEVELOPMENT-PLAYBOOK.md
5. docs/handoff/FILE-MAP.md
6. docs/plans/module-execution-queue.md

Context:
- Supabase is canonical for all business facts and state transitions.
- Existing Portainer n8n is used initially in the Cascade Hideaway folder, but all source workflows remain inactive. n8n is delivery/integration only, never booking/payment authority.
- Finance/Admin and OPS are strictly separate. OPS never receives money, payment, receipt, bank, rate, deposit, refund, or guest contact information.
- AI/OpenRouter is advisory only. It cannot confirm payment, post financial decisions, override policy, or approve a booking.
- Human approval is mandatory for payment/booking confirmation, refunds, discounts, exceptions, cleaning overrides, purchase approval, and social publication.
- The business is unregistered; do not claim BIR/tax compliance or automate filing.
- The current architectural next step is Module A production-gate closure. Do not deploy, activate workflows/cron, configure providers, modify Docker/VPS, apply migrations, or send messages without fresh owner approval.

Current branch: codex/cascade-waves-0-1-sol
Run `git log -1 --oneline` for the current handoff commit; do not rely on a copied SHA.

Immediate production gates:
- Dashboard-account MFA is enrolled, but it is not Cascade project Auth MFA/AAL2. Project-owner bootstrap and project TOTP happen only after the staff/RLS migration release is safely applied.
- Supabase Free has no scheduled backups or point-in-time recovery. The owner has chosen to remain on Free; do not apply the staff/cleaner migrations until the owner explicitly approves and proves the selected encrypted external backup/restore process in `docs/runbooks/supabase-external-backup-recovery.md`.
- The selected external backup script is `scripts/recovery/backup-supabase-production.ps1`. It passed syntax/secret/fail-closed checks but has not run against production. It uses the existing `postgres:17` Docker image for `pg_dump`, `pg_restore`, and OpenSSL, with image pulls disabled.
- The release packet is `docs/plans/2026-08-31-module-a-cutover-packet.md`; it is the only approved order for the coordinated staff/RLS/named-cleaner release.

The portable design contract is:
docs/mockups/cascade-experience-mockups.html

The Analytics mockup uses sample values only. Production must calculate gross booking income, approved operating expenses, operating profit, cost per available night, cost per occupied night, electricity/water daily consumption and cost, occupancy, ADR, and RevPAR from reconciled canonical data with owner-approved effective-dated targets.

Work incrementally: read the applicable module plan/runbook, state the authority boundary, implement the smallest reversible change, run focused tests plus secret scan, commit evidence, then stop at the named production gate.
```
