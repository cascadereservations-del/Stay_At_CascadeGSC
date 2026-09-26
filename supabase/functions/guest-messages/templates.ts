// guest-messages templates (session 54, SPEC-05 messages 1 and 2, D-174 / D-253 / D-257). Pure: no env, no I/O.
// The copy is DESIGN-direct-booking-scheduled-messages section 7 verbatim, with D-257's two changes: message 1's
// payment bullet reads "Due a day before check-in" (D-251) and message 2 gains the "Before You Arrive" paragraph.
// Session 56 adds messages 3-6 (section 7 verbatim): door_code is never sent - it is the Finance card's text with
// {{door_pin}} left literal for the host to type; mid_stay (D-249 timing), checkout_reminder, after_departure.
// A missing on-ground contact drops that paragraph; a missing review URL drops its bullet, all three drop the list.

export type Key = 'confirmation' | 'pre_arrival' | 'door_code' | 'mid_stay' | 'checkout_reminder' | 'after_departure';
export type Channel = 'messenger' | 'email' | 'card_only';
export type Fields = {
  guest_name: string; checkin_date: string; checkout_date: string; pax: number | null;
  total_amount: number | string | null; deposit_amount: number | string | null;
  onground_name?: string; onground_phone?: string;
  review_facebook_url?: string; review_google_url?: string; review_airbnb_url?: string;
};

const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** "Tue, Oct 20" from a yyyy-mm-dd date (UTC arithmetic, the date has no time). */
export function day(d: string, plusDays = 0): string {
  const x = new Date(String(d).slice(0, 10) + 'T00:00:00Z'); x.setUTCDate(x.getUTCDate() + plusDays);
  return `${DOW[x.getUTCDay()]}, ${MON[x.getUTCMonth()]} ${x.getUTCDate()}`;
}
const peso = (n: number) => '₱' + n.toLocaleString('en-PH', { maximumFractionDigits: 2 });
const balanceOf = (f: Fields) => Math.max(0, Number(f.total_amount ?? 0) - Number(f.deposit_amount ?? 0));
export const firstName = (name: string) => String(name ?? '').trim().split(/\s+/)[0] || 'there';
export const replyChannel = (c: Channel) => c === 'email' ? 'by replying to this e-mail' : 'here in the chat';

/** Message 1's payment bullet (D-257): the balance and the deposit are due a day before check-in (D-251). */
export function atCheckinLine(f: Fields): string {
  const bal = balanceOf(f);
  return bal > 0 ? `${peso(bal)} balance and the ₱1,000 refundable security deposit` : 'the ₱1,000 refundable security deposit only';
}
/** Message 2's "Before You Arrive" paragraph (D-257). */
export function beforeYouArrive(f: Fields, c: Channel): string {
  const bal = balanceOf(f), due = day(f.checkin_date, -1), where = replyChannel(c);
  return bal > 0
    ? `💳 Before You Arrive\nThe ${peso(bal)} balance and the ₱1,000 refundable security deposit are due at least a day before check-in, by ${due}. You may send them by GCash to 0956 011 5744 (account name Cascades, Marifel Suzanne Boncales) and share the receipt ${where}. Your check-in PIN follows once the payment and your IDs are in.`
    : `💳 Before You Arrive\nThe ₱1,000 refundable security deposit is due at least a day before check-in, by ${due}. You may send it by GCash to 0956 011 5744 (account name Cascades, Marifel Suzanne Boncales) and share the receipt ${where}. Your check-in PIN follows once the deposit and your IDs are in.`;
}

export const SUBJECT: Record<Key, string> = {
  confirmation: 'Your stay at Cascade Hideaway is confirmed',
  pre_arrival: 'Your arrival at Cascade Hideaway',
  door_code: '', // never e-mailed: the host sends it by hand after typing the PIN
  mid_stay: "A mid-stay refresh, if you'd like one",
  checkout_reminder: 'Your check-out today',
  after_departure: 'Thank you for staying with us',
};

function confirmation(f: Fields, c: Channel): string {
  return `Welcome home to Cascade Hideaway, ${firstName(f.guest_name)} 🌿

We're happy to confirm your stay with us. Your booking is all set, and we're already looking forward to welcoming you.

🏡 Your Stay Details
• Check-in: ${day(f.checkin_date)} from 2:00 PM
• Check-out: ${day(f.checkout_date)} by 12:00 noon
• Guests: ${f.pax ?? ''}
• Due a day before check-in: ${atCheckinLine(f)}
• Address: Blk 47 Lot 39, Bria Homes, Conel Road, Brgy. San Isidro, General Santos City
• Google Maps: https://maps.app.goo.gl/9vn8KyDwNrXPmJqT9
• Parking: Free roadside parking right in front of the unit

🌿 To help us prepare a smooth and hassle-free arrival for you, may we request the following details for all staying guests:
• Full name of each guest
• Contact number of the main guest
• A photo of a valid ID for all staying guests

These details allow us to pre-register your stay with the village security and coordinate gate access, so you can enter the community and check in smoothly without delays.

You may send these details ${replyChannel(c)} whenever convenient. Once received, we will finalize your smart-lock access and prepare your personal check-in PIN, which will be shared with you as soon as it's ready, or at least 24 hours before your arrival.

Our goal is to make your arrival seamless, secure, and completely stress-free, so you can simply settle in and enjoy your time at Cascade Hideaway.

If there's anything we can prepare for you before your arrival, or if you need assistance at any time during your stay, please feel free to message us. We're always glad to help.

We're excited to welcome you soon and hope you have a relaxing stay at Cascade Hideaway.

With warm regards,
Marifel & The Cascade Team
Hotel Comfort. Home Warmth. 🌿`;
}

