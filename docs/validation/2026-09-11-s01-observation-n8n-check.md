# S01 observation close — n8n-plane check

**Checked:** 2026-09-11, after the 2026-09-11 00:55 UTC observation boundary
**Scope:** aggregate-only, read-only SSH inspection of Alfred's `cascade-n8n` plane

## Evidence

- `cascade-n8n-app` and `cascade-n8n-postgres` were healthy, with zero restarts and no OOM state.
- The loopback `/healthz` endpoint returned `{"status":"ok"}`.
- n8n held 13 workflows, 2 active workflows, and 2 credentials.
- CH-S01 (`a6suf8qOJnp7ASdG`) recorded **276 executions** since 2026-09-10 00:55 UTC, with
  **0 non-success statuses**.

No workflow body, execution payload, credential, message content, or production business row was
read or recorded.

## Boundary

This establishes the n8n-side portion of S01's observation window only. It does **not** prove the
production `automation_outbox` / delivery-log aggregate or authorize enabling CH-W07's Telegram
node. A fresh owner-authorized, aggregate-only production delivery check and Lloyd's exact
provider-node approval remain required before the controlled W07 failure test.
