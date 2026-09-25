// deno test --allow-read submit-booking/supersede.test.ts
// SPEC-30 (D-239): the guest's own earlier request is released BEFORE the availability read, or a guest moving to
// overlapping dates is refused by their own hold. The rules themselves are pgTAP (supersede_pending_hold.sql).
import { assert } from 'https://deno.land/std@0.224.0/assert/mod.ts';
const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
Deno.test('supersede runs before check_availability, with the new dates, phone and e-mail', () => {
  const s = src.indexOf("rpc('supersede_pending_direct_requests_v1'"), a = src.indexOf(".rpc('check_availability'");
  assert(s > 0 && a > s, 'supersede must come first');
  const call = src.slice(s, s + 260);
  for (const k of ['p_email: guestEmail', 'p_phone: guestPhone', 'p_checkin: checkinStr', 'p_checkout: checkoutStr']) assert(call.includes(k), k);
});
