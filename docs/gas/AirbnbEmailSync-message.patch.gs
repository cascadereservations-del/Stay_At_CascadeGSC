/**
 * AirbnbEmailSync-message.patch.gs  (session 72, SPEC-42 section 2 / D-290 item 5)
 *
 * A PATCH FILE for Lloyd to paste into the Apps Script project "Cascade Cleaning Reports" (AirbnbEmailSync.gs, repo copy v2.1.0).
 * Nothing in this repo runs it. Deploy is Lloyd's (B46); do it AFTER the airbnb-email-sync Edge Function and the migration
 * 20261006120000_airbnb_message_events are live, or the function answers 500 for the new event type.
 *
 * What it does: when Airbnb forwards a guest's chat message by e-mail, send the guest's own words (quoted history and footer
 * cut off, max 2,000 characters) to airbnb-email-sync as { email_type: 'message', ... }. The function reads a mobile number and
 * companion names, matches ONE confirmed stay, and posts a single "details from Airbnb chat" card to OPS with Save and Cancel.
 * Nothing is sent to the guest, and the text is never stored: the function's event log keeps counts only.
 *
 * ---- Edit 1 of 4: add the new type to the counters in syncAirbnbEmails() --------------------------------------------------
 * FIND:     const counts = { booking: 0, payout: 0, cancellation: 0, skipped: 0, errors: 0 };
 * REPLACE:  const counts = { booking: 0, payout: 0, cancellation: 0, message: 0, skipped: 0, errors: 0 };
 * (Without this, counts[event.email_type]++ turns the 'message' counter into NaN. It does not stop the sync, but the log line lies.)
 *
 * ---- Edit 2 of 4: add the branch to parseMessage_() ---------------------------------------------------------------------
 * FIND (the last lines of parseMessage_):
 *     if (/^Canceled: Reservation/i.test(subject))
 *       return parseCancellation_(id, subject, body, dateIso);
 *
 *     return null;
 * REPLACE:
 *     if (/^Canceled: Reservation/i.test(subject))
 *       return parseCancellation_(id, subject, body, dateIso);
 *
 *     if (isGuestMessageEmail_(msg, subject))
 *       return parseGuestMessage_(id, msg, subject, body, date, dateIso);
 *
 *     return null;
 * The three existing checks run first, so a booking, payout or cancellation e-mail can never be taken for a chat message.
 *
 * ---- Edit 3 of 4: paste everything below this block at the end of AirbnbEmailSync.gs -------------------------------------
 *
 * ---- Edit 4 of 4: send the shared secret with every batch, in postToEF_() --------------------------------------------------
 * FIND:     'apikey':         AES_CONFIG.ANON_KEY,
 * REPLACE:  'apikey':         AES_CONFIG.ANON_KEY,
 *           'x-airbnb-sync-secret': PropertiesService.getScriptProperties().getProperty('AIRBNB_SYNC_SECRET') || '',
 * The function refuses 'message' events (no card, HTTP 401 when a batch holds only messages) unless this header equals its AIRBNB_SYNC_SECRET
 * environment variable. Lloyd sets BOTH values himself (Script Properties > AIRBNB_SYNC_SECRET here; Supabase function secrets there), the same
 * value in each. No value is written in this file or anywhere in the repo. Booking, payout and cancellation e-mails are not gated yet.
 *
 * BEFORE YOU DEPLOY (the one open point in SPEC-42): open ONE real "new message" e-mail from a guest in the cascadereservations
 * inbox and check the AES_MSG values below against it. The defaults are Airbnb's usual shape, not a verified one:
 *   - the real chat e-mail's SENDER matches AES_CONFIG.AIRBNB_SENDER ('automated@airbnb.com'): the sync only reads mail from that
 *     address, so a chat e-mail sent from another Airbnb address is never seen (open it, read the From line, change AIRBNB_SENDER or the
 *     search if it differs),
 *   - the subject contains "sent you a message" or starts "New message from" (AES_MSG.SUBJECT, isGuestMessageEmail_),
 *   - the Reply-To / From address ends in @reply.airbnb.com (isGuestMessageEmail_),
 *   - the guest's first name is in the subject or the first line (guestFirstName_),
 *   - the message ends at the first footer line (AES_MSG.FOOTER).
 * If a value is wrong the worst case is no card (the function matches nothing); it never writes guest data on its own.
 * testMessageDryRun() logs what WOULD be sent, without the message text, and posts nothing. (The old testSyncDryRun() prints whole events,
 * so after this patch it would print a message text into the execution log: use testMessageDryRun() instead.)
 */

// ─── Guest-message e-mails (session 72) ──────────────────────────────────────────────────────────────────────────

