# Module A Production Cutover Implementation Plan

**Goal:** Safely close the remaining Module A production gates for staff authorization, cleaner access, privacy/release controls, heartbeat readiness and shared n8n recovery without activating guest/provider workflows.

**Architecture:** The release applies the reviewed additive Supabase staff/cleaner packet only during an owner-MFA-proven maintenance window. Supabase remains authoritative; existing Portainer n8n remains inactive and is tested only through an owner-approved backup/restore exercise. Every transition is evidence-backed, fail-closed and reversible through the declared rollback/restore procedure.

**Tech Stack:** Supabase Auth/Postgres/RLS/Edge Functions/Storage, existing Portainer n8n, Docker, Uptime Kuma, Node release scripts, pgTAP, Playwright.

---

## Preconditions — do not start the production window unless all are true

- A named owner is present and approves the exact cutover window.
- The feature branch is clean and reviewed at the approved immutable source commit.
- `docs/validation/2026-08-31-module-a-readiness-refresh.md` is reviewed alongside the existing release/recovery evidence.
- A rollback operator and a production-native backup/restore facility are available.
- No provider message, calendar write, n8n workflow publication, or automated delivery is included in this cutover.

### Task 1: Freeze and prove the approved source

**Files:**
- Read: `supabase/releases/20260830_staff_cleaner_cutover.release.json`
- Read: `docs/runbooks/database-release.md`
- Read: `docs/validation/2026-08-31-module-a-readiness-refresh.md`

- [ ] **Step 1: Confirm branch cleanliness and immutable source ancestry.**

```powershell
Set-Location 'C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol'
git status --short
node scripts/migrations/verify-expand-contract.mjs --release supabase/releases/20260830_staff_cleaner_cutover.release.json
npm.cmd run preflight:local -- --release supabase/releases/20260830_staff_cleaner_cutover.release.json
```

Expected: empty `git status --short`; contract verifier and local preflight exit 0.

- [ ] **Step 2: Capture the approved commit outside chat.**

```powershell
git rev-parse HEAD
git log -1 --oneline
```

Expected: the owner records the checked-out commit in the production release record. It must descend from the source commit declared by the release JSON, and the release verifier must confirm the locked migration hashes. Later documentation/evidence commits do not invalidate the payload; a changed migration, client artifact, or verifier failure does.

- [ ] **Step 3: Commit any action-time evidence before production work.**

```powershell
git add docs/validation/<dated-evidence-file>.md
git commit -m "docs(cascade): record module a cutover preflight"
```

Expected: evidence is committed before the production operator applies the release. Do not place tokens, backup IDs, personal data or raw logs in the file.

### Task 2: Secure the dashboard operator and prepare named-user scope

**Files:**
- Read: `supabase/migrations/20260828000400_staff_roles_and_sessions.sql`
- Read: `supabase/functions/staff-access/`
- Read: `docs/runbooks/staff-access-lifecycle.md`
- Test: `supabase/tests/database/staff_roles_and_sessions.sql`

- [x] **Step 1: Enroll the Supabase dashboard owner in TOTP through the approved account-security UI.**

Expected: the owner completes dashboard-account TOTP personally; do not copy recovery codes or MFA secrets into a terminal, repository, or chat. This protects the administrative console but is not an application `aal2` claim.

- [x] **Step 2: Confirm the application identity gate remains unfulfilled until the coordinated release.**

Expected: before the staff migration is applied, the Cascade project has no database-owned staff owner and no project Auth TOTP factor. Do not treat dashboard MFA as a substitute.

- [ ] **Step 3: Record the intended minimum access scopes without creating access early.**

Expected: plan one named project Auth owner and one named cleaner. The cleaner will receive only the `cleaner` role and exactly the intended Cascade `property_id`; no Finance/Admin permission is granted. Do not bootstrap either role until Task 3 has a fresh restore point and its migrations are live.

### Task 3: Perform the coordinated staff/RLS/named-cleaner release

**Files:**
- Read: `supabase/releases/20260830_staff_cleaner_cutover.release.json`
- Read: `docs/runbooks/database-release.md`
- Read: `supabase/migrations/20260828000200_operational_rls_lockdown.sql`
- Read: `supabase/migrations/20260828000300_job_heartbeats.sql`
- Read: `supabase/migrations/20260828000400_staff_roles_and_sessions.sql`
- Read: `supabase/migrations/20260830002347_named_cleaner_access_boundary.sql`

- [ ] **Step 1: Capture fresh production backup and migration-ledger evidence using approved Supabase tooling.**

Expected: a production-native restore point exists in the current cutover window; its identifier is retained in the approved operations record, not in Git/chat. Stop if the migration ledger differs from the release contract baseline.

- [ ] **Step 2: Confirm feature-gate prerequisites match the release JSON.**

Expected: old/new reader and writer compatibility is exactly as declared. Stop if a client cannot follow the backend change in the staffed window.

- [ ] **Step 3: Apply only the ordered migration set in the reviewed release contract through the approved production migration mechanism.**

Expected: each applied ledger version and forward-verification query matches the expected scalar result. Stop at the first mismatch; do not edit deployed migrations or force-mark history.

- [ ] **Step 4: Create the first named Cascade project Auth owner, bootstrap it from a database-owner session, then enroll project TOTP and issue a fresh session.**

Expected: create or use a pre-existing project Auth user through the approved project Auth administration flow; bootstrap that exact user with `bootstrap_cascade_owner` from a database-owner session; then the owner personally completes the **project** TOTP flow. The staff-access/status endpoint must report the authenticated owner and `aal2`; record only pass/fail and timestamp in release evidence. Do not put an email address, MFA secret, user UUID or recovery code in Git/chat.

