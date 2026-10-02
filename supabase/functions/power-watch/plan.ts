// power-watch, planning and card wording (D-290, Lloyd 2026-10-02). Pure, so plan.test.ts reads every decision.
//
// The rule: block every night the outage touches. Night N is the guest night that checks in on N and out on N+1, from
// 14:00 on N to 12:00 on N+1. So an outage on D starting before 12:00 touches night D-1 (the guest is still checking out);
// one running past 14:00 touches night D (the guest has checked in). That is an overlap test against the stay window.
//   06:00-17:00 -> D-1 and D     18:00-20:00 -> D     08:00-11:00 -> D-1     13:00-15:00 -> D
// Nothing here writes to Airbnb. Marifel blocks Airbnb by hand; the cards exist to tell her at once.
import { autoKeyboard, doSend, groups, withHeader, type Btn } from '../_shared/cascade-core/format.ts';
import { addDays, brownoutUid, nightsList, nightsPhrase, pwData, type Guest, type NoticeState } from '../_shared/cascade-core/brownout.ts';
import { clock, dayLabel, endOf, FEEDER } from './poster.ts';

// House facts, 2026-10-02 (topics ecoflow, power-outage): the EcoFlow RIVER 3 sits near the TV unit, the charged emergency
// light is on top of the fridge, the router has backup power. The Airbnb template says "inside the cabinet near the TV": house_facts wins.
export const ECOFLOW_PLACE = 'near the TV unit';
export const LIGHT_PLACE = 'on top of the fridge';

const mins = (t: string) => +t.slice(0, 2) * 60 + +t.slice(3, 5);

/**
 * Nights (YYYY-MM-DD) an outage on `date` touches. Unknown start counts as the whole morning (from 00:00), unknown
 * length as running to midnight, so a poster with no times blocks the night before and the night of: the safe side.
 */
export function touchedNights(date: string, time: string | null, hours: number | null): string[] {
  const s = time ? mins(time) : 0;
  const e = hours && hours > 0 ? s + Math.round(hours * 60) : Math.max(s, 1440);
  const out: string[] = [];
  for (let k = -1; k <= Math.ceil(e / 1440); k++) {
    const stayStart = k * 1440 + 14 * 60, stayEnd = (k + 1) * 1440 + 12 * 60;
    if (s < stayEnd && e > stayStart) out.push(addDays(date, k));
  }
  return out;
}

export type Row = { uid: string; source: string; status: string; checkin_date: string; checkout_date: string; guest_name?: string | null };
const covers = (r: Row, night: string) => r.status !== 'cancelled' && r.checkin_date <= night && r.checkout_date > night;
const isGuest = (r: Row) => r.source === 'direct' || (r.status === 'confirmed' && (r.source === 'airbnb' || r.source === 'manual'));

/**
 * For each touched night, tonight or later: a guest in the house (never blocked), already ours, already blocked by
 * something else (an Airbnb block, an admin block: said so, not blocked again), or free (we block it).
 */
export function classifyNights(nights: string[], rows: Row[], today: string): { toBlock: string[]; held: string[]; already: string[]; guests: Guest[] } {
  const out = { toBlock: [] as string[], held: [] as string[], already: [] as string[], guests: [] as Guest[] };
  for (const night of nights.filter((n) => n >= today)) {
    const on = rows.filter((r) => covers(r, night));
    const g = on.find(isGuest);
    if (g) out.guests.push({ night, name: String(g.guest_name ?? '').trim() });
    else if (on.some((r) => r.uid === brownoutUid(night) && r.source === 'manual')) out.held.push(night);
    else if (on.length) out.already.push(night);
    else out.toBlock.push(night);
  }
  return out;
}

/** An Airbnb row (a block or a stay) on every one of these nights: Marifel's block has come back through the iCal feed. */
export function airbnbCovers(nights: string[], rows: Row[]): boolean {
  return nights.length > 0 && nights.every((n) => rows.some((r) => r.source === 'airbnb' && covers(r, n)));
}

export const THREE_HOURS_MS = 3 * 3_600_000;
/** One reminder, three hours after the card, while nothing says Airbnb is blocked and nobody tapped Done. */
export function reminderDue(st: NoticeState, rows: Row[], now: Date, today: string): boolean {
  if (st.status !== 'active' || st.card || st.cancelAskedAt || !st.cardAt || st.doneAt || st.seenAt || st.remindedAt || !st.blocked.length) return false;
  if (st.blocked[st.blocked.length - 1] < today) return false;
  if (airbnbCovers(st.blocked, rows)) return false;
  return now.getTime() - Date.parse(st.cardAt) >= THREE_HOURS_MS;
}
export const seenDue = (st: NoticeState, rows: Row[]) =>
  st.status === 'active' && !st.card && !st.cancelAskedAt && !!st.cardAt && !st.seenAt && st.blocked.length > 0 && airbnbCovers(st.blocked, rows);

