// SPEC-42 s4b / TASKS #7: Telegram /intake. An owner/admin taps a current or upcoming stay and gets the guest-intake link for it,
// ready to forward to the guest. Finance group only (the link is a credential; OPS is read by cleaners, D-306). No typed syntax (D-302):
// the button carries the booking id, so there is no pending row to expire. Every tap re-checks the tapper, re-reads the stay and mints a
// fresh token (only the SHA-256 is stored, same as submit-booking). guest-intake resolves confirmed direct stays and (D-323) confirmed Airbnb
// stays with a guest record, so only those are offered. An Airbnb link is the host's to share by hand; Cassy's Airbnb drafts never carry it.
import { withHeader } from '../_shared/cascade-core/format.ts';
import { monthDay } from '../_shared/cascade-core/brownout.ts';
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
export type Kind = 'direct' | 'airbnb';
export type Stay = { id: string; name: string; checkin: string; checkout: string; kind: Kind };
export type Tap = { id: string; kind: Kind };

/** The same filters intake_resolve_v1 applies: confirmed, a guest record, not checked out (Airbnb also: not cancelled). */
function stayQuery(d: Deps, kind: Kind, onlyId?: string) {
  let q = kind === 'direct'
    ? d.db.from('booking_inquiries').select('id,guest_id,checkin_date,checkout_date').eq('property_id', d.propertyId).eq('source', 'direct')
    : d.db.from('airbnb_reservations').select('id,guest_id,checkin_date,checkout_date').eq('property_id', d.propertyId).eq('source', 'airbnb').is('cancelled_at', null); // source: skip the DIRECT:<uuid> mirror rows
  q = q.eq('status', 'confirmed').not('guest_id', 'is', null).gte('checkout_date', d.today());
  if (onlyId) q = q.eq('id', onlyId); // a tap checks that one stay with the same filters, not the 8-item list
  return q.order('checkin_date', { ascending: true }).limit(8);
}

/** Stays the guest form can serve, direct and Airbnb together. Nearest first, max 8. */
export async function openStays(d: Deps, only?: Tap): Promise<Stay[] | null> {
  const kinds: Kind[] = only ? [only.kind] : ['direct', 'airbnb'];
  const reads = await Promise.all(kinds.map((k) => stayQuery(d, k, only?.id)));
  if (reads.some((r: any) => r.error)) return null;
  const rows = reads.flatMap((r: any, i) => ((r.data ?? []) as any[]).map((x) => ({ ...x, kind: kinds[i] })))
    .sort((a, b) => String(a.checkin_date).localeCompare(String(b.checkin_date))).slice(0, 8);
  if (!rows.length) return [];
  const g = await d.db.from('guests').select('id,name').in('id', rows.map((r) => r.guest_id));
  if (g.error) return null;
  const names = new Map<string, string>(((g.data ?? []) as any[]).map((x) => [x.id, String(x.name ?? '')]));
  return rows.map((r) => ({ id: r.id, name: names.get(r.guest_id) || 'Guest', checkin: r.checkin_date, checkout: r.checkout_date, kind: r.kind }));
}

export const stayLabel = (s: Stay, today: string) => `${s.name.slice(0, 24)} · ${monthDay(s.checkin)} to ${monthDay(s.checkout)}${s.kind === 'airbnb' ? ' · Airbnb' : ''}${s.checkin <= today ? ' · in house' : ''}`;
/** int:<uuid> is a direct stay, int:a:<uuid> an Airbnb one (one prefix, so the index router is unchanged). */
export const tapData = (s: Pick<Stay, 'id' | 'kind'>) => `int:${s.kind === 'airbnb' ? 'a:' : ''}${s.id}`;
export function parseIntakeTap(data: string): Tap | null {
  if (!data.startsWith('int:')) return null;
  const airbnb = data.startsWith('int:a:'), id = data.slice(airbnb ? 6 : 4);
  return UUID.test(id) ? { id, kind: airbnb ? 'airbnb' : 'direct' } : null;
}
/** D-323: the host decides whether and when an Airbnb guest gets the link. */
export const AIRBNB_HOST_NOTE = 'This is an Airbnb stay, so the link is yours to share with the guest when you choose.';

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
  if (!stays.length) { await d.send(chatId, withHeader('guest', 'guest link', 'No confirmed stay is current or upcoming, so there is nothing to send a link for.')); return; }
  const t = d.today();
  await d.send(chatId, withHeader('guest', 'guest link', 'Which stay is the link for? Tap it and I will make the link to forward to the guest.'),
    { reply_markup: { inline_keyboard: stays.map((s) => [{ text: stayLabel(s, t), callback_data: tapData(s) }]) } });
}

/** Every int: tap. */
export async function onIntakeTap(d: Deps, cq: any): Promise<void> {
  const chatId = cq.message?.chat?.id, mid = cq.message?.message_id, tap = parseIntakeTap(String(cq.data ?? ''));
  if (!tap) { await d.answer(cq.id, 'That button is not valid. Nothing was made.'); return; }
  if (!d.isFinance(chatId)) { await d.answer(cq.id, 'Finance group only. Nothing was made.'); return; }
  if (!(await isOwnerAdmin(d, cq.from?.id))) { await d.answer(cq.id, 'Only the owner or admin can make a guest link. Nothing was made.'); return; }
  const stay = (await openStays(d, tap))?.[0];
  if (!stay) { await d.answer(cq.id, 'That stay is no longer open. Nothing was made.'); return; }
  // Each tap mints a new token on purpose; older ones simply expire at check-out + 7 days.
  const tokens = d.db.from('guest_access_tokens') as TokenStore;
  // mintStatusToken writes booking_type 'direct'; an Airbnb stay overrides it here so the shared helper (and its bundlers) stay unchanged.
  const store: TokenStore = stay.kind === 'airbnb' ? { insert: (row) => tokens.insert({ ...row, booking_type: 'airbnb' }) } : tokens;
  const token = await mintStatusToken(store, { propertyId: d.propertyId, bookingId: stay.id, checkoutDate: stay.checkout });
  if (!token) { await d.answer(cq.id, 'I could not make the link. Nothing was made.'); return; }
  await d.answer(cq.id);
  // The card in the thread never holds the token; the link goes in one separate message that can be forwarded or copied.
  await d.edit(chatId, mid, withHeader('guest', 'guest link', `Link made for ${d.esc(stay.name)}, ${stay.checkin} to ${stay.checkout}. It is in the next message.${stay.kind === 'airbnb' ? `\n${AIRBNB_HOST_NOTE}` : ''}`));
  const first = stay.name.replace(/`/g, '').split(/\s+/)[0] || 'there';
  await d.send(chatId, guestLine(first, monthDay(stay.checkin), STAY_PAGE + token));
}