function preArrival(f: Fields, c: Channel): string {
  const onground = f.onground_name && f.onground_phone
    ? `\n\nFor anything urgent during your journey or upon arrival, please feel free to contact our on-ground support, ${f.onground_name} ${f.onground_phone}, who will be glad to assist you right away.`
    : '';
  return `Hello ${firstName(f.guest_name)}, 😊

Your stay is just around the corner, and we're very much looking forward to welcoming you to Cascade Hideaway. ✨

Your unit will be ready for you anytime after 2:00 PM on ${day(f.checkin_date)}. We've arranged a simple and secure self-check-in process, so your arrival will be smooth, private, and effortless.

${beforeYouArrive(f, c)}

📖 Your Welcome Guide Awaits
To help you feel at home even before you arrive, we've prepared a thoughtfully curated Welcome Guide, from check-in details to our favorite cafés and hidden gems around GenSan.

🌿 Cascade Hideaway Welcome Guide:
https://tinyurl.com/WelcomeToCascade

Many guests enjoy browsing it ahead of time, planning where to enjoy their first coffee, or deciding which local spot to explore after settling in.

📍 Helpful Details for Your Arrival
Address: Blk 47 Lot 39, Bria Homes, Conel Road, Brgy. San Isidro, General Santos City
https://maps.app.goo.gl/9vn8KyDwNrXPmJqT9
📍 Google Maps (Turn-by-Turn Navigation): https://www.google.com/maps/dir/?api=1&destination=6.1545469,125.1852321

If you have any questions or requests before your arrival, we're always just a message away. 🌿${onground}

Thank you once again for choosing Cascade Hideaway. We look forward to hosting you soon.

Warm regards,
Marifel & The Cascade Team
Hotel Comfort. Home Warmth. 🌿`;
}

/** Message 3 (door code). {{door_pin}} stays literal: the host types it when pasting; code never holds a PIN. */
function doorCode(f: Fields): string {
  const onground = f.onground_name && f.onground_phone
    ? `\n\nIf you need urgent assistance upon arrival or during your stay, please feel free to contact our on-ground partner, who will be glad to assist you:\n📞 ${f.onground_name} ${f.onground_phone}`
    : '';
  return `Hi ${firstName(f.guest_name)} ☀️

Thank you very much for sending the required details. Your stay is now fully verified. 🌿

Welcome home to Cascade Hideaway 💚

Below are your self check-in details for a seamless arrival:
🔑 Smart Lock PIN: {{door_pin}}
Tip: It's the last 4 digits of the mobile number you gave us 😊
(You'll also find a key card on the Cascade keychain with the TV and AC remotes for easy access.)

📖 Welcome Guide (house tips, Wi-Fi, and local recommendations): https://tinyurl.com/WelcomeToCascade

📍 Complete Address: Blk 47 Lot 39, Bria Homes, Conel Road, Brgy. San Isidro, General Santos City
https://maps.app.goo.gl/9vn8KyDwNrXPmJqT9
📍 Google Maps (Turn-by-Turn Navigation): https://www.google.com/maps/dir/?api=1&destination=6.1545469,125.1852321${onground}

For non-urgent concerns, you may message us anytime, and we'll respond as soon as possible. 💚

It's a pleasure to host you. We wish you a smooth and safe journey to General Santos City, and a truly relaxing stay here at Cascade Hideaway.

Marifel & The Cascade Team
Hotel Comfort. Home Warmth. 🌿`;
}

function midStay(f: Fields): string {
  return `Good afternoon, ${firstName(f.guest_name)} 🌿

We hope you're settling in comfortably and enjoying your time at Cascade Hideaway.

As part of our complimentary service for long-stay guests, we're glad to offer a free mid-stay refresh tomorrow. This is completely optional and free of charge. You're welcome to avail of it, or simply let us know if you'd prefer to continue enjoying your privacy.

If you'd like the refresh, we can arrange a convenient time for you. It includes light housekeeping, fresh towels and linens, and replenished toiletries to keep your stay comfortable and refreshed. ✨

If you won't be around during the cleaning, we recommend securing any valuables and personal belongings beforehand, simply for your peace of mind.

Please let us know what works best for you. We're always just a message away, and we hope you enjoy the rest of your stay. 💚

Marifel & The Cascade Team
Hotel Comfort. Home Warmth. 🌿`;
}

