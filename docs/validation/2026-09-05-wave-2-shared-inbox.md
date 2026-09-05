# Wave 2 shared-inbox local candidate — 2026-09-05

Wave 2 now has a local-only Supabase shared-inbox foundation. No provider was configured, no workflow was activated, and no message was sent.

- Inbound messages are idempotent and retain opaque source/content hashes, ciphertext bodies, redacted previews, and received times.
- The accepted purposes are operational stay, booking support, and service recovery. Marketing is outside this release.
- Payment, refund, cancellation, complaint, safety, access, policy-exception, and uncertain topics deterministically escalate.
- Assistant output remains an advisory draft. A named AAL2 owner/admin may approve or reject the exact draft, but approval returns `send_authorized: false` and creates no outbox event.
- Assignment and resolution actions are named, property-scoped, idempotent, and audited.
- Finance, service integrations, cleaners, inspectors, and maintenance identities cannot read or manage the guest inbox. Service integrations can only ingest inbound records and propose drafts through guarded RPCs.

Validation passed: 4/4 Node source-boundary tests and 31/31 rollback-only pgTAP assertions. Production and provider delivery remain frozen behind Module A and fresh action-time approval.