// ── wording ──────────────────────────────────────────────────────────────────────────────────────────────────────────
/** '06:00-17:00' (24-hour, as the poster prints it). */
export function timeLabel(time: string | null, hours: number | null): string {
  const end = endOf(time, hours);
  return time ? `${time.slice(0, 5)}${end ? `-${end}` : ' onward'}` : 'times not shown on the poster';
}
/** 'Thu 15 Oct, 06:00-17:00' for staff. */
export function windowLabel(date: string, time: string | null, hours: number | null): string {
  return time ? `${dayLabel(date)}, ${timeLabel(time, hours)}` : `${dayLabel(date)} (${timeLabel(time, hours)})`;
}
/** 'Thu 15 Oct, 6:00 AM to 5:00 PM' for a guest. */
export function guestWindow(date: string, time: string | null, hours: number | null): string {
  const end = endOf(time, hours);
  return `${dayLabel(date)}${time ? `, ${end ? `${clock(time)} to ${clock(end)}` : `from ${clock(time)}`}` : ''}`;
}

/** The draft for a guest in the house: the window, what is ready and where, and that we are a message away. Cassy voice (D-167).
 *  One paragraph on purpose: the 📨 text of a card ends at the first blank line (templateOf), and the voice lint wants 320 characters or fewer. */
export function guestDraft(name: string, date: string, time: string | null, hours: number | null, changed = false): string {
  const first = name.split(/\s+/)[0];
  const hi = first ? `Hi ${first}, a quick heads-up:` : 'Hi, a quick heads-up:';
  const when = guestWindow(date, time, hours);
  const what = changed ? `Socoteco has moved the power interruption to ${when}.` : `Socoteco has scheduled a power interruption on ${when}.`;
  return `${hi} ${what} The Wi-Fi router has backup power, the EcoFlow ${ECOFLOW_PLACE} is charged for phones and a fan, and a charged emergency light is ${LIGHT_PLACE}. We are a message away if you need anything. 🌿`;
}

export type Built = { text: string; markup: { inline_keyboard: Btn[][] } | undefined };
const doneUndo = (date: string): Btn[] => [{ text: '✅ Blocked in Airbnb', callback_data: pwData('done', date) }, { text: '↩ Undo block', callback_data: pwData('undo', date) }];
const header = (subject: string, body: string) => withHeader('attention', subject, body);
const subjectOf = (date: string) => `brownout ${dayLabel(date)}`;

/** Guests grouped by name, in night order: Anna on Oct 14 and 15 is one guest. */
export function guestGroups(guests: Guest[]): Array<{ name: string; nights: string[] }> {
  const by = new Map<string, string[]>();
  for (const g of guests) by.set(g.name, [...(by.get(g.name) ?? []), g.night]);
  return [...by].map(([name, nights]) => ({ name, nights }));
}
const who = (name: string) => name || 'A guest';
const ifs = (c: unknown, text: string): string | false => (c ? text : false);
/** Last line of every card that asks someone to act: the SOCOTECO poster itself (Telegram makes it a link). */
const source = (st: NoticeState): Array<string | false> => [ifs(st.url, `SOCOTECO notice: ${st.url}`)];

function guestLines(st: NoticeState, g: { name: string; nights: string[] }, changed: boolean): Array<string | false> {
  return [
    `${who(g.name)} is staying the ${nightsPhrase(g.nights)}.`,
    `Prep: EcoFlow at 100% the day before, emergency light ${LIGHT_PLACE}.`,
    ...doSend(g.name || 'the guest', guestDraft(g.name, st.date, st.time, st.hours, changed)),
  ];
}

/** The first card of an outage: the blocks, what Marifel does in Airbnb, and the guest part when someone is staying. */
export function newCard(st: NoticeState): Built {
  const gs = guestGroups(st.guests);
  const body = groups(
    [`⚡ SOCOTECO power interruption ${windowLabel(st.date, st.time, st.hours)} (Feeder ${FEEDER}).`],
    [
      ifs(st.blocked.length, `Blocked on our booking site: ${nightsPhrase(st.blocked)}.`),
      ifs(st.already.length, `Already blocked, so nothing was added: ${nightsPhrase(st.already)}.`),
      ifs(st.guests.length, `Not blocked, a guest is in the house: ${nightsPhrase(st.guests.map((g) => g.night))}.`),
      ifs(!st.nights.length, 'No night is touched from today on.'),
    ],
    [ifs(st.blocked.length, `Marifel: block the same ${st.blocked.length === 1 ? 'night' : 'nights'} in Airbnb now.`)],
    gs.length ? guestLines(st, gs[0], false) : [],
    source(st),
  );
  const text = header(subjectOf(st.date), body);
  return { text, markup: autoKeyboard(text, st.blocked.length ? doneUndo(st.date) : []) };
}

