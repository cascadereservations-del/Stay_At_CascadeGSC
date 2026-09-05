# Wave 7 selective marketing and exact-content review — 2026-09-05

Status: local candidate verified. Not deployed or published.

Private drafts store target profiles plus ciphertext and SHA-256 hashes; they contain no raw recipient address and no provider delivery state. Draft creation requires a currently eligible CRM profile and a named AAL2 owner/admin. Advisory-model provenance remains advisory.

Named-human review locks the draft, rechecks current marketing consent, recovery, and retention eligibility, and requires the reviewed content hash to match exactly. Targeting is always approved explicitly; discounts and claims require their own explicit approvals when present. Both draft and review records permanently retain `publication_authorized = false`. No outbox, provider, send, or publication path exists.

Validation passed: 5/5 source checks, 6/6 handoff checks, 33/33 rollback-only pgTAP assertions, the compensating rollback in a disposable restored database while preserving Wave 6, 37/37 platform-safety checks, 13/13 inactive workflow checks, the secret scan, and the whitespace check. No production or provider action occurred.
