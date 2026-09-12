# Meta App Review — pages_messaging (Cascade Hideaway concierge)

App: 1958177441518876 · Page: Cascades Hideaway (699640026568720) · Mode today: In Development, concierge_mode = auto.

## Before submitting (Lloyd)
1. Privacy Policy URL (live since 2026-09-12, concierge section added in Stay_At_CascadeGSC commit ef81360): https://cascadereservations-del.github.io/Stay_At_CascadeGSC/privacy.html . Set it in App Dashboard → Settings → Basic → Privacy Policy URL. (`docs/app-review/privacy.html` here is the standalone draft; the live page is the source of truth.) Add a 1024×1024 app icon and category "Business and Pages". Save.
2. Complete Business Verification for the Meta Business portfolio that owns the Page (registration document or utility bill matching the business name and address).
3. Complete Data Use Checkup when prompted.
4. Record a 1–3 minute screencast: open Messenger as a test user, send "How much? Available?", show the concierge reply; send "Can you do 1500 per night?", show the handoff line and the host card in Telegram; tap an option and show the signed reply in Messenger.

## Use case text (paste into the pages_messaging request)
Cascade Hideaway is a single guest unit in General Santos City, Philippines. Our app powers an automated concierge for the one Facebook Page we own. When a prospective guest messages the Page, the app reads the message via the messages webhook and replies through the Send API with answers to routine pre-booking questions: nightly rates, live availability from our calendar, amenities, directions and house rules. Anything involving payments, refunds, cancellations, complaints, safety, or price negotiation is not answered automatically; the app posts a handoff message and our staff reply personally through the app (a staff reply is sent with the Send API, signed with the staff member's name). We only message people who have messaged the Page first, within Meta's 24-hour messaging window. No message content is used for advertising, and the data we store is described at our Privacy Policy URL.

## Permissions requested
- pages_messaging — send and receive messages for our own Page.
- pages_manage_metadata — subscribe the Page to the messages and message_echoes webhook fields.

## Test instructions for the reviewer
Page: Cascades Hideaway. Send any of: "How much per night?", "Is Sep 20–22 available for 2 adults?", "How far is the airport?". Expected: a reply within 10 seconds from the Page. Send "Can I get a discount?" Expected: a handoff message saying the host will reply personally.

## After approval
Switch App Mode to Live. Keep concierge_mode = auto. Revert to suggest with `docs/plans/2026-09-12-concierge-mode-suggest.sql` if anything looks wrong.
