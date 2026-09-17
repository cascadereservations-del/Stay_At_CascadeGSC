# Concierge communication protocol

Cascade Hideaway · Messenger Concierge, Cassy drafts, Telegram templates · v1, 2026-09-17 (session 28)

Brand promise: **Hotel comfort. Home warmth.** Every message a guest reads from us, whether a person or the
Concierge wrote it, has to feel like a host who is glad they wrote, not a form that is collecting fields.

## Where this comes from

- **Airbnb, "Communicate effectively with guests"** (airbnb.com/resources/hosting-homes/a/communicate-effectively-659):
  availability (respond fast), transparency (what we say matches what they get), openness (ask how we can
  help them feel comfortable and welcome), care (empathy, resolve fast). Five messaging moments: inquiry,
  after booking, 1-2 days before check-in, shortly after arrival, after check-out.
- **Ritz-Carlton Three Steps of Service** (via Hospitality Net, "5 Steps to 5-Star Service Excellence"):
  a warm welcome; address guests by name and anticipate and fulfil their needs; a fond farewell.
  Consistency comes from documenting what works, not from hoping.
- **Forbes Travel Guide** guest-messaging guidance: clear, concise, on brand and polite; do not overwhelm.
- What we saw live on 2026-09-17: "Hello, is Oct 3 to 4 available? I would like to book for 2 adults" was
  answered with "Your mobile number po, for the booking?". The guest's question was skipped, the flow read
  as a form, and Lloyd's verdict was "transactional, sounds very AI".

## The three moves, in this order, in every reply

1. **Answer.** If the guest asked something, the first sentence answers it. Availability from the calendar,
   rates from the rate card, everything else from FACTS. A reply that only asks a question back is a defect.
2. **Acknowledge.** The person before the fact: their name early, "po" in Taglish, what they already told us
   ("Oct 3 to 4, 2 guests, noted po"). Reflect their plan back where it changes the advice.
3. **Advance.** One ask at most, phrased as a host would ("May we have your mobile number po, so we can reach
   you about your stay?"), and never a dead end: the guest always knows the next step.

4. **Easy to consume.** A phone screen, read between two other things: at most three or four short
   paragraphs, one blank line between ideas, the next step named as "Next step:" and carrying the exact
   amount or date, numbers on their own line, one payment channel (GCash), no repeated information.
   Fewer steps beat more: ask for two things in one message when the guest can answer both at once
   (mobile number + optional e-mail), and let the decisive answer do the confirming (DEPOSIT / FULL sends
   the request; there is no separate YES). Nudges stay gentle: one invitation, never repeated.

## Voice rules that are enforced

| Rule | Where it lives | How it is enforced |
|---|---|---|
| Answer first | `booking.ts` `start()` records `asked`; `index.ts` answers availability from `calendar_events` before the flow's ask, or lets the model answer and appends the ask | `voice.test.ts` (build fails); `voice_lint` warning at runtime |
| Welcome before any ask on the first turn | `booking.ts` `opener()` | `voice.test.ts` `cold_opener` |
| No form-speak ("Your mobile number?", "Enter…") | `booking.ts` `prompt()` | `voice.ts` `form_speak` |
| One idea per message, ≤ 2 questions, ≤ 700 chars, ≤ 4 paragraphs of ≤ 320 chars | every canned prompt | `voice.ts` `two_asks`, `too_long`, `too_dense` |
| No robot vocabulary (bot, automated, processing, ticket, form) | all replies | `voice.ts` `robot_word` |
| Positive frame, warm vocabulary, name early, no exclamation stacking | `facts.ts` VOICE rules 1-8, 5a | model prompt; live audit |
| Money is exact and the guest's choice | `booking.ts` `pay` step (fee or full), `quoteTotal()` from the rate card; QR carries the amount (QR Ph tag 54) | `voice.test.ts` CRC test; `submit-booking` accepts only the fee or the full total |
| Policies match the site | `paymentReply()` names the 50 % fee, the ₱1,000 deposit, the 48 h and 5-day rules | session 28 policy table (04-HANDOFF) |
| Nothing is sent to a guest by a draft tool | Cassy `draft`/`revise` end with "Nothing was sent" | design |

## The five moments (Airbnb) and who covers them today

| Moment | Cascade today | Gap |
|---|---|---|
| Inquiry | Concierge answers, anchors the rate, links the site; book flow when they say "book" | – |
| After booking | Messenger "Confirmed po" from the Telegram Confirm tap; e-mail via the GAS relay | – |
| 1-2 days before check-in | H1 scheduled sends (address, gate code, arrival morning) | **still manual** (open item) |
| Shortly after arrival / mid-stay | daily digest mid-stay 📨 template on night 2 of 3+ | host sends it (Copy button) |
| After check-out | review ask | not automated |

## Keeping the quality (the protocol proper)

1. **Build gate.** `deno test messenger-concierge/voice.test.ts` runs every canned line through `lintReply()`.
   A new prompt that fails the lint does not ship. Add a case to the test whenever a new canned line is added.
2. **Live watch.** `index.ts` logs `voice_lint` (warn-only) with the violation and the first 160 characters of
   any outgoing reply that breaks a rule. Read it with `query_logs` after any Concierge deploy and in the
   weekly review; three of the same violation in a week means the prompt or a rule changes, not the log.
3. **Weekly review (Monday, with the WEEKLY digest).** Read the last five guest threads end to end in the
   Page inbox. Score each reply on the three moves (answered / acknowledged / advanced) and tone (would a
   guest guess a person wrote it?). Anything below 3/3 becomes a test case or a VOICE rule the same week.
4. **Every live complaint from Lloyd becomes a test.** The 08:53 exchange is now
   `voice.test.ts` "the question is answered before the ask"; the next one gets the same treatment.
5. **Change discipline.** Copy changes are patch-only, in the guest's language, and are read back live
   (Hard Rule 9) before the session closes: send the real message from a personal profile and read the reply.
