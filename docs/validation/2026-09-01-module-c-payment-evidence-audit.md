# Module C payment-evidence audit — 2026-09-01

## What already exists

- `upload-booking-receipt` uses a short-lived booking-scoped upload token, accepts only validated image types, stores a non-guessable private path and permits only one receipt path per booking.
- Uploading that receipt emits a minimized `booking.receipt_uploaded` outbox event. The existing database test proves the event excludes guest PII and the receipt path.
- `ocr-receipt` creates expense-ledger records with `status = pending_review`; it does not confirm a payment or financial transaction automatically.
- The source workflow inventory contains the inactive `CH-W02 Receipt Review` export. No workflow is activated.

## Gaps to close before Module C can be released

1. **Booking evidence is not yet correlated.** A booking receipt upload does not create a structured payment-evidence candidate tied to expected deposit/full-payment amount.
2. **No bank-email adapter exists.** The approved mailbox must be allowlisted by sender/subject, retain only necessary metadata and produce advisory evidence—not a confirmation.
3. **Legacy OCR bypasses the selected gateway.** `ocr-receipt` calls Gemini directly. New booking-payment analysis must use a pinned OpenRouter task profile with a strict JSON schema, provider-minimized payload and failure-to-review result.
4. **No human review record exists.** Finance needs a review screen/action that compares receipt candidate, allowed bank evidence and expected booking amount. Only the existing canonical booking decision may confirm the booking.
5. **No test fixtures/evaluation pack exists.** Add synthetic clear, unreadable, manipulated, wrong-amount and missing-bank-email cases before provider integration.

## Required contract

```text
receipt upload / allowlisted bank email
  -> advisory evidence candidates (OCR or parser)
  -> deterministic amount/reference/date comparison
  -> Finance review queue
  -> named human chooses approve or decline
  -> decide_direct_booking(...)
```

AI, OCR confidence, matching score, receipt image and bank email cannot change a booking to `confirmed`. A missing bank email must remain manually reviewable rather than reject an otherwise valid payment.

## Next safe local increment

Create the evidence schema and synthetic fixtures first, with tests that prove: no evidence function can invoke `decide_direct_booking`; no candidate can write a confirmed payment/booking state; and Finance review remains required. Deployment, Gmail OAuth, OpenRouter credentials, n8n activation and provider messages require separate action-time owner approval.
