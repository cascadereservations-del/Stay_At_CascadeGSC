# Wave 0 Recovery Proof Implementation Plan

**Goal:** Prove that Cascade's versioned n8n workflows and Supabase migrations can be rebuilt in disposable local runtimes without activating workflows or altering the active `direct-booking` Supabase stack.

**Architecture:** Two fail-closed Node CLIs create uniquely prefixed temporary resources. The n8n proof imports all source-controlled workflow JSON into a disposable SQLite-backed n8n volume, exports them again, and compares normalized inactive definitions. The Supabase proof copies only the versioned `supabase/` tree to a temporary project with different ports and project ID, starts database-only services, resets from migrations, compares the migration ledger, proves the active database container identity did not change, and removes only resources bearing the disposable prefix.

**Tech Stack:** Node.js built-ins, Docker Desktop, pinned `n8nio/n8n:2.34.6`, Supabase CLI 2.116.0, PowerShell/npm command wrappers, Node test runner.

---

### Task 1: Recovery contract and workflow comparison

**Files:**
- Create: `scripts/recovery/recovery-contract.mjs`
- Create: `tests/recovery/recovery-contract.test.mjs`

- [x] Write a failing test importing `inventoryWorkflowFiles`, `normalizeWorkflow`, `compareWorkflowSets`, `assertDisposableProjectId`, and `rewriteDisposableSupabaseConfig`; require unique workflow names, inactive definitions, semantic round-trip equality, a `cascade-recovery-` project prefix, different ports, and disabled seed execution.
- [x] Run `node --test tests/recovery/recovery-contract.test.mjs`; expect `ERR_MODULE_NOT_FOUND`.
- [x] Implement the five functions with Node built-ins only. Workflow comparison must ignore n8n-generated IDs/timestamps while retaining names, nodes, connections, settings, tags and inactive state. Configuration rewriting must fail unless every expected source value is found exactly once.
- [x] Rerun the focused test; expect all contract tests to pass.

### Task 2: Disposable n8n workflow restore

**Files:**
- Create: `scripts/recovery/verify-n8n-restore.mjs`
- Modify: `tests/recovery/recovery-contract.test.mjs`

- [x] Add failing subprocess tests for an invalid source directory and for refusal to clean a volume without the `cascade-n8n-recovery-` prefix.
- [x] Run the focused test and observe non-zero failures because the CLI does not exist.
- [x] Implement the CLI to create a prefixed Docker volume and OS temporary directory, import `automation/n8n/workflows/*.json` with `--activeState=false`, export all workflows separately, compare normalized definitions, record the pinned image digest/count/hash, and clean only its prefixed volume/temp directory in `finally`.
- [x] Run `node scripts/recovery/verify-n8n-restore.mjs --output <temporary-evidence-path>`; expect 13 imported/exported inactive workflows and zero persistent containers.

### Task 3: Disposable Supabase migration rebuild

**Files:**
- Create: `scripts/recovery/verify-supabase-reset.mjs`
- Modify: `tests/recovery/recovery-contract.test.mjs`

- [x] Add failing subprocess tests proving `--project-id direct-booking` and any ID without `cascade-recovery-` are refused before Docker access.
- [x] Run the focused test and observe non-zero failures because the CLI does not exist.
- [x] Implement the CLI to snapshot `supabase_db_direct-booking` identity, copy the versioned `supabase/` directory to OS temp, rewrite project ID/database ports/seed setting, start database-only Supabase services, run `db reset --local --no-seed`, compare every source migration version with the disposable ledger, prove the active database ID/start time is unchanged, and stop only the validated disposable project with `--no-backup` in `finally`.
- [x] Run the CLI with a generated prefixed ID; expect all source migration versions in the disposable ledger, unchanged active-container identity, and no remaining disposable container.

### Task 4: Recovery evidence and Wave 0 disposition

**Files:**
- Create: `docs/validation/2026-08-30-wave-0-recovery-report.md`
- Modify: `package.json`
- Modify: `docs/plans/module-execution-queue.md`
- Modify: `docs/plans/HANDOFF-2026-08-30-sol-security-and-release-preflight.md`
- Modify: `C:/Users/Lloyd/Claude/Projects/Cascade/docs/plans/2026-08-28-cascade-plan-gap-review.md`

- [x] Add `test:recovery`, `recovery:n8n`, and `recovery:supabase` scripts.
- [x] Run the contract tests, real n8n restore, real disposable Supabase reset, source-to-deployment comparison, workflow graph validator, Finance/OPS boundary tests, static secret scan, release-safety tests, and `git diff --check`.
- [x] Record UTC timestamps, exact sanitized commands, expected/actual results, image/CLI versions, active-stack non-interference evidence, cleanup proof, and unresolved shared-Portainer credential/database backup risk. Do not include credentials, raw environment values or generated local keys.
- [x] Mark Wave 0.8 locally complete only if both disposable proofs pass. Keep production recovery readiness gated until an owner-approved shared-Portainer backup and restore exercise exists.
- [x] Commit repository changes with `test(cascade): prove disposable recovery gates`; retain the main gap-review update in its owning workspace because that root is not a Git repository.

### Completion evidence

- All 13 source-controlled workflows round-trip through the pinned n8n CLI and remain inactive.
- A differently named Supabase database container rebuilds from every versioned migration while the active `supabase_db_direct-booking` container ID and start time remain unchanged.
- Disposable resources are removed using validated prefixes; the scripts never call `supabase stop --all`, publish a workflow, start the n8n web service, or connect to production.
- The production source inventory reports all 21 deployed functions as recovered or versioned.
- The report explicitly distinguishes source-level recoverability from the still-unproven backup of the shared Portainer n8n database, credentials and encryption key.
