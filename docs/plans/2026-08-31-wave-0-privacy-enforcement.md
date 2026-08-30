# Wave 0 Privacy Enforcement Implementation Plan

**Goal:** Add an auditable, property-scoped database workflow for access, correction and deletion requests plus legal/dispute holds, without automatically deleting operational or financial records.

**Architecture:** Three private RLS-enabled tables store requests, holds and an append-only action trail. Authenticated owner/admin users enter three `security definer` RPCs; authorization is derived from DB-owned staff state, requires AAL2, enforces property scope for admins and rejects revoked/disabled sessions. Deletion remains a reviewed human action, and an active matching hold blocks approval or completion.

**Tech Stack:** PostgreSQL/Supabase migrations, DB-owned staff authorization, pgTAP, disposable Supabase recovery verification.

---

### Task 1: Define the failing privacy contract

**Files:**
- Create: `supabase/tests/database/privacy_requests_and_holds.sql`

- [x] **Step 1: Add structural and privilege assertions**

Create a rollback-scoped pgTAP file with assertions for:

```sql
select has_table('public', 'privacy_requests');
select has_table('public', 'privacy_holds');
select has_table('public', 'privacy_action_audit');
select has_function('public', 'create_privacy_request',
  array['uuid','text','text','text','text','text','text']);
select has_function('public', 'transition_privacy_request',
  array['uuid','text','text']);
select has_function('public', 'manage_privacy_hold',
  array['uuid','text','uuid','text','text','text','text']);
```

Assert RLS is enabled, `anon`, `authenticated` and `service_role` cannot directly select/insert/update/delete, only `authenticated` can execute the three guarded RPCs, and `privacy_action_audit` has no UPDATE or DELETE path.

- [x] **Step 2: Add authorization and lifecycle fixtures**

Inside the transaction, create two properties and three synthetic Auth/staff identities: an AAL2 property-scoped admin, an AAL2 finance user and a disabled admin. Assert:

```sql
select ok(public.staff_access_allowed('admin','manage_privacy',null,'aal2'));
select ok(not public.staff_access_allowed('admin','manage_privacy',null,'aal1'));
select ok(not public.staff_access_allowed('finance','manage_privacy',null,'aal2'));
```

Using DB-owned staff rows plus deliberately non-authoritative JWT metadata, prove the admin can create a request only for the assigned property, Finance cannot create one, and a disabled/revoked admin is denied immediately.

- [x] **Step 3: Add request/hold transition assertions**

Exercise these exact transitions:

```text
received -> identity_verified -> in_review -> approved -> completed
received -> cancelled
in_review -> on_hold -> in_review
in_review -> denied
```

Create an active `legal` hold matching a deletion request's property, subject kind and subject reference. Assert `approve` and `complete` fail with SQLSTATE `23514` while the hold is active, hold release is audited and does not automatically mutate the request, and `resume_review` succeeds only after every matching hold is released.

- [x] **Step 4: Run the focused test and observe RED**

Run:

```powershell
npx.cmd supabase test db supabase/tests/database/privacy_requests_and_holds.sql --local
```

Expected: non-zero because `privacy_requests`, `privacy_holds`, `privacy_action_audit` and their RPCs do not exist.

### Task 2: Implement the private privacy workflow

**Files:**
- Create: `supabase/migrations/20260831010000_privacy_requests_and_holds.sql`

- [x] **Step 1: Create the three tables**

Use these contracts:

```sql
create table public.privacy_requests (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  request_type text not null check (request_type in ('access','correction','deletion')),
  subject_kind text not null check (subject_kind in ('guest','staff','other')),
  subject_reference text not null check (char_length(subject_reference) between 1 and 200),
  contact_method text not null check (contact_method in ('email','phone','in_person','other')),
  scope text not null check (char_length(scope) between 3 and 2000),
  received_at timestamptz not null default now(),
  status text not null default 'received' check (status in
    ('received','identity_verified','in_review','on_hold','approved','denied','completed','cancelled')),
  identity_verified_at timestamptz,
  identity_verified_by uuid,
  decided_at timestamptz,
  decided_by uuid,
  responded_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.privacy_holds (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  subject_kind text not null check (subject_kind in ('guest','staff','other')),
  subject_reference text not null check (char_length(subject_reference) between 1 and 200),
  hold_type text not null check (hold_type in
    ('legal','dispute','chargeback','safety','tax_accounting','unresolved_payment')),
  reason text not null check (char_length(reason) between 3 and 2000),
  status text not null default 'active' check (status in ('active','released')),
  opened_by uuid not null,
  opened_at timestamptz not null default now(),
  released_by uuid,
  released_at timestamptz,
  release_reason text check (release_reason is null or char_length(release_reason) between 3 and 2000),
  check ((status = 'active' and released_by is null and released_at is null and release_reason is null)
      or (status = 'released' and released_by is not null and released_at is not null and release_reason is not null))
);

create table public.privacy_action_audit (
  id uuid primary key default extensions.uuid_generate_v4(),
  entity_type text not null check (entity_type in ('request','hold')),
  entity_id uuid not null,
  property_id uuid not null references public.properties(id) on delete restrict,
  actor_user_id uuid not null,
  action text not null,
  before_state jsonb not null default '{}'::jsonb,
  after_state jsonb not null default '{}'::jsonb,
  reason text not null check (char_length(reason) between 3 and 2000),
  created_at timestamptz not null default now()
);
```

