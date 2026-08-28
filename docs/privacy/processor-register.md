# Cascade processor register

| Processor | Service | Data categories | Contract/configuration gate |
|---|---|---|---|
| Supabase | Database, Auth, Storage, Edge Functions | All operational and booking data | Project-specific roles, private storage, RLS, service-secret handling. |
| Portainer-managed n8n | Automation orchestration | Signed event IDs, minimal delivery metadata | Dedicated Cascade folder/credentials; inactive imports and no shared Alfred/Alex credentials. |
| Google | Gmail / Apps Script | Minimum payment notification fields, operational email relay | Dedicated `cascadereservations@gmail.com` OAuth; sender allowlist; no raw-body persistence. |
| Telegram | Finance/OPS notifications | Closed, route-specific templates | Finance/OPS chat separation; no financial payload to OPS. |
| OpenRouter | Future advisory chat/OCR | Minimized/redacted prompt/image task data | Pinned allowlist, fallback/manual review, no random free router. |
| Airbnb | Listing/reservation channel | Reservation and payout data | Calendar is projection; Airbnb payments remain external. |

Add a processor only after its least-data contract and breach/contact path are documented.
