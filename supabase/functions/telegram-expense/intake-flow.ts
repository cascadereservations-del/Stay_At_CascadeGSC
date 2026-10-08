// SPEC-42 s4b / TASKS #7: Telegram /intake. An owner/admin taps a current or upcoming direct stay and gets the guest-intake link for it,
// ready to forward to the guest. Finance group only (the link is a credential; OPS is read by cleaners, D-306). No typed syntax (D-302):
// the button carries the booking id, so there is no pending row to expire. Every tap re-checks the tapper, re-reads the stay and mints a
// fresh token (only the SHA-256 is stored, same as submit-booking). guest-intake resolves direct, confirmed stays only, so only those are offered.
import { withHeader } from '../_shared/cascade-core/format.ts';
import { mintStatusToken, type TokenStore } from '../_shared/guest-access-token.ts';

export const STAY_PAGE = 'https://cascadereservations-del.github.io/Stay_At_CascadeGSC/stay.html#t=';
export const INTAKE_FINANCE_ONLY = 'The guest link runs from the Finance group, because the link is private to the guest. Nothing was made.';
export const INTAKE_NOT_LINKED = "Your Telegram is not linked to an owner or admin login, so I can't make a guest link. Ask Lloyd to link it in the admin dashboard (Staff). Nothing was made.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type Deps = {
  db: any;
  propertyId: string;
  isFinance: (chatId: unknown) => boolean;
  send: (chatId: any, text: string, extra?: Record<string, unknown>) => Promise<any>;
  edit: (chatId: any, mid: number, text: string, rm?: unknown) => Promise<any>;
  answer: (cbId: string, text?: string) => Promise<any>;
  esc: (s: string) => string;
  today: () => string;
};
export type Stay = { id: string; name: string; checkin: string; checkout: string };

/** Stays the guest form can serve: confirmed direct bookings with a guest record that have not checked out. Nearest first, max 8. */
export async function openStays(d: Deps): Promise<Stay[] | null> {
  const { data, error } = await d.db.from('booking_inquiries').select('id,guest_id,checkin_date,checkout_date')
    .eq('property_id', d.propertyId).eq('source', 'direct').eq('status', 'confirmed').not('guest_id', 'is', null)
    .gte('checkout_date', d.today()).order('checkin_date', { ascending: true }).limit(8);
  if (error) return null;
  const rows = (data ?? []) as any[];
  if (!rows.length) return [];
  const g = await d.db.from('guests').select('id,name').in('id', rows.map((r) => r.guest_id));
  if (g.error) return null;
  const names = new Map<string, string>(((g.data ?? []) as any[]).map((x) => [x.id, String(x.name ?? '')]));
  return rows.map((r) => ({ id: r.id, name: names.get(r.guest_id) || 'Guest', checkin: r.checkin_date, checkout: r.checkout_date }));
}

const short = (iso: string) => `${iso.slice(5, 7)}-${iso.slice(8, 10)}`;
export const stayLabel = (s: Stay, today: string) => `${s.name.slice(0, 24)} · ${short(s.checkin)} to ${short(s.checkout)}${s.checkin <= today ? ' · in house' : ''}`;
export const parseIntakeTap = (data: string): string | null => (data.startsWith('int:') && UUID.test(data.slice(4)) ? data.slice(4) : null);

/** Owner/admin check through the existing candidates RPC (telegram_staff_actor_v1 is not callable by service_role); fails closed. */
async function isOwnerAdmin(d: Deps, tgId: unknown): Promise<boolean> {
  const t = d.today();
  const { data, error } = await d.db.rpc('telegram_guest_candidates_v1', { p_actor_telegram_id: tgId, p_property_id: d.propertyId, p_from: t, p_to: t, p_search: 'zz' });
  return !error && data?.ok === true;
}

/** The line staff forward to the guest. Cassy voice: calm, a guide, no exclamation. */
export function guestLine(firstName: string, checkin: string, link: string): string {
  return `Hello ${firstName}, before you arrive on ${checkin} you can add each guest's name and an ID photo here: ${link}\nIt takes about two minutes and the photos are kept private. You can come back to the same link until check-out.`;
}

/** `/intake`: one button per stay. */
export async function startIntake(d: Deps, msg: any): Promise<void> {
  const chatId = msg.chat?.id;
  if (!d.isFinance(chatId)) { await d.send(chatId, INTAKE_FINANCE_ONLY); return; }
  if (!(await isOwnerAdmin(d, msg.from?.id))) { await d.send(chatId, INTAKE_NOT_LINKED); return; }
  const stays = await openStays(d);
  if (stays === null) { await d.send(chatId, 'I could not load the stays, so nothing was made. Try again in a minute.'); return; }
  if (!stays.length) { await d.send(chatId, withHeader('guest', 'guest link', 'No confirmed direct stay is current or upcoming, so there is nothing to send a link for.')); return; }
  const t = d.today();
  await d.send(chatId, withHeader('guest', 'guest link', 'Which stay is the link for? Tap it and I will make the link to forward to the guest.'),
    { reply_markup: { inline_keyboard: stays.map((s) => [{ text: stayLabel(s, t), callback_data: `int:${s.id}` }]) } });
}

/** Every int: tap. */
export async function onIntakeTap(d: Deps, cq: any): Promise<void> {
  const chatId = cq.message?.chat?.id, mid = cq.message?.message_id, id = parseIntakeTap(String(cq.data ?? ''));
  if (!id) { await d.answer(cq.id, 'That button is not valid. Nothing was made.'); return; }
  if (!d.isFinance(chatId)) { await d.answer(cq.id, 'Finance group only. Nothing was made.'); return; }
  if (!(await isOwnerAdmin(d, cq.from?.id))) { await d.answer(cq.id, 'Only the owner or admin can make a guest link. Nothing was made.'); return; }
  const stay = (await openStays(d))?.find((s) => s.id === id);
  if (!stay) { await d.answer(cq.id, 'That stay is no longer open. Nothing was made.'); return; }
  const token = await mintStatusToken(d.db.from('guest_access_tokens') as TokenStore, { propertyId: d.propertyId, bookingId: stay.id, checkoutDate: stay.checkout });
  if (!token) { await d.answer(cq.id, 'I could not make the link. Nothing was made.'); return; }
  await d.answer(cq.id);
  // The card in the thread never holds the token; the link goes in one separate message that can be forwarded or copied.
  await d.edit(chatId, mid, withHeader('guest', 'guest link', `Link made for ${d.esc(stay.name)}, ${stay.checkin} to ${stay.checkout}. It is in the next message.`));
  const first = stay.name.replace(/`/g, '').split(/\s+/)[0] || 'there';
  await d.send(chatId, `\`${guestLine(first, stay.checkin, STAY_PAGE + token)}\``);
}