Add indexes on request status/received time, hold subject/status and audit entity/time.

- [x] **Step 2: Close direct access and extend staff authorization**

Enable RLS on all three tables, create no direct policies, revoke all table privileges from `public`, `anon`, `authenticated` and `service_role`, and replace `staff_access_allowed(text,text,timestamptz,text)` so `manage_privacy` is AAL2-only and permitted only to `owner` and `admin`. Preserve every existing action/role decision unchanged.

- [x] **Step 3: Add guarded RPCs**

Implement these exact signatures as `security definer set search_path = ''`:

```sql
public.create_privacy_request(uuid,text,text,text,text,text,text) returns uuid
public.transition_privacy_request(uuid,text,text) returns jsonb
public.manage_privacy_hold(uuid,text,uuid,text,text,text,text) returns jsonb
```

Every RPC must require `auth.uid()`, `current_staff_authorized('manage_privacy', property_id)`, AAL2 through the shared decision helper, a reason of 3–2000 characters, row locking for transitions and one append-only audit row in the same transaction. Reject unknown actions with `22023`, invalid transitions or hold-blocked deletion with `23514`, and authorization failure with `42501`.

`manage_privacy_hold` supports only `create` and `release`; create requires property/subject/type, while release derives scope from the locked existing row. `transition_privacy_request` supports only `verify_identity`, `start_review`, `place_on_hold`, `resume_review`, `approve`, `deny`, `complete` and `cancel` according to Task 1's transition table.

- [x] **Step 4: Grant only RPC entry points**

Revoke all function execution from `public`, `anon`, `authenticated` and `service_role`, then grant only the three RPCs to `authenticated`. Keep the pure `staff_access_allowed` helper available only to `service_role` as before; retain the existing `current_staff_authorized` grant unchanged.

- [x] **Step 5: Run the focused test and observe GREEN**

Run:

```powershell
npx.cmd supabase db reset --local --no-seed
npx.cmd supabase test db supabase/tests/database/privacy_requests_and_holds.sql --local
```

Expected: all privacy assertions pass and the transaction rolls back its fixtures.

### Task 3: Verify recovery and regression boundaries

**Files:**
- Modify: `docs/plans/module-execution-queue.md`
- Modify: `docs/plans/HANDOFF-2026-08-30-sol-security-and-release-preflight.md`
- Modify: `C:/Users/Lloyd/Claude/Projects/Cascade/docs/plans/2026-08-28-cascade-plan-gap-review.md`

- [x] **Step 1: Run database and recovery verification**

```powershell
npm.cmd run test:recovery
npm.cmd run recovery:supabase -- --output <OS-temp>\cascade-wave0-privacy-evidence.json
```

Expected: the disposable ledger includes `20260831010000`, every database test file passes, the active stack identity is unchanged, cleanup is empty and no production connection is used.

- [x] **Step 2: Run security and release regression checks**

```powershell
node scripts/audit/scan-secrets.mjs
node --test tests/security/endpoint-boundaries.test.mjs
npm.cmd run test:release-safety
node scripts/audit/compare-supabase-production.mjs --check
git diff --check
```

Expected: every command exits zero. No production deployment, n8n activation, Telegram/email message or privacy deletion occurs.

- [x] **Step 3: Update status documents**

Mark Wave 0.10 schema enforcement complete locally, record the migration/test counts, and retain these gates: current Philippine privacy/legal review, reversible staging proof, owner MFA/real staff cutover and explicit production approval.

- [x] **Step 4: Commit**

```powershell
git add docs/plans/2026-08-31-wave-0-privacy-enforcement.md docs/plans/HANDOFF-2026-08-30-sol-security-and-release-preflight.md docs/plans/module-execution-queue.md docs/validation/2026-08-31-wave-0-privacy-enforcement.md supabase/migrations/20260831010000_privacy_requests_and_holds.sql supabase/releases/20260831_privacy_enforcement.release.json supabase/tests/database/privacy_requests_and_holds.sql tests/migrations/release-safety.test.mjs
git commit -m "feat(cascade): add privacy request and hold controls"
```

### Completion evidence

- Request and hold records are private by default and cannot be changed through direct client table access.
- Only active, non-revoked owner/admin sessions at AAL2 can enter the RPCs; admins remain property-scoped.
- Every request/hold transition is append-only audited in the same transaction.
- An active matching hold prevents approval/completion of deletion requests.
- No migration automatically deletes, anonymizes or releases operational, financial, safety or audit data.
- Disposable recovery and the full security/release regression matrix remain green.
