# Copy/Paste Resume Prompt for the Next Developer

```text
Continue the Cascade Hideaway business-system project from:
C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol

Start by running:
- git status --short
- git log -7 --oneline

Then read, in order:
1. HANDOFF.md
2. docs/handoff/COMPLETE-HANDOFF-2026-09-05.md
3. docs/handoff/CURRENT-STATE.md
4. docs/handoff/DEVELOPMENT-PLAYBOOK.md
5. docs/plans/module-execution-queue.md
6. docs/validation/2026-09-05-module-e-local-candidate.md
7. docs/validation/2026-09-05-wave-2-shared-inbox.md
8. docs/validation/2026-09-05-wave-3-cleaning-meter.md

Current branch: codex/cascade-waves-0-1-sol
Expected latest completed commit at handoff: ab39695 Complete Wave 3 cleaning verification foundation. Verify it from Git rather than assuming the copied SHA is current.

Completed local candidates:
- Module B: canonical atomic booking decision.
- Module C: advisory payment evidence and named Finance review; 47/47 rollback-only pgTAP assertions pass.
- Module D: Finance-only review queue and separate inactive delivery boundary. The Admin dashboard source is outside this repository, so its UI wiring remains with the owning product.
- Module E: booking holds, safe expiry, amendments, cancellations, no-shows, effective-dated rate policies, separate refund authorization, calendar reconciliation, and immutable audit. 43/43 rollback-only pgTAP assertions pass. A two-session collision test proved one overlapping hold wins and the other fails closed.
- Wave 2: private shared-inbox foundation with encrypted-body fields, redacted previews, deterministic escalation, named assignment, and human-reviewed advisory drafts. 31/31 rollback-only pgTAP assertions pass. Draft approval does not send or queue a message.
- Wave 3: private cleaning/meter evidence tied to the named cleaner, session, property, and matching meter reading. Named inspectors review evidence; only operations managers may override. 21/21 rollback-only pgTAP assertions pass.

The next local implementation is Wave 4: inventory forecasting and human purchase approval. Build an independently reversible migration, rollback-only pgTAP suite, source-boundary tests, dated validation record, and one clean commit. Forecasts and recommendations remain advisory. A named authorized human must approve a purchase, and no function may place a supplier order or invoke a provider.

After Wave 4, continue locally in order:
1. Wave 5 — Finance reconciliation and internal management analytics.
2. Wave 6 — CRM, consent, retention, and guest lifecycle.
3. Wave 7 — marketing drafts and exact-content human approval; no publication.
4. Wave 8 — consolidation, recovery drills, authority inventory, and operational handoff.

Non-negotiable boundaries:
- Supabase is canonical for every business fact and state transition.
- n8n is delivery/integration only. All 13 source-controlled workflows remain inactive.
- Finance/Admin and OPS remain strictly separate. OPS receives no money, payment, receipt, bank, rate, deposit, refund, or guest-contact data.
- AI, OCR, forecasts, classifications, and bank email are advisory only.
- Named human approval is mandatory for booking/payment confirmation, refunds, discounts, exceptions, cleaning overrides, purchases, and publication.
- The business is unregistered. Do not claim BIR, statutory, tax, or filing compliance.
- Do not deploy, apply production migrations, activate workflows or cron, configure providers, modify VPS/Docker configuration, or send messages without fresh action-time owner approval.
- Production remains frozen behind Module A: encrypted backup/restore proof, coordinated staff/RLS release, project Auth MFA/AAL2, real cleaner authorization checks, monitoring, and shared n8n recovery.

Local Docker Supabase was running during the completed validations. Database candidate tests were assembled with their migrations inside transactions ending in ROLLBACK; they did not alter the migration ledger or persist fixtures.

The worktree intentionally still contains old uncommitted Task Master setup files and a modified .gitignore. The owner explicitly chose to stop spending time on Task Master. Do not include these files in feature commits and do not make Task Master a prerequisite for continuing:
- .taskmaster/
- .env.example
- AGENTS.md
- docs/handoff/TASKMASTER.md
- scripts/taskmaster-codex.mjs
- scripts/taskmaster-schema.mjs
- tests/taskmaster/
- .gitignore changes related to that setup

Before each commit, stage only the files owned by the current wave, run focused tests and git diff --check, record exact evidence, and preserve all unrelated dirty files. Stop before every production or provider action.
```
