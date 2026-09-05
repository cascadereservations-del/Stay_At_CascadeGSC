# Copy/Paste Resume Prompt for the Next Developer

```text
Continue the Cascade Hideaway business-system project from:
C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol

Start by running:
- git status --short
- git log -7 --oneline

Then read, in order:
1. HANDOFF.md
2. docs/handoff/COMPLETE-HANDOFF-2026-09-06.md
3. docs/handoff/CURRENT-STATE.md
4. docs/handoff/DEVELOPMENT-PLAYBOOK.md
5. docs/plans/2026-09-06-portainer-n8n-completion-plan.md
6. docs/plans/module-execution-queue.md
7. docs/architecture/adr-002-dedicated-hetzner-cascade-operations.md
8. docs/runbooks/cascade-n8n-deploy.md
9. docs/validation/2026-09-06-alfred-detailed-capacity-audit.md
10. docs/validation/2026-09-05-wave-8-consolidation-handoff.md

Current branch: codex/cascade-waves-0-1-sol
Expected latest completed commit at handoff: the Portainer CE + n8n decision, updated completion plan, and 2026-09-06 handoff. Verify it from Git rather than relying on a copied SHA.

Selected hosting decision:
- Use Alfred's existing Docker Engine and Portainer CE to manage a separate capped `cascade-n8n` Compose project with its own PostgreSQL database.
- Do not add a second Docker daemon, replace Alfred's existing n8n, or share its volumes, database, keys, credentials, networks, hostname, or backups.
- This adds no subscription. A separate Cascade VPS remains the fallback if a pre-start or 72-hour dormant-soak threshold fails.
- The platform choice is approved; no server, stack, swap, DNS, secret, provider, workflow, or production action has happened or is implied.

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
1. Execute Phase P1 locally: complete the redacted recovery/deployment packet, including Alfred's existing n8n disposable restore, action-time n8n image/security review, rendered capped Compose, secrets/proxy plan, exact smoke/abort checks, and rollback.
2. Present the concrete P2/P3 action packet before adding at least 2 GiB swap or creating the dormant stack. Re-run the host baseline after swap.
3. Import all 13 workflows inactive without provider credentials, prove the new stack's encrypted restore, and complete a 72-hour dormant soak.
4. Close every Module A production gate before releasing Modules B–E or Waves 2–7.
5. Continue phases P6–P10 from docs/plans/2026-09-06-portainer-n8n-completion-plan.md. Activate only one separately approved provider/workflow batch at a time.

Non-negotiable boundaries:
- Supabase is canonical for every business fact and state transition.
- n8n is delivery/integration only. All 13 source-controlled workflows remain inactive.
- Finance/Admin and OPS remain strictly separate. OPS receives no money, payment, receipt, bank, rate, deposit, refund, or guest-contact data.
- AI, OCR, forecasts, classifications, and bank email are advisory only.
- Named human approval is mandatory for booking/payment confirmation, refunds, discounts, exceptions, cleaning overrides, purchases, and publication.
- The business is unregistered. Do not claim BIR, statutory, tax, or filing compliance.
- Do not deploy, apply production migrations, activate workflows or cron, configure providers, modify VPS/Docker configuration, or send messages without fresh action-time owner approval.
- Do not add swap or deploy the Cascade stack on Alfred without the recovery, capacity, and action-time approval gates. Do not activate it for business delivery until the dormant-soak and Module A gates pass.
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

Before each commit, stage only the files owned by the current phase, run focused tests and git diff --check, record exact evidence, and preserve all unrelated dirty files. Stop before every server mutation, production action, provider action, message, order, or publication.
```
