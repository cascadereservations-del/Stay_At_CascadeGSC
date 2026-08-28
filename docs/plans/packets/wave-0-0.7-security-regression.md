# Wave 0 Task 0.7 Packet — Security regression gates

Starting commit: `574783e` on `codex/cascade-waves-0-1-sol`.

The failing contract is that every deployed/local Edge Function must have one explicit authority mode, compensating controls and an owner; high-confidence credentials must never appear in tracked or unignored source. A recovered endpoint that is not yet safe is `migration_blocked`, not falsely classified as public.

Run:

```powershell
node --test tests/security/endpoint-boundaries.test.mjs
node scripts/audit/scan-secrets.mjs
node scripts/audit/check-edge-auth.mjs
node scripts/check-n8n-workflows.mjs
```

CI runs content, browser, Deno, n8n, secret, auth-boundary and local Supabase tests. Production deployment remains separate and requires the blocked endpoints to be hardened, staged and approved.
