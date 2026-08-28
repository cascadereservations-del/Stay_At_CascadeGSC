# Wave 0 Task 0.2a Packet — Stabilize Recovered Source Type Checks

## Starting point

- Repository: `C:\Users\Lloyd\Claude\Projects\Cascade\direct-booking-waves-0-1-sol`
- Branch: `codex/cascade-waves-0-1-sol`
- Starting commit: `afab977`

## RED evidence

`telegram-expense` fails Deno 2.9.5 with two `TS2769` overload errors when Telegram photo `ArrayBuffer` values are passed to `Uint8Array`.

`submit-cleaning` fails with 19 errors because `ReturnType<typeof createClient>` collapses query row types to `never` after the floating Supabase 2.x import resolves to 2.112.4. `turnover-verifier` passes with npm auto-install enabled.

## Minimal compatibility change

- Add explicit `ArrayBuffer` assertions only at the two Telegram photo conversion points. Runtime values already come from `Response.arrayBuffer()`.
- Replace helper-parameter `ReturnType<typeof createClient>` with a local structural legacy database client type whose `from` method returns `any`. This restores the untyped runtime contract the deployed function was authored against without changing queries, payloads or control flow.
- Do not add `@ts-nocheck`, alter notification routing or refactor recovered logic.

## Verification

```powershell
npx.cmd --yes deno check supabase/functions/telegram-expense/index.ts
npx.cmd --yes deno check --node-modules-dir=auto supabase/functions/submit-cleaning/index.ts
npx.cmd --yes deno check --node-modules-dir=auto supabase/functions/turnover-verifier/index.ts
node scripts/audit/compare-supabase-production.mjs --check
```

## Rollback and stop conditions

- Rollback: revert this commit; the prior recovery commit retains exact downloaded source.
- Stop if a change affects emitted JavaScript, query strings, message content, routing, environment-variable names or provider calls.

## Commit

```powershell
git add docs/plans/packets/wave-0-0.2a-recovered-source-typecheck.md supabase/functions/telegram-expense/index.ts supabase/functions/submit-cleaning/index.ts docs/validation/recovered-function-hashes.md
git commit -m "fix(cascade): type check recovered edge function sources"
```
