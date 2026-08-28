# Wave 0 Task 0.2 Packet — Recover Deployed Edge Function Source

## Starting point

- Repository: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- Starting commit: `c3a8be8`
- Production project: `qkgfhsdppslwunarczeq`

## Preconditions

- `node scripts/audit/compare-supabase-production.mjs --check` reports exactly 12 `missing-source` functions.
- Download only these missing slugs: `airbnb-email-sync`, `daily-digest`, `last-readings`, `missed-cleaning-alert`, `notify-cleaner-payment`, `ocr-receipt`, `rain-alert`, `submit-cleaning`, `telegram-expense`, `turnover-verifier`, `upload-photo`, `weather-proxy`.
- Do not download all functions because that could overwrite nine reviewed local sources.
- Use `--use-api` so Docker is not required.
- Do not deploy, refactor, reformat or activate anything.

## Recovery procedure

For each missing slug, confirm `supabase/functions/<slug>` does not exist, then run:

```powershell
npx.cmd --yes supabase functions download <slug> --project-ref qkgfhsdppslwunarczeq --use-api
```

The download is treated as generated recovery rather than new production behavior. Record each downloaded source-tree SHA-256 beside the separately observed deployment bundle hash. Do not claim the two hash forms are directly comparable.

Create `docs/validation/recovered-function-hashes.md` with version, JWT setting, deployment bundle hash, local tree hash and verification status. Add all successfully recovered slugs to `recovered_slugs` in `docs/architecture/production-contract.json`.

## Verification

```powershell
node --test tests/production-contract.test.mjs
node scripts/audit/compare-supabase-production.mjs --check
deno check supabase/functions/telegram-expense/index.ts
deno check supabase/functions/submit-cleaning/index.ts
deno check supabase/functions/turnover-verifier/index.ts
```

Expected: 21 deployed functions classified as 9 `versioned` and 12 `recovered`, with no missing-source block. If Deno is unavailable, record that toolchain blocker and do not claim type-check completion.

## Forward verification and rollback

- Forward: repeat the safe function list and confirm slug/version/deployment hash still match the frozen contract.
- Smoke: no original nine function directories changed; every recovered directory contains `index.ts`.
- Rollback: revert only this recovery commit; no production state was changed.
- Stop if a download targets an existing directory, a live version/hash changes mid-recovery, or the API returns a different slug.

## Commit

```powershell
git add docs/plans/packets/wave-0-0.2-recover-deployed-functions.md docs/architecture/production-contract.json docs/validation/recovered-function-hashes.md supabase/functions
git commit -m "chore(cascade): recover deployed edge function sources"
```