/** Each further guest beyond the first gets a card of their own (a card carries one 📨 draft). */
export function extraGuestCards(st: NoticeState, changed = false): Built[] {
  return guestGroups(st.guests).slice(1).map((g) => {
    const text = header(subjectOf(st.date), groups([`⚡ Same interruption, ${windowLabel(st.date, st.time, st.hours)}.`], guestLines(st, g, changed)));
    return { text, markup: autoKeyboard(text) };
  });
}

/** SOCOTECO posted new times for a date we already announced. */
export function changedCard(st: NoticeState): Built {
  const prev = st.card?.prev;
  const was = prev ? timeLabel(prev.time, prev.hours) : '';
  const added = st.blocked.filter((n) => !(prev?.blocked ?? []).includes(n));
  const dropped = (prev?.blocked ?? []).filter((n) => !st.blocked.includes(n));
  const gs = guestGroups(st.guests);
  const body = groups(
    [`⚡ SOCOTECO changed the power interruption on ${dayLabel(st.date)} (Feeder ${FEEDER}).`,
      `Now ${timeLabel(st.time, st.hours)}${was ? `, was ${was}` : ''}.`],
    [
      ifs(added.length, `Now blocked on our booking site: ${nightsPhrase(added)}.`),
      ifs(dropped.length, `Released on our booking site: ${nightsPhrase(dropped)}.`),
      ifs(st.blocked.length && !added.length && !dropped.length, `The ${st.blocked.length === 1 ? 'night' : 'nights'} blocked stay the same: ${nightsList(st.blocked)}.`),
      ifs(st.already.length, `Already blocked, so nothing was added: ${nightsPhrase(st.already)}.`),
      ifs(st.guests.length, `Not blocked, a guest is in the house: ${nightsPhrase(st.guests.map((g) => g.night))}.`),
    ],
    [
      ifs(added.length, `Marifel: block ${nightsPhrase(added)} in Airbnb now.`),
      ifs(dropped.length, `Marifel: unblock ${nightsPhrase(dropped)} in Airbnb if you blocked ${dropped.length === 1 ? 'it' : 'them'}.`),
    ],
    gs.length ? guestLines(st, gs[0], true) : [],
    source(st),
  );
  const text = header(subjectOf(st.date), body);
  return { text, markup: autoKeyboard(text, added.length ? doneUndo(st.date) : []) };
}

/** SOCOTECO cancelled or moved an outage we blocked: ask before anything is released, because Airbnb is Marifel's. */
export function cancelCard(st: NoticeState): Built {
  const note = st.card?.note ?? 'cancelled';
  const held = st.blocked;
  const body = groups(
    [`⚡ SOCOTECO ${note} the power interruption on ${dayLabel(st.date)} (Feeder ${FEEDER}).`],
    [held.length
      ? `Unblock ${nightsPhrase(held)} on our booking site and in Airbnb?`
      : 'Nothing was blocked on our booking site for it. Tap Unblock to take it off the operations board.'],
    source(st),
  );
  const text = header(subjectOf(st.date), body);
  return { text, markup: autoKeyboard(text, [{ text: '🔓 Unblock', callback_data: pwData('unblock', st.date) }]) };
}

/** Three hours on, Airbnb still shows no block and nobody tapped Done. */
export function reminderCard(st: NoticeState): Built {
  const body = groups(
    [`⚡ Reminder: Airbnb is not blocked yet for the SOCOTECO interruption on ${windowLabel(st.date, st.time, st.hours)}.`],
    [`Marifel: block ${nightsPhrase(st.blocked)} in Airbnb, then tap Blocked in Airbnb.`],
    source(st),
  );
  const text = header(subjectOf(st.date), body);
  return { text, markup: autoKeyboard(text, [{ text: '✅ Blocked in Airbnb', callback_data: pwData('done', st.date) }]) };
}

/** The iCal feed now shows Airbnb blocked on every night we hold. */
export function seenCard(st: NoticeState): Built {
  const text = header(subjectOf(st.date), `✅ Airbnb block seen for ${nightsPhrase(st.blocked)} (SOCOTECO interruption ${dayLabel(st.date)}).`);
  return { text, markup: undefined };
}

/** The line the host e-mail carries about the blocking. */
export function nightsLine(st: NoticeState): string {
  return [
    ifs(st.blocked.length, `Blocked on our booking site: ${nightsPhrase(st.blocked)}. Marifel blocks the same ${st.blocked.length === 1 ? 'night' : 'nights'} in Airbnb by hand.`),
    ifs(st.already.length, `Already blocked: ${nightsPhrase(st.already)}.`),
    ifs(st.guests.length, `A guest is in the house on ${nightsPhrase(st.guests.map((g) => g.night))}, so no block there.`),
  ].filter(Boolean).join(' ');
}
