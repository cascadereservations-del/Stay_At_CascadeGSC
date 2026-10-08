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

import { withHeader, groups, doSend, DASH_URL, pesoOrNull } from '../_shared/cascade-core/format.ts';
import { problemSentence, problemSubject } from '../_shared/cascade-core/health-labels.ts';

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

// V6 (a guest arriving without ID) is the day's work, not the money. V7/V7b go to Finance, where the
// Airbnb new-booking card already lands (SPEC-24).
const OPS_CHECKS = new Set(['V6']);
const airbnbUrl = (code: unknown) => (str(code) ? `https://www.airbnb.com/hosting/reservations/details/${str(code)}` : '');
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


// The problem sentences live in _shared/cascade-core/health-labels.ts (SPEC-18) so the digest and
// the card cannot drift apart again. Money here is null-safe (SPEC-19): a row whose amount cannot be
// read names the row without an amount, and never prints a zero that claims the books balance.
const peso = (v: unknown) => pesoOrNull(v);
const parts = (...xs: Array<string | null | undefined>) => xs.filter((x): x is string => !!x).join(', ');

/** The rows behind a health check, named so somebody can act without opening the dashboard. */
function healthRows(check: string, d: Record<string, any>): string[] {
  const rows: any[] = Array.isArray(d?.d) ? d.d : [];
  const take = rows.slice(0, 3);
  const more = rows.length > 3 ? [`and ${rows.length - 3} more`] : [];
  switch (check) {
    case 'inventory_ledger_consistent':
      return [...take.map((r) => `${str(r.item, 'an item')}: counted ${r.onHand}, last movement said ${r.lastMovement}`), ...more];
    case 'checkouts_cleaned':
      return [...take.map((r) => `${str(r.guest, 'a guest')} checked out ${dm(r.checkout)}`), ...more];
    case 'completed_stays_paid':
      return [...take.map((r) => parts(`${str(r.guest, 'a guest')}, out ${dm(r.checkout)}`, peso(r.payout))), ...more];
    case 'cleaner_fees_settled':
      return [...take.map((r) => parts(`${str(r.guest, 'a clean')} on ${dm(r.cleaned)}`, peso(r.fee), r.paid ? `paid ${dm(r.paid)}` : null)), ...more];
    case 'payout_rows_linked':
      return [...take.map((r) => parts(dm(r.date), peso(r.amount))), ...more];
    case 'ledger_duplicates':
      return [...take.map((r) => parts(dm(r.date), str(r.payee, 'unnamed'), peso(r.amount) && `${peso(r.amount)} x${r.n}`)), ...more];
    case 'meter_readings_reviewed':
      return [...take.map((r) => `reading of ${dm(r.recorded)}`), ...more];
    case 'concierge_handoffs_open':
      return [...take.map((r) => `${str(r.guest, 'a guest')}`), ...more];
    case 'journals_balanced':
      return [...take.map((r) => peso(r.debits) && peso(r.credits) ? `journal ${str(r.journalNo)}: ${peso(r.debits)} against ${peso(r.credits)}` : `journal ${str(r.journalNo)}`), ...more];
    case 'payout_totals_agree':
      return [parts(peso(d?.d?.reservationPayouts) && `reservations ${peso(d?.d?.reservationPayouts)}`, peso(d?.d?.payoutEmails) && `e-mails ${peso(d?.d?.payoutEmails)}`, peso(d?.d?.adjustments) && `adjustments ${peso(d?.d?.adjustments)}`)];
    case 'ledger_position':
      return [parts(peso(d?.d?.income) && `income ${peso(d?.d?.income)}`, peso(d?.d?.expenses) && `expenses ${peso(d?.d?.expenses)}`, peso(d?.d?.drawings) && `drawings ${peso(d?.d?.drawings)}`)];
    default:
      return [];
  }
}


// ── API governor cards (V14-V18, D-294) ────────────────────────────────────────────────────────────────────────────────
// Lloyd: say the EXACT value and WHERE to change it; the system never changes an external cap itself. Every number
// here arrives already rounded (governor.ts), so these only print.
const GOVERNOR = new Set(['V14', 'V15', 'V16', 'V17', 'V18']);
const amt = (unit: unknown, v: unknown) =>
  unit === 'neurons' ? `${Math.round(Number(v)).toLocaleString('en-US')} neurons` : `USD ${Number(v).toFixed(2)}`;
