// SPEC-11 session 2: what a verifier run says out loud.
//
// Pure. No network, no Deno APIs beyond crypto.subtle, so verifier.test.ts can
// read every card as a string. index.ts does the talking.
//
// The shape the spec asks for: every red gets its own ALERT card, because a red
// finding is one thing one person has to go and do. Every yellow shares ONE
// ATTENTION card, because five small things read at 07:45 are a list, not five
// interruptions. Resolved findings are a footer on that card and never a card
// of their own - nobody needs a notification to say nothing is wrong.
//
// Cards are written for a person reading a phone between two other things
// (Lloyd, 2026-09-19): what happened, who has to act, plain sentences, ids last.

import { withHeader, groups, doSend, DASH_URL } from '../_shared/cascade-core/format.ts';

export type Severity = 'red' | 'yellow';
export type Finding = {
  key: string;
  check_id: string;
  severity: Severity;
  title: string;
  detail?: Record<string, unknown> | null;
};
export type Resolved = { key: string; title: string; auto?: boolean };
export type Applied = { new?: Finding[]; remind?: Finding[]; resolved?: Resolved[] };

/** A card, and the finding key its [Known] button should acknowledge. */
export type Card = { to: 'finance' | 'ops'; text: string; ackKey?: string };

// V6 (a guest arriving without ID) and V7 are the day's work, not the money.
const OPS_CHECKS = new Set(['V6', 'V7']);
const audienceOf = (checkId: string): 'finance' | 'ops' => (OPS_CHECKS.has(checkId) ? 'ops' : 'finance');

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** '2026-10-21' -> '21 Oct'. Anything unparseable comes back as it arrived. */
export function dm(d: unknown): string {
  const s = String(d ?? '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return String(d ?? '');
  const x = new Date(s + 'T00:00:00Z');
  return `${x.getUTCDate()} ${MON[x.getUTCMonth()]}`;
}

/** How long ago, in the roundest honest unit. */
export function ago(since: unknown, now: Date): string {
  const t = Date.parse(String(since ?? ''));
  if (!Number.isFinite(t)) return 'some time ago';
  const h = Math.floor((now.getTime() - t) / 3_600_000);
  if (h < 1) return 'less than an hour ago';
  if (h < 48) return `${h} hours ago`;
  return `${Math.floor(h / 24)} days ago`;
}

const str = (v: unknown, fallback = '') => {
  const s = String(v ?? '').trim();
  return s === '' || s === 'null' || s === 'undefined' ? fallback : s;
};

/** The first line of a card: what happened, in a sentence. */
function headline(f: Finding, now: Date): string {
  const d = (f.detail ?? {}) as Record<string, any>;
  switch (f.check_id) {
    case 'V1':
      return 'Two stays are booked over the same nights. One of them has to go before either guest travels.';
    case 'V2':
      return `${str(d.guest, 'A guest')} is confirmed but holds no place on the calendar, so those nights can still be sold to somebody else.`;
    case 'V3':
      return `The calendar is holding nights for ${str(d.guest, 'a booking')} that nothing live is behind, so they look taken and are not.`;
    case 'V4':
      return `${str(d.guest, 'A guest')} stopped at the payment step on Messenger ${ago(d.since, now)} and has not been helped since.`;
    case 'V5':
      return `${str(d.guest, 'A guest')} asked something ${ago(d.since, now)} and nobody has answered.`;
    case 'V6':
      return `${str(d.guest, 'A guest')} arrives ${dm(d.arrives)} and has no ID on file.`;
    case 'V11':
      return `The Concierge has been on ${str(d.mode, 'manual')} since ${ago(d.since, now)}, so guest messages are waiting for a person.`;
    case 'V12':
      return d.last_good_sync
        ? `The Airbnb calendar last synced ${ago(d.last_good_sync, now)}. A booking landing now would not be seen.`
        : 'The Airbnb calendar has never synced successfully. A booking landing now would not be seen.';
    case 'V10':
      return f.key === 'V10:stale'
        ? `System health last ran ${ago(d.last_run, now)}, so the numbers below are older than they look.`
        : `System health: ${f.title.toLowerCase()}, ${str(d.n, '0')} to look at.`;
    default:
      return f.title;
  }
}

/** The middle group: the facts a person needs in order to act. Ids last. */
function facts(f: Finding): string[] {
  const d = (f.detail ?? {}) as Record<string, any>;
  switch (f.check_id) {
    case 'V1': {
      const one = (x: any) => `${str(x?.guest, 'unnamed')} · ${str(x?.source, 'unknown source')} · ${dm(x?.from)} to ${dm(x?.to)}`;
      return [one(d.a), one(d.b), `ids ${str(d.a?.id).slice(0, 8)} and ${str(d.b?.id).slice(0, 8)}`];
    }
    case 'V2':
      return [`${dm(d.from)} to ${dm(d.to)}`, `id ${str(d.booking).slice(0, 8).toUpperCase()}`];
    case 'V3':
      return [
        `${dm(d.from)} to ${dm(d.to)}`,
        d.inquiry_status ? `The booking behind it is ${str(d.inquiry_status)}.` : 'Nothing is behind it at all.',
        `id ${str(d.event).slice(0, 8)}`,
      ];
    case 'V4':
      return [`${dm(d.from)} to ${dm(d.to)}`, d.email ? `Reachable at ${str(d.email)}` : '', `Stopped at: ${str(d.step, 'the money step')}`];
    case 'V5':
      return [d.asked ? `They asked: ${str(d.asked)}` : '', d.risk ? `Risk: ${str(d.risk)}` : ''];
    case 'V6':
      return [`id ${str(d.booking).slice(0, 8).toUpperCase()}`];
    case 'V10':
      // No `check: payout_rows_linked` line. The headline already says which
      // check in words, and a key=value line is the thing Lloyd asked not to
      // see on a card (2026-09-19).
      return f.key === 'V10:stale' || !d.accepted
        ? []
        : ['This pair was gone through on 14 Sep and is fine. It will speak up again only if the count changes.'];
    default:
      return [];
  }
}

/** The last group: the one thing to do. */
function action(f: Finding): string {
  switch (f.check_id) {
    case 'V1': return 'open the calendar, decide which stay is real, and cancel the other.';
    case 'V2': return 'open the booking and put its block back on the calendar.';
    case 'V3': return 'cancel the hold, or find the booking it belongs to.';
    case 'V4': return 'open Messenger and finish the booking with them, or close the conversation.';
    case 'V5': return 'answer the guest, then dismiss the handoff.';
    case 'V6': return 'ask for the ID before they arrive.';
    case 'V11': return 'put the Concierge back on auto in Settings, or leave it and keep answering by hand.';
    case 'V12': return 'check the Airbnb feed and the sync job before taking another booking.';
    case 'V10': return f.key === 'V10:stale' ? 'open Settings, System health, and run it.' : 'open Settings, System health, and work through this check.';
    default: return 'open the dashboard.';
  }
}

const LINK: Record<string, string> = {
  V1: `${DASH_URL}calendar`,
  V2: `${DASH_URL}bookings`,
  V3: `${DASH_URL}calendar`,
  V4: `${DASH_URL}concierge`,
  V5: `${DASH_URL}concierge`,
  V6: `${DASH_URL}bookings`,
  V10: `${DASH_URL}settings`,
  V11: `${DASH_URL}settings`,
  V12: `${DASH_URL}calendar`,
};

/** One red finding, one card. */
export function redCard(f: Finding, now: Date): Card {
  const link = LINK[f.check_id];
  // V1 alone carries a ready-to-send line. An overlap is the one finding where
  // somebody has to talk to a guest before anything is decided, and the line is
  // deliberately neutral: it promises an answer, never a cancellation, because
  // which booking is the real one is exactly what nobody knows yet.
  const first = str((f.detail as any)?.a?.guest, 'the guest').split(' ')[0];
  const sample = f.check_id === 'V1'
    ? doSend(
        first,
        `Hello ${first}, I am looking into the dates on your stay at Cascade Hideaway and will come back to you within the hour. Nothing on your booking has changed.`,
      )
    : [];
  // One Do per card. doSend opens with 'Do: send ...', so a card that carries a
  // sendable line states its own instruction as a sentence instead of claiming
  // a second Do - two of them on one card is two instructions, and the person
  // reading it at 07:45 follows the first.
  const instruction = sample.length
    ? action(f).charAt(0).toUpperCase() + action(f).slice(1)
    : `Do: ${action(f)}`;
  return {
    to: audienceOf(f.check_id),
    ackKey: f.key,
    text: withHeader('alert', f.title.toLowerCase(), groups(
      [headline(f, now)],
      facts(f),
      [instruction, link ? link : ''],
      sample,
    )),
  };
}

/** One bullet in the shared yellow card. */
export function yellowBullet(f: Finding, now: Date): string {
  // In a list of six V10 findings, 'System health:' on every line is six words
  // of nothing. The card's Do line already says where they came from.
  return headline(f, now).replace(/^System health: /, '');
}

/**
 * Every yellow for one audience in ONE card, at most five bullets. When there
 * are more than five the fifth says how many are not shown, rather than
 * silently dropping them: renderReport caps at five by skipping the rest, which
 * is the wrong behaviour for a list somebody is meant to work through.
 */
export function yellowCard(
  findings: Finding[],
  resolved: Resolved[],
  audience: 'finance' | 'ops',
  now: Date,
  today: string,
): Card | null {
  if (findings.length === 0 && resolved.length === 0) return null;

  const out: string[] = [];
  if (findings.length === 1) out.push(headline(findings[0], now));
  else if (findings.length > 1) out.push(`${findings.length} things are worth a look.`);
  else out.push('Nothing needs you. These closed themselves.');

  const bullets = findings.length > 5
    ? [...findings.slice(0, 4).map((f) => `• ${yellowBullet(f, now)}`), `• and ${findings.length - 4} more in the dashboard`]
    : findings.length > 1
      ? findings.map((f) => `• ${yellowBullet(f, now)}`)
      : [];
  if (bullets.length) out.push('', ...bullets);

  if (findings.length === 1) out.push('', `Do: ${action(findings[0])}`);
  else if (findings.length > 1) out.push('', 'Do: open Settings, System health, and take them in order.');

  if (resolved.length) {
    const names = resolved.slice(0, 3).map((r) => r.title + (r.auto ? ' (closed itself)' : ''));
    const more = resolved.length > 3 ? ` and ${resolved.length - 3} more` : '';
    out.push('', `Resolved: ${names.join('; ')}${more}`);
  }

  return {
    to: audience,
    ackKey: findings.length === 1 ? findings[0].key : undefined,
    text: withHeader('attention', `system check · ${today}`, out.join('\n')),
  };
}

/** Every card a run should send, in the order it should send them. */
export function buildCards(applied: Applied, now: Date, today: string): Card[] {
  const loud = [...(applied.new ?? []), ...(applied.remind ?? [])];
  const reds = loud.filter((f) => f.severity === 'red');
  const yellows = loud.filter((f) => f.severity !== 'red');
  const resolved = applied.resolved ?? [];

  const cards: Card[] = reds.map((f) => redCard(f, now));
  for (const audience of ['finance', 'ops'] as const) {
    // Resolutions ride with Finance; OPS hears only when OPS has something open.
    const mine = yellows.filter((f) => audienceOf(f.check_id) === audience);
    const card = yellowCard(mine, audience === 'finance' ? resolved : [], audience, now, today);
    if (card) cards.push(card);
  }
  return cards;
}

// The button's short name for a finding. Defined in _shared so that
// telegram-expense, which reads it back, does not have to bundle this file.
export { ackHash } from '../_shared/ack-hash.ts';
