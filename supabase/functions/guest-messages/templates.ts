// guest-messages templates (session 54, SPEC-05 messages 1 and 2, D-174 / D-253 / D-257). Pure: no env, no I/O.
// The copy is DESIGN-direct-booking-scheduled-messages section 7 verbatim, with D-257's two changes: message 1's
// payment bullet reads "Due a day before check-in" (D-251) and message 2 gains the "Before You Arrive" paragraph.
// Messages 3-6 are out of scope. A missing on-ground contact drops that paragraph; nothing else is optional.

export type Key = 'confirmation' | 'pre_arrival';
export type Channel = 'messenger' | 'email' | 'card_only';
export type Fields = {
  guest_name: string; checkin_date: string; checkout_date: string; pax: number | null;
  total_amount: number | string | null; deposit_amount: number | string | null;
  onground_name?: string; onground_phone?: string;
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

export function render(key: Key, f: Fields, c: Channel): string {
  return key === 'confirmation' ? confirmation(f, c) : preArrival(f, c);
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
