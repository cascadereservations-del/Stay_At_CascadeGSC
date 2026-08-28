# Degraded operations

| Dependency unavailable | Required behaviour |
|---|---|
| OpenRouter | Acknowledge/handoff; create human review; never invent OCR/chat results. |
| n8n | Supabase keeps the canonical outbox event pending/replayable; never roll back a confirmed booking. |
| Gmail/bank notification | Allow manual evidence review; absence is not proof of non-payment. |
| Chat channel | Stop bot after human takeover; prevent webhook echo loops. |
| Airbnb calendar feed | Preserve current blocks; do not reap on an empty/stale feed; require manual confirmation review. |

Every provider error must carry a correlation ID and a sanitized reason code. Never log secrets, receipt URLs, message bodies, payment data to OPS, or guest contact data.
