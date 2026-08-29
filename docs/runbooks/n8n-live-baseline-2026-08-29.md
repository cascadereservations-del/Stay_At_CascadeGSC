# n8n live baseline — 2026-08-29

This is a read-only inventory of the existing shared Portainer n8n runtime. It
contains no credential values and authorizes no workflow activation.

## Runtime

- Public editor: `https://n8n.rocloyd.com`
- Portainer container: `n8n`
- Stack: `deploy`
- Observed image: `n8nio/n8n:latest`
- Observed published Cascade workflows: **0**
- Approved location: Personal → `Cascade Hideaway`
- Folder URL: `/projects/3X0mu5jWdTO2B56T/folders/AK7i39EXJbjcNzls/workflows`

The unpinned `latest` image is an upgrade/recovery risk. Pinning it requires a
separate Portainer change window, backup and rollback plan; do not change the
shared container during ordinary workflow work.

## Workflow inventory

The folder contained 14 unpublished drafts: CH-S01 and CH-W01 through CH-W12,
with two workflows named `CH-W01 Booking Requested`.

| Workflow | Live observation | Disposition |
|---|---|---|
| Newer CH-W01 (`qOD67nBfIFHxxYCc`) | Webhook was GET on a random path; routes into CH-S01; unpublished. | Keep unpublished. Rebuild from the reviewed source export before activation. |
| Older CH-W01 (`UdECCXyzKsyeOUTF`) | POST path `cascade-w01-booking-requested`; Gmail and Telegram nodes; unpublished. Its shared host text contains guest contact and payment totals and targets OPS. | **Blocked:** violates Finance/OPS separation. Never publish. Rename/archive only in an approved cleanup session. |
| CH-S01 (`h9xRZDJbLoaisIRX`) | Safe configuration-gate draft; no provider delivery/final callback. | Keep unpublished until closed templates and per-route credentials are wired. |
| CH-W02–CH-W12 | Safe unpublished drafts observed in the Cascade folder. | Source-controlled exports remain the review baseline. |

## Credential boundary

The Personal credential view visibly included unrelated Google Drive,
OpenRouter and Alfred/Alex Telegram credentials. Node references also included
generic `Gmail account`, `Header Auth account 2` and `CASCADE - Telegram API`
names that were not sufficient to prove dedicated access separation.

Before any Cascade workflow is published:

1. Create/verify credentials named `Cascade — <provider/purpose>`.
2. Confirm Cascade workflows reference only those credentials.
3. Confirm OPS destinations cannot receive amounts, payment status, receipt or
   bank details; use the closed OPS templates and database guard.
4. Export the reviewed workflow to `automation/n8n/workflows/`.
5. Run `node scripts/check-n8n-workflows.mjs`.
6. Obtain action-time approval before publishing or sending a test message.

## Current integration state

Production Supabase already contains an `automation_outbox_dispatch_w01`
trigger that posts only `event_id` and `workflow_id` to the named W01 webhook.
The required Vault secret records exist. The n8n workflow is unpublished, so
this is not a completed delivery path; outbox reconciliation remains canonical.

On 2026-08-29, execution permission on the trigger function was revoked from
`public`, `anon`, `authenticated` and `service_role`. The database trigger still
runs as its owner, but the function is no longer exposed as a client RPC.

## Resume gate

The in-app n8n session expired after the audit. The owner must sign in again
before the duplicate drafts can be renamed, exported or inspected further. Do
not enter or transmit n8n credentials through automation.