const PROVIDER_NAME: Record<string, string> = { openrouter: 'OpenRouter', gemini: 'Gemini', omniroute: 'OmniRoute' };
const PROVIDER_FIX: Record<string, string> = {
  openrouter: 'check status.openrouter.ai and the key at openrouter.ai/settings/keys.',
  gemini: 'check the Gemini key and its quota at aistudio.google.com.',
  omniroute: 'check OmniRoute on the alfred host (ssh -L 20129:localhost:20129 alfred), then its Cloudflare and Groq steps.',
};

// Every governor detail holds bands and a recommended value, never an amount that moves (D-217.2, see governor.ts), so these
// cards print no evidence numbers: an acknowledged card must read the same tomorrow.
const V17_SPAN: Record<string, string> = { '<7': 'less than a week', '7-13': 'one to two weeks', '14-29': 'two to four weeks' };
/** The last step of every value a governor card asks for: the same number into api_caps. For an OpenRouter key it keeps the
 *  fallback true; for OmniRoute it is the only way the governor learns the new limit, because nothing reads it live. */
const capsStep = (d: Record<string, any>) => d.reads_live
  ? `then also set "cap" for ${str(d.cap_id)} to ${Number(d.recommended)} in Supabase app_settings, key api_caps, so the fallback matches.`
  : `then set "cap" for ${str(d.cap_id)} to ${Number(d.recommended)} in Supabase app_settings, key api_caps: nothing reads this limit live, so the governor only knows it from there.`;

function governorHeadline(f: Finding): string {
  const d = (f.detail ?? {}) as Record<string, any>;
  switch (f.check_id) {
    case 'V14': {
      const cap = amt(d.unit, d.cap);
      const lead = d.projected
        ? `${str(d.label, 'A model key')} is on course to pass its daily limit of ${cap}.`
        : Number(d.pct) >= 100
          ? `${str(d.label, 'A model key')} has reached its daily limit of ${cap}.`
          : `${str(d.label, 'A model key')} has used at least ${Number(d.pct ?? 0)}% of its daily limit of ${cap}.`;
      return `${lead} At the limit it stops answering until its next reset.`;
    }
    case 'V15':
      return `${PROVIDER_NAME[str(d.provider)] ?? str(d.provider, 'A provider')} failed ${str(d.fail_band, 'most')}% of its ${str(d.title, 'model')} calls over the last two days.`;
    case 'V16':
      return d.direction === 'raise'
        ? `${str(d.label)} is set close to what a busy normal day needs, so a heavy day could hit the limit.`
        : `${str(d.label)} allows far more a day than its busiest normal day needs.`;
    case 'V17':
      return `The OpenRouter credit lasts ${V17_SPAN[str(d.days)] ?? `about ${str(d.days)} days`} at the recent rate of spend.${f.severity === 'red' ? ' Guest replies stop when it runs out.' : ''}`;
    case 'V18':
      return `${str(d.title, 'A feature')}${d.probe ? ' test runs' : ''} cost more than ${Number(d.x ?? 2)}x their usual in the last 7 days.`;
    default:
      return f.title;
  }
}

function governorFacts(f: Finding): string[] {
  const d = (f.detail ?? {}) as Record<string, any>;
  switch (f.check_id) {
    case 'V14':
      return [
        d.estimate ? 'Counted from token totals at list price over the Manila day, so it is an estimate.' : '',
        d.approx ? 'Some calls used a model with no list price; they are counted at the average Cloudflare price.' : '',
        d.advice === 'V16' ? 'The value to set is in the limit advice on the system check card.' : '',
      ];
    case 'V15':
      return ['A free provider that fails while a paid one answers still counts: the paid one is covering for it.'];
    case 'V16':
      return [
        'Advice only: nothing is failing.',
        d.reads_live ? "Measured from the key's own spend, which includes test runs." : '',
      ];
    case 'V17':
      return [d.source === 'estimate' ? 'The credit is an estimate: the total in app_settings api_caps minus what both keys have used.' : ''];
    case 'V18':
      return [
        d.cause === 'test_runs' ? "Most of that feature's spend is test runs." : '',
        d.cause === 'reasoning' ? 'Reasoning-heavy image reads: hidden thinking tokens dominate the cost.' : '',
      ];
    default:
      return [];
  }
}

