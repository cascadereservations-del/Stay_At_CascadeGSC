# Cascade n8n exports

All workflows import inactive. Configure credentials and webhook authentication in n8n, never in these JSON files. Supabase remains the booking system of record; workflows consume outbox events and call the authenticated callback after each channel attempt.

Do not enable a workflow, connect Google Calendar, configure WhatsApp, or send host/guest messages without Lloyd's explicit approval.
