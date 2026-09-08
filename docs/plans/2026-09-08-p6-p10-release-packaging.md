# P6–P10 release packaging — analysis, contracts written, and what actually blocks each phase

**Date:** 2026-09-08 · **Branch:** `codex/cascade-waves-0-1-sol` · **Source commit:** `a0bf38f`

The plan's approval column said "staged approvals" for P6 through P10, but nobody had ever
established *what* would be staged. This document is the answer: an exact inventory of the
unapplied migrations, three release contracts written and validated, and the specific reason each
remaining phase cannot proceed today.

## 1. What is actually unapplied

81 migration files exist locally; 68 versions are recorded in
`supabase_migrations.schema_migrations`. **13 are genuinely unapplied**, plus one ledger drift.

| Migration | Batch | Contract |
|---|---|---|
| `20260828000300_job_heartbeats` | platform | `20260908_platform_heartbeats` ✅ |
| `20260830070000_fix_price_history_view_recursion` | platform | `20260908_platform_heartbeats` ✅ |
| `20260831010000_privacy_requests_and_holds` | P8 unit 1 | `20260831_privacy_enforcement` (pre-existing) |
| `20260901010000_canonical_booking_decision` | P6 | **none — see §3** |
| `20260905010000_payment_evidence_finance_review` | P6 | **none — see §3** |
| `20260905020000_payment_review_queue` | P6 | **none — see §3** |
| `20260905030000_booking_lifecycle` | P6 | **none — see §3** |
| `20260905050000_cleaning_meter_verification` | P7 | `20260908_p7_operations_insight` ✅ |
| `20260905060000_inventory_forecast_purchase_review` | P7 | `20260908_p7_operations_insight` ✅ |
| `20260905070000_finance_reconciliation_analytics` | P7 | `20260908_p7_operations_insight` ✅ |
| `20260905040000_guest_shared_inbox` | P8 | `20260908_p8_guest_lifecycle` ✅ |
| `20260905080000_crm_consent_lifecycle` | P8 | `20260908_p8_guest_lifecycle` ✅ |
| `20260905090000_selective_marketing_review` | P8 | `20260908_p8_guest_lifecycle` ✅ |
| `20260824045800_dispatch_w01_to_n8n` | P9 | deliberately unapplied (D-022, D-028) |

**Ledger drift.** The local file is `20260908000200_staff_users_service_grants.sql`; production
recorded the same change as version `20260908021745`. Same content, different version string, so
every ledger comparison will report a phantom missing migration until one side is renamed. Worth
fixing before any preflight result is trusted.

## 2. The ordering hazard — the most important finding

`public.staff_access_allowed(text,text,timestamptz,text)` is redefined by **four** migrations, and
each body is a strict superset of the one before it:

| Migration | Adds | Live? |
|---|---|---|
| `20260828000500_db_backed_operational_authorization` | baseline actions | ✅ applied |
| `20260831010000_privacy_requests_and_holds` | `manage_privacy` | ❌ |
| `20260905030000_booking_lifecycle` | `manage_booking`, `approve_refund`, `publish_rate_policy` | ❌ |
| `20260905040000_guest_shared_inbox` | `manage_guest_inbox` | ❌ |

Because each is a full `create or replace`, **applying them out of timestamp order silently
removes actions**. Apply P6 first and the privacy release second, and `manage_booking`,
`approve_refund` and `publish_rate_policy` vanish — with no error, no failed migration, and no
symptom until someone tries to approve a refund. Every operational endpoint reaches this function
through `current_staff_authorized`, so the blast radius is the whole staff authority model.

Every contract written here carries this as an explicit stop condition, and each has a forward
check named `earlier_authority_actions_survive_the_function_replacement` that fails loudly if an
earlier action was dropped. **Apply strictly in timestamp order.**

## 3. Why P6 has no contract yet

`20260905010000_payment_evidence_finance_review` contains:

```sql
alter function public.decide_direct_booking(uuid,text,text)
  rename to decide_direct_booking_without_finance_review;
```

It renames the function that `20260901010000` creates one migration earlier — Module C superseding
Module B's unreviewed entry point. `scripts/migrations/verify-expand-contract.mjs` correctly
rejects that as `destructive SQL is not allowed in expand phase (RENAME TABLE/COLUMN)`, so the four
P6 migrations cannot ship as an `expand` release.