function governorAction(f: Finding): string {
  const d = (f.detail ?? {}) as Record<string, any>;
  switch (f.check_id) {
    case 'V14':
      if (d.fixed) return `cut the calls behind it, because the limit cannot be raised (${str(d.where)}).`;
      if (d.recommended == null) return 'find what is calling it so much; the value to set is in the limit advice on the system check card.';
      return `set the ${str(d.label)} limit from ${amt(d.unit, d.cap)} to ${amt(d.unit, d.recommended)} at ${str(d.where)} (or find what is calling it so much), ${capsStep(d)}`;
    case 'V15':
      return PROVIDER_FIX[str(d.provider)] ?? 'check the provider status page and the key.';
    case 'V16':
      return `set the ${str(d.label)} limit to ${amt(d.unit, d.recommended)} at ${str(d.where)}, ${capsStep(d)}`;
    case 'V17':
      return `top up about ${amt('usd', d.topup)} at openrouter.ai > Settings > Credits${d.source === 'estimate' ? ', then set credit.openrouter_usd in app_settings api_caps to the new total credit you have bought' : ''}.`;
    case 'V18':
      return d.cause === 'reasoning'
        ? 'find which model reads the images and lower its reasoning effort, or move to a cheaper vision model.'
        : d.cause === 'test_runs'
          ? 'find the script or schedule that keeps running the test, and stop it.'
          : 'open the llm_usage table in Supabase, group by title and day, and find the day it jumped.';
    default:
      return 'open the dashboard.';
  }
}

/** The first line of a card: what happened, in a sentence. */
function headline(f: Finding, now: Date): string {
  const d = (f.detail ?? {}) as Record<string, any>;
  if (GOVERNOR.has(f.check_id)) return governorHeadline(f);
  switch (f.check_id) {
    case 'V1':
      // s77: V1m (same check, key V1m:) is our own Airbnb block for a direct stay running past the stay.
      if (f.key.startsWith('V1m:')) return `Our Airbnb block for ${str(d.guest, 'a direct guest')} covers nights outside their stay, so nights nobody is staying cannot be booked.`;
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
    case 'V7':
      return 'The Airbnb calendar and the booking e-mail disagree on dates, and this one could not be corrected automatically.';
    case 'V7b':
      return `An Airbnb stay ${dm(d.from)} to ${dm(d.to)} has no booking e-mail after 24 hours.`;
    case 'V8':
      return `The same payment receipt is on two live bookings, ${str(d.a?.guest, 'one guest')} and ${str(d.b?.guest, 'another guest')}, so one payment may be counted twice.`;
    case 'V13':
      return d.refused
        ? 'The OpenRouter key was refused, so guest replies and receipt reads are failing.'
        : `Only ${Number(d.left_pct ?? 0)}% of today's USD ${Number(d.limit ?? 0).toFixed(2)} model budget is left. At zero, guests get the host handoff line instead of an answer until it resets at 08:00 Manila.`;
    case 'V11':
      return `The Concierge has been on ${str(d.mode, 'manual')} since ${ago(d.since, now)}, so guest messages are waiting for a person.`;
    case 'V12':
      return d.last_good_sync
        ? `The Airbnb calendar last synced ${ago(d.last_good_sync, now)}. A booking landing now would not be seen.`
        : 'The Airbnb calendar has never synced successfully. A booking landing now would not be seen.';
    case 'V10':
      return f.key === 'V10:stale'
        ? `System health last ran ${ago(d.last_run, now)}, so the numbers below are older than they look.`
        : problemSentence(str(d.check), Number(d.n ?? 0), d);
    default:
      return f.title;
  }
}