function checkoutReminder(f: Fields): string {
  return `Good morning, ${firstName(f.guest_name)} 🌿

We hope you had a restful night and a comfortable stay here at Cascade Hideaway.

As your stay comes to a close, we want to ensure your departure is as seamless as your arrival. Our standard check-out time is 12:00 noon, so there's no rush. Please take your time and enjoy a relaxed morning.

As you gather your belongings, we'd be so grateful if you could switch off the lights and AC and leave the space generally tidy. This gives our team enough time to carefully clean and refresh the space for our next guest.

Once you've checked out, a quick message as you set off would be much appreciated. We truly appreciate having you with us.

It has been a privilege to host you. ☺️

Warmest regards,
Marifel & The Cascade Team 🌿`;
}

/** Message 5.2: a blank review URL drops its bullet; with none left the list and its lead-in go. */
function afterDeparture(f: Fields): string {
  const links = [
    f.review_facebook_url ? `• Facebook: ${f.review_facebook_url}` : '',
    f.review_google_url ? `• Google: ${f.review_google_url}` : '',
    f.review_airbnb_url ? `• Airbnb, if you have stayed with us there as well: ${f.review_airbnb_url}` : '',
  ].filter(Boolean);
  return `Hi ${firstName(f.guest_name)},

Thank you for choosing to stay with us at Cascade Hideaway 🌿

It was such a pleasure hosting you, and we hope your stay was relaxing, comfortable, and wonderfully worry-free.

When you have time, we'd truly appreciate it if you could leave a brief review and share what stood out for you during your stay (and any gentle suggestions, too). Your thoughtful feedback really matters to us and helps us keep improving. ✨
${links.length ? `\nWherever is easiest for you:\n${links.join('\n')}\n` : ''}
We look forward to welcoming you back. You'll always have a home at Cascade.

Warm regards,
Marifel & The Cascade Team 💚`;
}

export function render(key: Key, f: Fields, c: Channel): string {
  switch (key) {
    case 'confirmation': return confirmation(f, c);
    case 'pre_arrival': return preArrival(f, c);
    case 'door_code': return doorCode(f);
    case 'mid_stay': return midStay(f);
    case 'checkout_reminder': return checkoutReminder(f);
    case 'after_departure': return afterDeparture(f);
  }
}

/** The Finance card that offers message 3 (DESIGN-host-fraud-protection section 4). There is no balance-paid column, so
 *  the balance line says "not recorded yet" and states the policy. The 📨 ⤵ block runs to the end (Show as text). */
export function doorCodeCard(ref: string, f: Fields): string {
  const bal = balanceOf(f);
  return [
    `🔑 DOOR CODE READY TO SEND · ${ref}`,
    '',
    `${f.guest_name} · ${day(f.checkin_date)} → ${day(f.checkout_date)} · ${f.pax ?? '?'} guest${f.pax === 1 ? '' : 's'}`,
    `✅ Booking confirmed · ${peso(Number(f.deposit_amount ?? 0))} received`,
    '✅ ID on file',
    bal > 0
      ? `⚠️ Balance ${peso(bal)} + ₱1,000 deposit: not recorded yet. Policy: the PIN follows full payment, unless you are collecting on arrival.`
      : '⚠️ ₱1,000 deposit: not recorded yet. Policy: the PIN follows the deposit, unless you are collecting on arrival.',
    '',
    'Set a fresh PIN in the lock app for this stay. After checkout, delete this guest\'s PIN in the lock app.',
    'Do: Show as text, paste it to the guest and type the PIN where it says {{door_pin}}.',
    '',
    `📨 ⤵\n${render('door_code', f, 'card_only')}`,
  ].join('\n');
}

/** Message 5.2 is held (a person writes instead) while a complaint or safety handoff is open, or a work order raised
 *  during the stay is still open (design section 3). */
export function afterDepartureHold(openHandoffs: Array<{ risk?: string | null; status?: string | null }>, openWorkOrders: number): boolean {
  return openWorkOrders > 0 || openHandoffs.some((h) => h.status === 'open' && ['complaint', 'safety'].includes(String(h.risk)));
}

/** The channel rule (design section 2): Messenger when the guest wrote in the last 23 h; the tapped confirmation may use
 *  HUMAN_AGENT inside Meta's 7 days (a person just tapped Confirm), never a scheduled message; else e-mail; else card only. */
export function channelFor(key: Key, lastGuestAt: number, hasThread: boolean, hasEmail: boolean, tapped: boolean, now: number): { channel: Channel; humanAgent: boolean } {
  const age = now - lastGuestAt, H = 3_600_000;
  if (hasThread && age < 23 * H) return { channel: 'messenger', humanAgent: false };
  if (hasThread && key === 'confirmation' && tapped && age < 167 * H) return { channel: 'messenger', humanAgent: true };
  return { channel: hasEmail ? 'email' : 'card_only', humanAgent: false };
}

/** Messenger takes 2,000 characters a message: split at paragraph breaks, never inside one. */
export function chunks(text: string, max = 2000): string[] {
  const out: string[] = []; let cur = '';
  for (const p of text.split('\n\n')) {
    const next = cur ? `${cur}\n\n${p}` : p;
    if (next.length <= max) { cur = next; continue; }
    if (cur) out.push(cur);
    cur = p;
  }
  if (cur) out.push(cur);
  return out;
}
