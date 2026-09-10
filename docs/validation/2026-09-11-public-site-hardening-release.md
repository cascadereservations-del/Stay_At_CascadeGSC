# Public-site hardening release — 2026-09-11 UTC

**Status:** PASS — GitHub Pages published the tested hardening revision.

## Released revision

- Repository: `cascadereservations-del/Stay_At_CascadeGSC`
- Commit: `5333691` (`fix(site): harden booking copy and image fallback`)
- Pages workflow: run `34541076907`, completed successfully for that exact commit.

## What the release changes

- Uses the tracked same-origin property image as the eager hero/LCP image and
  as a fallback if a non-payment Drive-hosted property image fails to load.
  Payment QR images are deliberately excluded from that fallback.
- Removes payment account identifiers from structured search metadata and the
  public pre-booking FAQ; payment instructions remain in the booking flow.
- Replaces instant-confirmation or immediate-date-hold wording with explicit
  payment-and-availability review before personal confirmation.
- Limits Playwright discovery to browser specs and runs one worker to keep the
  suite deterministic on the release workstation.

## Verification

Local verification on the released source passed:

| Check | Result |
| --- | --- |
| Content/design/link/handoff contracts | 38 passed |
| Mobile and desktop browser/accessibility/booking checks | 54 passed |
| Image-decode regression guard | passed at both viewports |
| Calendar horizon classifier | 3 passed |

A fresh read-only fetch of the published page confirmed the same-origin preload
and review-before-confirmation copy, with no payment account identifier in the
public FAQ and no superseded immediate-hold language.

## Boundaries retained

This static-site release does not deploy `calendar-sync` v13, activate or test
CH-W07's provider node, create recovery schedules, or perform an owner-only
backup restore. Those remain separately gated. The elapsed CH-S01 observation
window still needs a fresh aggregate production delivery/outbox check before
any W07 approval can be considered.