const AES_MSG = {
  REPLY_DOMAIN:  /@reply\.airbnb\.com/i,        // thread address Airbnb puts in Reply-To (or From) on chat e-mails
  SUBJECT:       /sent you a message|^(?:re:\s*)?new message from/i,  // a chat e-mail says so in the subject; nothing else is read as one
  MAX_AGE_DAYS:  3,                              // older chat e-mails (including the first-run 180-day back-fill) are never sent
  MAX_CHARS:     2000,                           // the function cuts at 2,000 too
  // the guest's text ends at the first line that starts like one of these (Airbnb footer / quoted history)
  FOOTER:        /^(?:reply to this email|you can reply|respond (?:to|in)|view (?:the )?(?:reservation|trip|message|conversation)|go to (?:your )?inbox|airbnb,? (?:inc|ireland)|this email was sent|on .{5,80} wrote:|-{2,}\s*original message|sent from my )/i,
  // first name: "<Name> sent you a message", "New message from <Name>", or "<Name> via Airbnb" in the From header
  NAME_FROM_SUBJECT: [/^(?:re:\s*)?(?:new message from\s+)?([A-Z][\p{L}'-]{1,30})\b(?:\s+sent you a message)?/u],
};

/** True for an Airbnb chat e-mail: the reply address is Airbnb's relay and it is recent enough to matter. */
function isGuestMessageEmail_(msg, subject) {
  const ageDays = (Date.now() - msg.getDate().getTime()) / 86400000;
  if (ageDays > AES_MSG.MAX_AGE_DAYS || !AES_MSG.SUBJECT.test(subject)) return false;
  const reply = String(msg.getReplyTo() || '') + ' ' + String(msg.getFrom() || '');
  return AES_MSG.REPLY_DOMAIN.test(reply);
}

/** { email_type: 'message', ... } for the Edge Function, or null when there is no usable text. */
function parseGuestMessage_(id, msg, subject, body, emailDate, dateIso) {
  const text = guestWordsOnly_(body);
  if (!text) return null;

  const codeMatch  = (subject + '\n' + body).match(/\b(HM[A-Z0-9]{8})\b/);
  const datesMatch = body.match(
    /([A-Z][a-z]{2},\s+[A-Z][a-z]{2,8}\s+\d{1,2})\s{2,}([A-Z][a-z]{2},\s+[A-Z][a-z]{2,8}\s+\d{1,2})/
  );

  return {
    gmail_message_id:  id,
    email_type:        'message',
    email_date:        dateIso,
    guest_first_name:  guestFirstName_(msg, subject),
    confirmation_code: codeMatch ? codeMatch[1] : null,
    checkin_date:      datesMatch ? parseAirbnbDate_(datesMatch[1], emailDate) : null,
    checkout_date:     datesMatch ? parseAirbnbDate_(datesMatch[2], emailDate) : null,
    text:              text,
  };
}

/** The guest's own words: quoted lines and everything from the first footer line down are dropped. */
function guestWordsOnly_(body) {
  const keep = [];
  for (const line of body.split('\n')) {
    if (/^\s*>/.test(line)) continue;
    if (AES_MSG.FOOTER.test(line.trim())) break;
    keep.push(line);
  }
  return keep.join('\n').trim().slice(0, AES_MSG.MAX_CHARS);
}

/** First name from the From header ("Maria via Airbnb <...>") or the subject; null when neither says (the function then needs the code). */
function guestFirstName_(msg, subject) {
  const fromName = String(msg.getFrom() || '').match(/^\s*"?([^"<]+?)\s+via\s+Airbnb/i);
  if (fromName) return fromName[1].trim().split(/\s+/)[0];
  for (const re of AES_MSG.NAME_FROM_SUBJECT) {
    const m = subject.match(re);
    if (m) return m[1];
  }
  return null;
}

/** Dry-run: logs which recent e-mails WOULD be sent as messages (first name, code, text length) - never the text. Posts nothing. */
function testMessageDryRun() {
  const threads = GmailApp.search(`from:${AES_CONFIG.AIRBNB_SENDER} newer_than:${AES_MSG.MAX_AGE_DAYS}d`, 0, 20);
  let n = 0;
  for (const thread of threads) {
    for (const msg of thread.getMessages()) {
      const subject = msg.getSubject();
      const body    = msg.getPlainBody().replace(/\r\n/g, '\n').replace(/\r/g, '\n');
      if (!isGuestMessageEmail_(msg, subject)) continue;
      const ev = parseGuestMessage_(msg.getId(), msg, subject, body, msg.getDate(), msg.getDate().toISOString());
      n++;
      Logger.log(ev
        ? `message: firstName=${ev.guest_first_name} code=${ev.confirmation_code} dates=${ev.checkin_date}..${ev.checkout_date} chars=${ev.text.length}`
        : `message: no usable text`);
    }
  }
  Logger.log(`Chat e-mails seen: ${n}`);
}
