# Degraded operations

| Dependency unavailable | Required behaviour |
|---|---|
| OpenRouter | Acknowledge/handoff; create human review; never invent OCR/chat results. |
| n8n | Supabase keeps the canonical outbox event pending/replayable; never roll back a confirmed booking. |
| Gmail/bank notification | Allow manual evidence review; absence is not proof of non-payment. |
| Chat channel | Stop bot after human takeover; prevent webhook echo loops. |
| Airbnb calendar feed | Preserve current blocks; do not reap on an empty/stale feed; require manual confirmation review. |

Every provider error must carry a correlation ID and a sanitized reason code. Never log secrets, receipt URLs, message bodies, payment data to OPS, or guest contact data.

## Executable reason codes

`docs/architecture/degraded-mode-contract.json` is the closed machine-readable source. Unknown providers do not receive an invented fallback.

| Provider | Reason code | Required action |
|---|---|---|
| OpenRouter | `OPENROUTER_UNAVAILABLE` | Create human review without fabricating OCR or chat output. |
| n8n | `N8N_DELIVERY_UNAVAILABLE` | Retain the canonical outbox event and retry idempotently. |
| Gmail | `GMAIL_EVIDENCE_UNAVAILABLE` | Permit manual evidence review; absence never proves non-payment. |
| Chatwoot | `CHATWOOT_HANDOFF_UNAVAILABLE` | Stop automated replies and prevent webhook echo until handoff is verified. |
| Airbnb | `AIRBNB_FEED_STALE` | Preserve existing calendar blocks and require manual review. |

Every decision acknowledges the outage, preserves canonical state and prohibits an automatic financial decision. Provider-specific retries and human-review flags are defined only in the machine-readable contract.
