# Cascade Direct Booking — Local Validation Evidence

Date: 2026-08-24

## Passed local checks

- pgTAP: 32 assertions covering public booking boundaries, automation tables, booking lifecycle outbox events, and guarded guest identity resolution.
- Deno: 20 tests covering receipt validation/tokens, analytics validation, callback HMAC, guest normalization, and guest-access token hashing.
- Deno type checks: submit booking, receipt upload, analytics, callback, event detail, and guest access functions.
- Frontend content/design suite: 17 tests.
- n8n export validator: four inactive, credential-free workflow templates.

## Explicitly not activated

- No Supabase migration or Edge Function has been deployed.
- No database webhook has been created.
- No n8n workflow has been imported or enabled.
- No Google Calendar OAuth client or calendar connection exists.
- No WhatsApp, Telegram, or email recipient/provider credentials were configured or used.
- No production guest rows were read, merged, or modified.

## Remaining required gates

1. Rebuild against a full staging schema with pgvector enabled, then run the complete synthetic CRM and calendar test matrix.
2. Configure server secrets (`BOOKING_RECEIPT_UPLOAD_SECRET`, `AUTOMATION_CALLBACK_SECRET`, and `N8N_EVENT_DETAIL_SECRET`) outside Git.
3. Obtain Lloyd's explicit approval before deploying migrations/functions, configuring the database webhook, importing/enabling n8n workflows, connecting Google Calendar, or sending messages.
4. Run one synthetic staging booking and validate private receipt access, outbox callbacks, and calendar projection before a frontend release.
