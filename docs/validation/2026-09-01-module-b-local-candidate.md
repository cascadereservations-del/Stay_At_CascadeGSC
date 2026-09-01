# Module B local candidate validation — 2026-09-01

## Scope and boundary

This is local source and disposable-container validation only. No production Supabase migration, Edge Function deployment, n8n activation, credential change or production data mutation occurred.

## Candidate

- Migration: `supabase/migrations/20260901010000_canonical_booking_decision.sql`
- RPC: `public.decide_direct_booking(uuid, text, text)`
- Edge boundary: `supabase/functions/approve-booking/index.ts`

The RPC uses a repeat-decision advisory lock and a property-wide advisory lock. It checks calendar overlap inside its transaction, then writes the booking state, direct reservation, canonical calendar row, ledger state, calendar projection request and decision record. External delivery remains an outbox concern.

## Evidence

| Check | Result |
| --- | --- |
| `node --test tests/bookings/canonical-booking-decision.contract.test.mjs tests/bookings/approve-booking-boundary.test.mjs` | Pass: 2/2 |
| Local pgTAP `supabase/tests/database/canonical_booking_decision.sql` | Pass: 10 assertions |
| Confirm flow | One reservation, confirmed canonical calendar, one projection request |
| Retry flow | Same idempotency key returned the stored decision and did not create a second row |
| Conflict flow | Overlapping approval returned `conflict`; request stayed pending |

The local pgTAP execution wrapped fixtures in `BEGIN`/`ROLLBACK`; no fixture booking data remained.

`deno check` could not run because the Deno executable is not installed on this workstation. This is an unverified local-tooling check, not a release pass; run it in the Supabase/Deno-capable release environment before deployment.

## Discovery / no-silent-fix rule

The first candidate application correctly failed because the legacy local schema does not expose a usable unique constraint on `booking_inquiries.id`, then on `calendar_events.id`. The final candidate does not add foreign keys to those columns; its logical references are validated by the locked RPC. A later primary/unique-key repair must be its own reviewed expand/contract release.

## Release status

**Blocked.** Module A’s deferred encrypted backup/restore proof, coordinated staff/privacy cutover gates and action-time owner approval remain prerequisites. Do not apply this candidate to production or deploy the refactored Edge Function until those gates are closed.
