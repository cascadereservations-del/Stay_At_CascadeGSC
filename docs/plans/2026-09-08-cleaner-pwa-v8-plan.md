# Cleaner PWA v8 — analysis and plan (2026-09-08)

**For:** the next chat (implementer: Sonnet; reviewer: Opus). Read `04-HANDOFF-cascade.md` in the vault first, then this file. Nothing here is implemented yet.
**Repo:** `cascadereservations-del/CH-Cleaners-Checklist`, local clone `Cascade\cleaners-auth-sol\` (branch `codex/named-cleaner-auth` = `main` = `2e268c3`). One file, `index.html`, 8,801 lines / 361 KB (about 3,100 lines of CSS), plus `sw.js`, `manifest.webmanifest`, `install.js`.
**Backend (live, do not change without a packet):** `submit-cleaning` v36, `upload-photo` v26, `last-readings` v26, `staff-users` v1; staff tables and RLS from Module A (D-031/D-032).
**Owner constraints, still binding:** zero added daily friction for the cleaner; sign in once per device; nothing here is a simulation. Rule 6: no push without Lloyd's word.

## 1. Lloyd's four asks, answered

### 1.1 "Login feels redundant" — what is true today, and what to change

Today the session already behaves as asked: one sign-in per device, kept in `localStorage`, access token refreshed silently, ends only on sign-out, password change, or owner disable/delete (which also bans the Auth user so refresh dies). The 2026-09-08 patch keeps the session through offline opens and bad signal.

What actually feels redundant is **identity asked twice**: once at sign-in, then again every shift in Phase 0's required "Your name" combobox (Marifel / Honey / Lloyd / type manually). Since Module A the form already knows who is signed in. So:

- **Remove the Phase 0 name combobox.** Replace with a read-only chip "Signed in as **Honey**" and a small "Not you? Switch account" link that signs out and shows the gate. `cleanerName` in the payload comes from the session.
- **Sign-out condition:** keep it to the three real ones (sign-out link, owner disable/delete, password change). No idle timeout; Supabase's inactivity timeout is Pro-only and constraint 1 forbids re-prompting. Optional, cheap guard: if the device has not opened the app for 90 days, show the gate on next open (client-side `last_seen` in `localStorage`); default **off**.
- **Where the name comes from:** the sign-in and refresh responses carry `user.user_metadata.display_name` (set by `staff-users` on create) and `user.app_metadata.display_name`. Store `display_name` in the saved session next to `id`/`email`. For the two mailbox logins (owner, admin) there is no display_name yet: one SQL update sets `raw_user_meta_data.display_name` to "Lloyd" and "Marifel" (owner-run, no e-mails in Git). Fallback: e-mail local part with dots as spaces.
- **Sign-out control:** move the tiny underlined "Sign out" out of the header (a cleaner can tap it by accident) into Phase 0 behind "Not you?" and into the success screen footer.

### 1.2 "Name automatically reflected in the form" — same change

`selectCleaner()` and `LAST_CLEANER_KEY` go away; `state.cleanerName = staffSession.user.display_name` at boot and after sign-in. The Telegram/Finance cards already print `cleanerName`, and `submitted_by_user_id` is the audit key, so nothing downstream changes.

### 1.3 "A dropdown in the login, same as in the form"

A dropdown of staff names *before* sign-in would need a public list of staff names. That leaks who works at the property to anyone with the URL, so **not that**. Two acceptable shapes:

- **Recommended: remembered names on this device.** After a successful sign-in, save the name in `localStorage` (`ch_known_logins`, max 5). The gate shows those names as tappable chips above the field ("Honey", "Marifel") plus "Other name". One tap fills the name; only the password is typed. On a phone that has never signed in there are no chips, which is correct.
- **If a true dropdown is required later:** an authenticated-only path, i.e. the dropdown appears in the *form* after sign-in for the rare shared-phone case, backed by a "list names only" action on `staff-users` that any enabled staff may call. Costs a function change; defer unless a shared phone actually exists.

### 1.3b "A PIN instead of a password, with a lock-screen interface" (added mid-planning, 2026-09-08)

Two ways to do this; the plan takes the second.

- **PIN as the Supabase password.** Simplest, but a 4–6 digit password on an internet-facing Auth endpoint is guessable over days despite Supabase's per-IP rate limit, and the same PIN would unlock the Inventory app and any future staff tool. Rejected.
- **Local PIN lock in front of a strong password (recommended).** The Auth password stays long and is typed **once per device** by Lloyd or Honey at first sign-in (the existing gate). Immediately after, the app asks the cleaner to **set a PIN** (4–6 digits) on a full-screen numeric keypad styled like a phone lock screen: large digits, dots that fill as digits are entered, haptic tick where supported, no submit button (auto-check on the last digit). Later opens show the PIN keypad, not the sign-in gate. The PIN is checked locally: PBKDF2-SHA-256 of PIN + a random per-device salt, 100k iterations, stored in `localStorage` (`ch_pin_v1`); the Supabase session is stored as today and is simply not used until the PIN passes. Five wrong PINs in a row fall back to the name + password gate, which also resets the PIN.
- **When the keypad appears:** on every cold open of the app (what a lock screen does). Switching between phases inside a shift never asks again. If Lloyd later finds even that too much, a single constant `PIN_IDLE_MINUTES` (0 = every open) turns it into "only after N minutes in the background".
- **What it changes elsewhere:** nothing on the server. Owner/admin can "Reset PIN" for a cleaner only in the sense of resetting the password from Staff logins, which forces the one-time gate again on her next open.
- **Inventory app:** same PIN component is dropped in later (out of this pass), so the cleaner has one PIN for both.

### 1.4 Form review (design, efficiency, low-spec phones, photos) — findings

Scored against mobile-first heuristics (touch targets, one-hand reach, cognitive load, first-paint cost, memory, network resilience). What is good stays: five-phase stepper, 48 px targets, Quick/Detail toggle, offline banner and retry, draft autosave, dedupe by `submissionId`, timestamp burned into photos, blur/size checks, mid-stay/emergency modes.

| # | Finding | Evidence | Effect on a low-spec phone |
|---|---|---|---|
| F1 | Photos are decoded at full camera resolution through `Image` before drawing to canvas | `compressImage()` lines ~5395–5430: `FileReader.readAsDataURL` → `new Image()` → 960 px canvas | A 12 MP JPEG decodes to ~48 MB RGBA; two in flight can crash the tab on 2 GB phones. `createImageBitmap(file, {resizeWidth})` decodes at target size in one step. |
| F2 | Every photo travels as base64 JSON | `uploadPhotoDrive()` sends `fileData` data-URL; server limit 7.1 MB string | +33 % bytes on 3G, plus a full string copy in memory. Sending the JPEG bytes raw (`Content-Type: image/jpeg`, metadata in headers) needs a small `upload-photo` v27 that accepts both shapes. |
| F3 | Draft autosave stores the base64 of every photo in `localStorage` | `state.meterPhotos[i].data = dataUrl; saveDraft()` | 15 photos × ~60 KB ≈ 1 MB per draft; `localStorage` quota is 5 MB and writes are synchronous on the main thread (jank on each photo). Move photo blobs to IndexedDB; keep only paths and flags in the draft. |
| F4 | Uploads start all at once with no concurrency cap | multi-select handlers call `uploadPhotoDrive` per file, fire-and-forget | Six parallel 60 KB POSTs on 3G stall each other; retries multiply. A queue with concurrency 2, per-photo state (queued / uploading / done / failed), and a "retry all failed" button. |
| F5 | Upload failures are silent | `uploadPhotoDrive` returns `null`, counter increments only | The cleaner reaches submit with photos that never uploaded and `submit-cleaning` rejects the `fileId`-less entries (`invalid_photo_scope`). Show per-thumbnail status and block submit while uploads are pending, with a clear "3 photos still uploading" line. |
| F6 | Blur check runs on the main thread per photo | `checkPhotoQuality()` Laplacian over 128² | ~30–60 ms on a low-end CPU; fine alone, but it runs right after the big canvas draw. Run inside the same worker as F1, or `requestIdleCallback`. |
| F7 | Two Google font families, six weights, blocking first paint | `<link href="fonts.googleapis.com/css2?family=Cormorant+Garamond…Raleway…">` | ~100–150 KB and a DNS+TLS round trip before text renders. Keep Cormorant for the two headline sizes only (self-hosted subset, `font-display: swap`), system font for body. |
| F8 | 361 KB HTML, all CSS and JS inline, no minification | file size | Parsing dominates on first open; the service worker caches it, so this hurts once per version. Acceptable for now; a build step is out of scope for this pass. |
| F9 | Header carries elapsed timer + online dot + 5-dot stepper; bottom bar carries progress | `#phase-stepper`, `#top-right`, `updateBottomBar()` | Two progress systems compete. Keep the bottom bar (thumb reach), demote the stepper to a thin segmented progress line. |
| F10 | Phase 1 (Document) mixes meters, four photo groups and unit condition in one long scroll | `#phase-1` sections | Longest phase; the cleaner scrolls back to find the missing photo group. Sticky "photos: 3/5 pre, 0/5 after, 1/2 meter" summary at the top of Phase 1 that scrolls to the short group on tap. |
| F11 | `capture="environment"` inputs plus a separate "upload" input per group | markup around 3684–4090 | Correct pattern for Android. Keep. Add `accept="image/jpeg,image/png,image/webp"` to match the server's MIME list. |
| F12 | Name combobox + manual entry (see 1.1) | Phase 0 | Removed. |

