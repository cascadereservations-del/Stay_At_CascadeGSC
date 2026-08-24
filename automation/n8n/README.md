# Cascade n8n exports

All workflows import inactive. Configure credentials and webhook authentication in n8n, never in these JSON files. Supabase remains the booking system of record; workflows consume outbox events and call the authenticated callback after each channel attempt.

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
