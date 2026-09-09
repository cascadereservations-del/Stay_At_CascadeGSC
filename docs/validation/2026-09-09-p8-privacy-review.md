# P8 guest-lifecycle privacy review

**Reviewed:** 2026-09-09 UTC

**Scope:** `20260908_p8_guest_lifecycle.release.json` — migrations
`20260905040000_guest_shared_inbox.sql`, `20260905080000_crm_consent_lifecycle.sql`,
`20260905090000_selective_marketing_review.sql`.

**Mode:** source review plus read-only production queries. No migration was applied,
no provider message sent, no personal data read.

## Why this review exists

The P8 contract sets `approvals.current_privacy_review_required: true`. On 2026-09-09
that gate was **unmet**: none of the ten tables P8 creates appeared in
`docs/privacy/data-inventory.md` or `docs/privacy/retention-schedule.md`, even though
they are the most privacy-sensitive tables in the system. Both documents have been
extended in the same change as this review, which is what closes the gate.

## Tables introduced

| Migration | Tables |
|---|---|
| `20260905040000` | `guest_conversations`, `guest_conversation_messages`, `guest_reply_drafts`, `guest_conversation_audit` |
| `20260905080000` | `crm_guest_profiles`, `crm_consent_events`, `crm_lifecycle_events`, `crm_retention_decisions` |
| `20260905090000` | `marketing_drafts`, `marketing_draft_reviews` |

Note that the contract's `forward_verification` names seven of these ten. The three it
does not name — `guest_conversation_messages`, `guest_reply_drafts`,
`guest_conversation_audit` — are the ones that actually hold message content, so they
are covered by this review and by the inventory even though no forward check asserts
their existence.

## Data-minimization findings

The design is minimizing rather than merely access-controlled, which is the reason this
review reaches PASS:

- **No raw contact details.** `crm_guest_profiles` stores email and phone only as
  SHA-256 hashes, constrained by `~ '^[a-f0-9]{64}$'`, and both indexes
  (`crm_guest_email_hash_idx`, `crm_guest_phone_hash_idx`) are over the hashes.
- **No plaintext message bodies.** Conversation messages, reply drafts and marketing
  content are stored as ciphertext with a separately redacted preview. External thread
  identifiers are hashed.
- **Free-text lifecycle values are hashed** (`crm_lifecycle_events.value_hash`).
- **Consent is evidence, not a flag.** `crm_consent_events` is append-only, carries an
  `evidence_hash`, an `effective_at`, a named recorder and a reason.

## Send-path finding

The contract's hardest stop condition is that no marketing send path may be enabled.
This is enforced in the schema, not only in policy: both `marketing_drafts` and
`marketing_draft_reviews` declare

```
publication_authorized boolean not null default false check (not publication_authorized)
```

so the column cannot hold `true` in either table. **The database is structurally
incapable of recording publication authority.** Approving a draft is therefore not a
send, and no code path can make it one without a further migration.

`marketing_draft_reviews` additionally requires `consent_rechecked` to be true, so
consent is re-tested at review time and eligibility at draft time is never sufficient.

## Ordering check (D-038)

P8 carries the widest `staff_access_allowed` body in the chain
(`20260828000500` → `20260831010000` → `20260905030000` → `20260905040000`). Production
was queried read-only on 2026-09-09 and currently answers:

| Check | Result |
|---|---|
| `admin` / `manage_privacy` @ aal2 | true |
| `admin` / `manage_booking` @ aal2 | true |
| `finance` / `approve_refund` @ aal2 | true |
| `cleaner` / `submit_cleaning` @ aal1 | true |
| `admin` / `manage_guest_inbox` @ aal2 | **false** (P8 adds it) |

Both prerequisite releases (privacy, P6) are live, so the ordering precondition holds
and P8 is the last remaining redefinition. The contract's
`earlier_authority_actions_survive_the_function_replacement` check must re-assert the
first four rows after apply.

## Verdict

**Privacy review: PASS**, conditional on the two documentation updates landing with it.

`approvals.current_privacy_review_required` is satisfied by this document.

## Still outstanding for P8 (not privacy)

1. A fresh encrypted production backup. The named restore point
   `cascade-supabase-20260908T082012Z` was taken at 08:22 UTC on 2026-09-08, **before**
   the privacy/P6/P7 applies at ~13:01–13:24 UTC, so it does not capture current
   production and trips the `the production restore point is older than the window`
   stop condition.
2. Rehearsal against that fresh set, then apply.
3. Owner MFA at action time. Production reports 1 verified factor, so this is
   satisfiable.
4. Both feature flags (`guest_inbox_ui`, `marketing_send`) stay off.
