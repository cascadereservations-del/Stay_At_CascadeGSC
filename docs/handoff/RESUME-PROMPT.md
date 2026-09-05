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
9. docs/validation/2026-09-05-wave-4-inventory-purchase.md
10. docs/validation/2026-09-05-wave-5-finance-analytics.md
11. docs/validation/2026-09-05-wave-6-crm-lifecycle.md
12. docs/validation/2026-09-05-wave-7-selective-marketing.md
13. docs/validation/2026-09-05-wave-8-consolidation-handoff.md

Current branch: codex/cascade-waves-0-1-sol
Expected latest completed commit at handoff: the Wave 8 consolidation and operational-handoff candidate. Verify it from Git rather than relying on a copied SHA.

Completed local candidates:
- Module B: canonical atomic booking decision.
- Module C: advisory payment evidence and named Finance review; 47/47 rollback-only pgTAP assertions pass.
- Module D: Finance-only review queue and separate inactive delivery boundary. The Admin dashboard source is outside this repository, so its UI wiring remains with the owning product.
- Module E: booking holds, safe expiry, amendments, cancellations, no-shows, effective-dated rate policies, separate refund authorization, calendar reconciliation, and immutable audit. 43/43 rollback-only pgTAP assertions pass. A two-session collision test proved one overlapping hold wins and the other fails closed.
- Wave 2: private shared-inbox foundation with encrypted-body fields, redacted previews, deterministic escalation, named assignment, and human-reviewed advisory drafts. 31/31 rollback-only pgTAP assertions pass. Draft approval does not send or queue a message.
- Wave 3: private cleaning/meter evidence tied to the named cleaner, session, property, and matching meter reading. Named inspectors review evidence; only operations managers may override. 21/21 rollback-only pgTAP assertions pass.
- Wave 4: inventory reconciliation, recorded-usage forecasts and named AAL2 owner/admin shopping-list review. Five source checks and all 31 rollback-only pgTAP assertions pass. A disposable two-session proof showed review waited for a concurrent stock change, then failed closed as stale; the compensating rollback passed. Purchase review never orders or invokes a provider.
- Wave 5: named AAL2 Finance reconciliation creates immutable facts from deterministic paired-source comparisons. Internal metrics and effective owner targets pass 50/50 rollback-only pgTAP assertions and a compensating rollback. OPS has no access; reports make no statutory/tax claim.
- Wave 6: hashed identity resolution, separate purpose consent, lifecycle/recovery events, and retention controls pass 31/31 rollback-only pgTAP assertions and a compensating rollback. Eligibility never authorizes communication or publication.
- Wave 7: consent-gated ciphertext drafts and named AAL2 review pass 33/33 rollback-only pgTAP assertions and a compensating rollback. Approval binds the exact content hash and explicit targeting/discount/claim scope; publication remains unauthorized.
- Wave 8: a machine-checkable authority inventory, local operating handoff, and gated dedicated-Hetzner direction pass consolidation checks. Disposable recovery round-tripped 13 n8n workflows inactive and rebuilt Supabase through 38 migrations and 26 database test files without changing the active local database.

Next gated work:
1. Review the Wave 8 evidence and dedicated Hetzner decision.
2. With target access available, perform only the fresh read-only Hetzner capacity and collision preflight.
3. Close the Module A and migration gates before any VPS, Docker, DNS, secret, workflow, provider, or production change.

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