They also cannot ship as a `contract` release yet: `validateReleaseContract` requires
`compatibility.verified: true` for that phase, and verifying compatibility honestly means running
the pgTAP files in `supabase/tests/database/` (`canonical_booking_decision.sql`,
`payment_evidence_finance_review.sql`, `payment_review_queue.sql`, `booking_lifecycle.sql`) against
a disposable database. **That needs a local Postgres, which needs Docker, which is not installed.**

Writing a contract with `verified: true` on the strength of a static read would be exactly the kind
of unearned assurance this tooling exists to prevent. So P6 stays unpackaged, deliberately, with a
one-line unblock: repair Docker, run the four pgTAP files, then write the contract-phase release.

## 4. The root blocker, stated once

`C:\Program Files\Docker\Docker\Docker Desktop.exe` is absent while the orphaned CLI remains
(`docker version` → client 28.1.1, engine pipe missing). That single fact blocks:

- `npm run preflight:local` for **every** release contract, including the three written today;
- the pgTAP rehearsal that `compatibility.verified: true` requires, and therefore P6 entirely;
- the disposable-restore proof that would let the 2026-09-08 backup claim a `restore_proof`.

Repair means downloading and installing signed workstation software — an owner decision, and the
subject of `2026-09-06-workstation-docker-repair-packet.md`. Everything else in P6–P8 is now
packaged and waiting on it.

## 5. Per-phase status after this session

| Phase | Contract | Blocked on |
|---|---|---|
| P6 — core booking | none | the rename above → Docker → pgTAP rehearsal → contract-phase release |
| P7 — operations and insight | `20260908_p7_operations_insight` ✅ validated | owner approval, real-role smoke test, `preflight:local` (Docker) |
| P8 — guest lifecycle | `20260831_privacy_enforcement` + `20260908_p8_guest_lifecycle` ✅ validated | privacy review, owner approval, ordering behind P6 |
| P9 — provider activation | n/a | creating `Cascade — <provider/purpose>` credentials, which an agent may not do |
| P10 — operational acceptance | n/a | follows P6–P9 |
| platform | `20260908_platform_heartbeats` ✅ validated | owner approval only — the lowest-risk batch by a wide margin |

## 6. Gaps and improvements found along the way

1. **`record_job_heartbeat` does not exist in production.** `turnover-verifier` v10 calls it on
   every run and logs a warning each time. The `20260828000300` migration that creates it has been
   sitting unapplied since 2026-08-28. This is why the platform contract exists and why it is the
   recommended first release: smallest surface, immediate observability payoff.
2. **`price_history_by_item` is broken in production right now.** The live view selects from
   itself and raises `42P17` on every read. The fix has been sitting unapplied since 2026-08-30.
   Rolling that fix back would restore a broken view, which the contract says explicitly.
3. **The endpoint authority manifest had drifted** — `staff-users` was deployed during Module A
   without a manifest entry, so `tests/security/endpoint-boundaries.test.mjs` failed. Fixed in
   `a0bf38f`; platform-safety is 37/37 again.
4. **`preflight:local` can no longer run without `--release`.** It errors with "expected exactly
   one release contract, found 2" — and there are now five. Every future invocation must name its
   contract. Worth either a package script per release or an `--all` mode.
5. **Ledger drift** between `20260908000200` and `20260908021745` (see §1) will make any automated
   ledger comparison report a false positive.
6. **The unapplied W01 dispatch migration** (`20260824045800`) is deliberately excluded per D-022
   and D-028 — the trigger is already live in production by another path. Anyone running a naive
   "apply everything unapplied" script would re-introduce it. That is a good reason never to write
   such a script.

## 7. Recommended order when the gates clear

1. `20260908_platform_heartbeats` — smallest, fixes two live defects, no authority change.
2. `20260831_privacy_enforcement` — additive, owner MFA already satisfied, needs privacy review.
3. P6 contract-phase release — after Docker and the pgTAP rehearsal.
4. `20260908_p7_operations_insight` — needs a real-role smoke test.
5. `20260908_p8_guest_lifecycle` — strictly last of the four, because it carries the widest
   authority function body.

Re-run every contract's forward verification after **each** step, not once at the end. The
authority function makes each release capable of silently undoing the one before it.
