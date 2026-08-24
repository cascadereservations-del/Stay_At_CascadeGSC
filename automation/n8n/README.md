# Cascade n8n exports

All workflows import inactive. The exports contain a connected, side-effect-free **safe draft**: manual trigger → idempotency check → configuration gate → callback placeholder. This deliberately replaces the earlier disconnected canvas exports. It is useful for visual review and safe import, but it is not an activated automation.

Configure credentials in **Personal → Credentials**, never in these JSON files. Supabase remains the booking system of record; production workflows must consume its outbox events and call the authenticated callback after each channel attempt.

## Before any workflow can be enabled

1. Replace the manual trigger with an authenticated, production event source.
2. Replace the configuration gate with the correct event-detail request, using the workflow's allow-listed identifier.
3. Add approved provider credentials in n8n: email, Telegram, official WhatsApp Business Cloud, Google Calendar, and the authenticated Supabase endpoints.
4. Wire every required delivery branch and only then replace the callback placeholder with a signed `automation-callback` request.
5. Test with an explicit, non-production event. Do not send a guest or host message during setup without approval.

## Delivery completion rule

Each provider attempt must call `automation-callback` with its own `email`,
`telegram`, or `whatsapp` channel. Those callbacks write a delivery log but
intentionally leave the outbox event `dispatched`: one successful channel is
not proof that the complete host-alert or guest-message workflow succeeded.

Only the final router step may call the callback with `channel: "internal"`
and `status: "sent"` or `"skipped"`, after every required branch has either
sent successfully or been intentionally skipped. If any required branch
fails, do not send that finalization callback; send the failed provider
callback with a normalized error code and leave the event for reconciliation.

Do not enable a workflow, connect Google Calendar, configure WhatsApp, or send host/guest messages without Lloyd's explicit approval.