/** The middle group: the facts a person needs in order to act. Ids last. */
function facts(f: Finding): string[] {
  const d = (f.detail ?? {}) as Record<string, any>;
  if (GOVERNOR.has(f.check_id)) return governorFacts(f);
  switch (f.check_id) {
    case 'V1': {
      if (f.key.startsWith('V1m:')) return [`direct stay ${dm(d.stay_from)} to ${dm(d.stay_to)}`, `Airbnb block ${dm(d.block_from)} to ${dm(d.block_to)}`, `block id ${str(d.block).slice(0, 8)}`];
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
    case 'V7':
      return [
        `${str(d.guest, 'Unnamed guest')}, ${str(d.code)}. The booking e-mail says ${dm(d.email_from)} to ${dm(d.email_to)}. The Airbnb calendar says ${dm(d.calendar_from)} to ${dm(d.calendar_to)}.`,
        airbnbUrl(d.code),
      ];
    case 'V7b':
      return [`Code ${str(d.code, 'unknown')}, first seen ${dm(d.since)}.`, airbnbUrl(d.code)];
    case 'V8': {
      // s78 (TASKS #20a): which sameness was found, in words; the reference in full, because it is what the wallet shows.
      const m: string[] = Array.isArray(d.match) ? d.match : [];
      const how = [m.includes('image') ? 'the same image' : '', m.includes('reference') ? `the same reference ${str(d.reference)}` : '',
        m.includes('amount_time') ? 'the same amount uploaded within 30 minutes' : ''].filter(Boolean).join(', ');
      const one = (x: any) => `${str(x?.guest, 'unnamed')} · ${str(x?.status, 'unknown')} · ${dm(x?.from)} to ${dm(x?.to)} · id ${str(x?.booking).slice(0, 8).toUpperCase()}`;
      return [how ? `Matched on ${how}${peso(d.amount) ? `, ${peso(d.amount)}` : ''}.` : '', one(d.a), one(d.b)];
    }
    case 'V10': {
      // Not a key=value dump, and not silence either: the first live run said
      // "1 to look at" and named nothing, so nobody could act without opening
      // the dashboard. These are the actual rows, at most three.
      if (f.key === 'V10:stale') return [];
      const rows = healthRows(str(d.check), d);
      return d.accepted
        ? [...rows, 'This pair was gone through on 14 Sep and is fine. It will speak up again only if the count changes.']
        : rows;
    }
    default:
      return [];
  }
}

/** The last group: the one thing to do. */
function action(f: Finding): string {
  if (GOVERNOR.has(f.check_id)) return governorAction(f);
  switch (f.check_id) {
    case 'V1': return f.key.startsWith('V1m:')
      ? `open the Airbnb calendar and cut the block back to ${dm((f.detail as any)?.stay_from)} to ${dm((f.detail as any)?.stay_to)}, unless the stay changed.`
      : 'open the calendar, decide which stay is real, and cancel the other.';
    case 'V2': return 'open the booking and put its block back on the calendar.';
    case 'V3': return 'cancel the hold, or find the booking it belongs to.';
    case 'V4': return 'open Messenger and finish the booking with them, or close the conversation.';
    case 'V5': return 'answer the guest, then dismiss the handoff.';
    case 'V6': return 'ask for the ID before they arrive.';
    case 'V7': return 'check the reservation on Airbnb and correct whichever side is wrong; the card clears on the next hourly run once they agree.';
    case 'V7b': return 'check the cascadereservations inbox for the confirmation, or the reservation on Airbnb.';
    case 'V8': return 'check the wallet or bank for this payment. If it covers only one booking, ask the other guest for their own receipt before confirming theirs.';
    case 'V13': return (f.detail as any)?.refused
      ? 'check the key at openrouter.ai/settings/keys.'
      : 'raise the key limit at openrouter.ai/settings/keys if today needs more; it resets by itself at 08:00 Manila.';
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
  V8: `${DASH_URL}bookings`,
  V10: `${DASH_URL}settings`,
  V11: `${DASH_URL}settings`,
  V12: `${DASH_URL}calendar`,
};

/**
 * The header subject. A health check's title is its PASSING assertion, so
 * "ALERT - inventory quantities agree with movements" reads as good news. For
 * V10 the subject is the check in plain words instead.
 */
function alertSubject(f: Finding): string {
  if (f.check_id !== 'V10') return f.title.toLowerCase();
  if (f.key === 'V10:stale') return 'system health has not run';
  const check = str((f.detail as any)?.check);
  // Never f.title here: for V10 it is the stored PASSING label (verifier_v10.sql:249).
  return problemSubject(check || 'unknown');
}

/** One red finding, one card. */
export function redCard(f: Finding, now: Date): Card {
  const link = LINK[f.check_id];
  // V1 alone carries a ready-to-send line. An overlap is the one finding where
  // somebody has to talk to a guest before anything is decided, and the line is
  // deliberately neutral: it promises an answer, never a cancellation, because
  // which booking is the real one is exactly what nobody knows yet.
  const first = str((f.detail as any)?.a?.guest, 'the guest').split(' ')[0];
  const sample = f.check_id === 'V1' && !f.key.startsWith('V1m:') // V1m is our own block: no guest to write to
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
    text: withHeader('alert', alertSubject(f), groups(
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
  // A bullet in a shared card has no Do line of its own, so a governor bullet carries its exact change: that is the whole point of it.
  const h = headline(f, now).replace(/^System health: /, '');
  if (!GOVERNOR.has(f.check_id)) return h;
  const a = action(f);
  return `${h} ${a.charAt(0).toUpperCase()}${a.slice(1)}`;
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
  // A lone yellow card names its rows exactly as a red one does. Without this
  // it printed a count and nothing else, which is the defect the first live
  // run showed on the red side.
  if (findings.length === 1) out.push(headline(findings[0], now), ...facts(findings[0]).filter(Boolean));
  else if (findings.length > 1) out.push(`${findings.length} things are worth a look.`);
  else out.push('These closed themselves; nothing to do for them.'); // 2026-09-24: never "Nothing needs you" beside a red card of the same run

  const bullets = findings.length > 5
    ? [...findings.slice(0, 4).map((f) => `• ${yellowBullet(f, now)}`), `• and ${findings.length - 4} more in the dashboard`]
    : findings.length > 1
      ? findings.map((f) => `• ${yellowBullet(f, now)}`)
      : [];
  if (bullets.length) out.push('', ...bullets);

  if (findings.length === 1) out.push('', `Do: ${action(findings[0])}`);
  else if (findings.length > 1) {
    out.push('', findings.every((f) => GOVERNOR.has(f.check_id))
      ? 'Do: make each change named above, in the order listed.'
      : 'Do: open Settings, System health, and take them in order.');
  }

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
// SPEC-20 (D-213): what makes a finding urgent when the card has to choose.
const DAY = 86_400_000;
function newestDate(f: Finding): number {
  const d = (f.detail ?? {}) as Record<string, any>;
  const rows: any[] = Array.isArray(d.d) ? d.d : [];
  let best = 0;
  for (const r of rows) for (const k of ['checkout', 'cleaned', 'date', 'recorded']) {
    const t = Date.parse(String(r?.[k] ?? ''));
    if (Number.isFinite(t) && t > best) best = t;
  }
  return best;
}
/** V10:stale is red: every V10 check has gone silent. A missing cleaning report is NOT promoted any more
 *  (D-232): missed-cleaning-alert owns it in OPS, and the urgency sort below keeps it first in the list. */
export function promoted(f: Finding, _now: Date): Finding {
  if (f.check_id !== 'V10' || f.severity === 'red') return f;
  if (f.key === 'V10:stale') return { ...f, severity: 'red' };
  return f;
}
/** Yellows sort by urgency before the five-bullet cap: a date inside 7 days first, then by count. */
export function byUrgency(now: Date) {
  return (a: Finding, b: Finding) => {
    const ra = newestDate(a) >= now.getTime() - 7 * DAY ? 1 : 0;
    const rb = newestDate(b) >= now.getTime() - 7 * DAY ? 1 : 0;
    if (ra !== rb) return rb - ra;
    const na = Number((a.detail as any)?.n ?? 0), nb = Number((b.detail as any)?.n ?? 0);
    return nb - na;
  };
}

export function buildCards(applied: Applied, now: Date, today: string): Card[] {
  const loud = [...(applied.new ?? []), ...(applied.remind ?? [])].map((f) => promoted(f, now));
  const reds = loud.filter((f) => f.severity === 'red');
  const yellows = loud.filter((f) => f.severity !== 'red').sort(byUrgency(now));
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