## 2. Work packages (do in order; each is one commit and one review)

| WP | Scope | Files | Done when |
|---|---|---|---|
| WP1 | Identity from session: store `display_name` in the saved session; Phase 0 chip + "Not you?"; remove combobox/manual entry/`LAST_CLEANER_KEY`; sign-out moved; remembered-names chips on the gate; optional 90-day guard flag (off) | `index.html`, tests | `npm test` green; new test asserts no `combobox-option` and that payload `cleanerName` equals session display name; owner/admin display names set by SQL |
| WP1b | PIN lock screen (see 1.3b): set-PIN screen after first sign-in, keypad unlock on cold open, PBKDF2 local check with per-device salt, 5 failures fall back to the password gate, `PIN_IDLE_MINUTES` constant (default 0) | `index.html`, tests | On a fresh device: sign-in → set PIN → close app → reopen shows keypad, correct PIN opens Phase 0 with the name chip; wrong PIN ×5 shows the password gate; no network call is made to check a PIN |
| WP2 | Photo pipeline v2: `createImageBitmap` with `Image` fallback, worker for resize + blur, IndexedDB photo store, upload queue (concurrency 2), per-thumbnail status, retry-all, block submit while pending | `index.html` (inline Blob worker) | Manual test on a 2 GB Android: 12 photos in Phase 1 without a tab reload; draft restore after killing the app shows thumbnails and upload states |
| WP3 | `upload-photo` v27: accept raw JPEG body (`Content-Type: image/jpeg`, `x-cascade-file-name`, `x-cascade-submission-id`, `x-cascade-property-id`) in addition to the JSON shape; same size/MIME/path rules | `supabase/functions/upload-photo/index.ts` | `deno check` clean; Deno test for both shapes; deploy is a separate approval |
| WP4 | First paint: self-hosted Cormorant subset (2 weights) with `font-display: swap`, system body font; remove unused CSS found by coverage on the five phases; `prefers-reduced-motion` respected | `index.html`, `fonts/` | Lighthouse mobile on a throttled 3G profile: first contentful paint under 2.5 s from cache-miss; no layout shift on font load |
| WP5 | Phase 1 sticky photo summary + jump links; stepper demoted; bottom bar remains the single progress control | `index.html` | Cleaner can see all three photo counts without scrolling; tapping a short group scrolls to it |
| WP6 | Evidence and handoff: screenshots at 360×640 and 412×915, before/after byte and timing table, vault update | `docs/validation/…`, vault | Opus review sign-off recorded |

Out of scope for this pass: a bundler/minifier, Inventory app UI, GAS forward removal, changing the five-phase structure.

## 3. Review checklist for Opus

1. Constraint 1 holds: no path shows the sign-in gate to a signed-in device except sign-out, disable/delete, or the optional off-by-default 90-day guard.
2. No staff name is fetchable before sign-in.
2b. The PIN never leaves the device and is never the Supabase password; the stored value is a salted PBKDF2 hash; five failures force the password gate.
3. `submitted_by_user_id` still comes from the server (`requireStaffAccess`), never from the client.
4. Photo path contract unchanged: `${propertyId}/${userId}/${submissionId}/…` and `submit-cleaning` rejects other prefixes.
5. Memory: no full-resolution decode on the main thread; no base64 in `localStorage`.
6. Offline: a draft with pending uploads survives an app kill and resumes on `online`.
7. `npm test` in the PWA repo and `deno check` on any function touched.
8. Nothing pushed or deployed without Lloyd's word; evidence file written before asking.