- [ ] **Step 5: Create the real cleaner identity and property assignment from the new owner project-AAL2 session.**

Expected: cleaner receives the least-privilege role and exactly the intended Cascade `property_id`; no Finance/Admin permission is granted.

- [ ] **Step 6: Deploy the compatible authenticated cleaner client/backend artifacts in the documented order.**

Expected: backend and client move together; no anonymous fallback is enabled to keep an old client working.

- [ ] **Step 7: Run the role-scope smoke matrix with synthetic/non-financial data.**

```text
Cleaner: sign in → read own property → read prior meter → upload private test photo → submit test report → create pending expense claim → sign out.
Disabled cleaner: sign in/read/write must be denied.
Stale session: write must be denied.
Other-property attempt: read/write must be denied.
```

Expected: allowed cleaner actions succeed only for assigned property; all denied cases fail closed; test photos/fixtures are removed through the documented cleanup route.

- [ ] **Step 8: Commit the release evidence.**

```powershell
git add docs/validation/<dated-production-cutover-evidence>.md
git commit -m "docs(cascade): record staff cleaner production cutover"
```

Expected: evidence contains timestamps, release commit, result summaries and rollback decision, but no secrets or personal data.

### Task 4: Establish heartbeat/liveness readiness without accidental activation

**Files:**
- Read: `supabase/functions/job-heartbeat-monitor/`
- Read: `supabase/functions/job-heartbeat-liveness/`
- Read: `docs/runbooks/scheduler-recovery.md`
- Test: `supabase/tests/database/job_heartbeats.sql`

- [ ] **Step 1: Create the two required scheduler/liveness secrets through the approved Vault/secret manager.**

Expected: values are never displayed, exported, committed or sent through chat.

- [ ] **Step 2: Deploy heartbeat components with schedules disabled.**

Expected: signed endpoint/authentication smoke check passes, but no periodic job, Uptime Kuma monitor, Telegram delivery or provider action is activated yet.

- [ ] **Step 3: Obtain separate owner approval to activate schedules and the Uptime Kuma monitor.**

Expected: activation is a distinct decision because it changes runtime behaviour.

- [ ] **Step 4: Verify one synthetic missed-run path routes only a reason-safe operational alert.**

Expected: no Finance amount, receipt, bank reference or guest contact information appears in OPS output.

### Task 5: Prove shared Portainer n8n recovery and credential separation

**Files:**
- Read: `docs/runbooks/n8n-live-baseline-2026-08-29.md`
- Read: `docs/runbooks/cascade-n8n-deploy.md`
- Read: `automation/n8n/README.md`
- Test: `scripts/check-n8n-workflows.mjs`

- [ ] **Step 1: Sign in to the existing n8n editor with the owner present and take a backup of the shared n8n data, credential ciphertext, encryption key and Cascade workflow set.**

Expected: backup is encrypted and copied to the approved external location. Do not expose credentials in the editor export, terminal, Git or chat.

- [ ] **Step 2: Restore the backup into a disposable recovery environment, never the shared runtime.**

Expected: credential decryption and Cascade workflow availability are proven; no workflow is activated and no provider nodes execute.

- [ ] **Step 3: Verify Cascade credential naming and separation.**

```text
Every Cascade workflow references only credentials named “Cascade — <provider/purpose>”.
No Alfred/Alex credential is referenced.
Finance templates cannot route to OPS.
```

Expected: pass/fail evidence only. If separation cannot be enforced, leave shared n8n inactive and invoke the ADR’s isolated-runtime reassessment trigger.

- [ ] **Step 4: Resolve duplicate W01 drafts without publishing either draft.**

Expected: export/rename/archive cleanup is performed one workflow at a time with owner approval; the unsafe OPS-payment draft remains unpublished.

### Task 6: Close Module A and authorize Module B planning

**Files:**
- Modify: `docs/plans/2026-08-31-cascade-system-plan-status-and-architecture.md`
- Modify: `docs/handoff/CURRENT-STATE.md`
- Modify: `docs/handoff/cascade-system-plan.html`
- Create: `docs/validation/<dated-module-a-closeout>.md`

- [ ] **Step 1: Compare every acceptance criterion in Tasks 1–5 with attached evidence.**

Expected: each is marked pass, fail, or still gated. A missing evidence item means Module A stays gated.

- [ ] **Step 2: Update plan/handoff status truthfully.**

Expected: replace “gated” with “complete” only when all production gates have evidence; otherwise retain exact blockers and dates.

- [ ] **Step 3: Run final local controls.**

```powershell
npm.cmd run test:platform-safety
node scripts/check-n8n-workflows.mjs
node scripts/audit/scan-secrets.mjs
git diff --check
```

Expected: all commands exit 0.

- [ ] **Step 4: Commit closeout and request fresh approval for Module B only after Module A is fully evidenced.**

```powershell
git add docs/plans docs/handoff docs/validation
git commit -m "docs(cascade): close module a evidence"
```

Expected: Module B begins as a separate reviewed workstream; it does not inherit permission to publish workflows or send provider messages.

## Coverage review

- Owner MFA and cleaner property scope: Task 2.
- Backup, ledger, release contract, RLS and compatible client cutover: Task 3.
- Scheduler/liveness secrets and safe activation: Task 4.
- Shared n8n restore, credential separation and W01 cleanup: Task 5.
- Accurate plan/handoff and controlled transition to Module B: Task 6.

No task authorizes an uncontrolled production action. This plan is executable only with the listed fresh owner approvals and approved operational tooling.
