// Lane XS (s82/s84): tell the owner and admin phones that a guest needs them, so the Inbox in the Staff app is not something they have to remember to open.
// Called only by messenger-concierge (service-role bearer) or by the database (cron secret). Everything it needs arrives through `InboxDeps`, so the
// order of events is unit-tested without a network.
//   1. read the phones that turned the Inbox push on (staff_push_inbox_recipients_v1: active owner/admin only). None: nothing is claimed, nothing is sent.
//   2. claim the event once (staff_push_claim_v1): `handover:<handoff_id>`, or `guest_wrote:<psid>:<15-minute bucket>`. A second ask sends nothing.
//   3. Web Push to every phone. One retry for a transient answer (429, 5xx, no answer), none after that; a 404 or 410 deletes that subscription.
// The lock-screen text carries no guest name, contact, message text or amount, ever. Same four keys as the paid notice: title, body, url, tag.
import type { PushResult } from '../_shared/C_webpush.ts';
import { HOUSE_PROPERTY_ID, isImportant, manilaDate, NOTICE_TAG, NOTICE_URL, noticeBody, rainBody, rainKey, type NoticeEvent, type NoticeRow, parseNoticeEvent } from './notices.ts';
// XS2 (s84): the same function also tells every active staff phone (topic `notices`) about a scheduled brownout or water interruption (kind `notice`)
// and about rain during a brownout (kind `rain`); see notices.ts. The inbox kinds above are unchanged.

export type Sub = { id: string; endpoint: string; p256dh: string; auth: string };
export type InboxKind = 'handover' | 'guest_wrote';

export const INBOX_TITLE = 'Cascade Staff';
export const INBOX_BODY: Record<InboxKind, string> = {
  guest_wrote: 'A guest wrote on Messenger',
  handover: 'Cassy needs you on a guest chat',
};
export const INBOX_URL = './#inbox';
export const INBOX_TAG = 'inbox';
export const BUCKET_MS = 15 * 60_000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PSID = /^[A-Za-z0-9_.:-]{1,64}$/;

export type GuestEvent = { kind: InboxKind; psid: string; handoffId: string | null };
export type InboxEvent = GuestEvent | NoticeEvent;

/** Parses the request body; the reason is a short code, never an echo of the input. */
export function parseEvent(raw: unknown): { ok: true; value: InboxEvent } | { ok: false; reason: string } {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ok: false, reason: 'bad_request' };
  const b = raw as Record<string, unknown>;
  if (b.kind === 'notice' || b.kind === 'rain') return parseNoticeEvent(b);
  if (b.kind !== 'handover' && b.kind !== 'guest_wrote') return { ok: false, reason: 'bad_kind' };
  if (typeof b.psid !== 'string' || !PSID.test(b.psid)) return { ok: false, reason: 'bad_psid' };
  const handoffId = typeof b.handoff_id === 'string' ? b.handoff_id : null;
  if (b.kind === 'handover' && (!handoffId || !UUID.test(handoffId))) return { ok: false, reason: 'bad_handoff_id' };
  return { ok: true, value: { kind: b.kind, psid: b.psid, handoffId: b.kind === 'handover' ? handoffId!.toLowerCase() : null } };
}

/** The claim key. A handover is one event per handoff; a guest writing is one event per guest per 15 minutes. */
export function claimKey(e: InboxEvent, nowMs: number): string {
  if (e.kind === 'notice') return `notice:${e.noticeId}`;
  if (e.kind === 'rain') return rainKey(e.from);
  return e.kind === 'handover' ? `handover:${e.handoffId}` : `guest_wrote:${e.psid}:${Math.floor(nowMs / BUCKET_MS)}`;
}

export type InboxDeps = {
  nowMs: () => number;
  recipients: () => Promise<Sub[] | null>; // null = the read failed
  /** XS2: phones holding the notices topic, for active staff of the property. null = the read failed. */
  noticeRecipients: (propertyId: string) => Promise<Sub[] | null>;
  /** XS2: the notice row; undefined = no such notice; null = the read failed. */
  notice: (id: string) => Promise<NoticeRow | null | undefined>;
  claim: (key: string) => Promise<boolean | null>; // null = the claim failed
  deleteSub: (id: string) => Promise<void>;
  touchSub: (id: string) => Promise<void>;
  /** null when the VAPID secrets are not set: nothing is sent. */
  push: ((s: Sub, m: { title: string; body: string; url: string; tag: string }) => Promise<PushResult>) | null;
  log: (msg: string) => void;
};

export type InboxOutcome = {
  ok: boolean; skipped?: string; reason?: string;
  push: { sent: number; gone: number; failed: number; subscriptions: number };
};
const none = { sent: 0, gone: 0, failed: 0, subscriptions: 0 };

export async function runInbox(e: InboxEvent, d: InboxDeps): Promise<InboxOutcome> {
  if (!d.push) return { ok: true, skipped: 'push_not_configured', push: none };
  let subs: Sub[] | null, message: { title: string; body: string; url: string; tag: string };
  if (e.kind === 'notice' || e.kind === 'rain') {
    if (e.kind === 'notice') {
      const n = await d.notice(e.noticeId);
      if (n === null) return { ok: false, reason: 'rpc_failed', push: none };
      if (n === undefined) return { ok: true, skipped: 'not_found', push: none };
      if (!isImportant(n, d.nowMs())) return { ok: true, skipped: 'not_important', push: none };
      subs = await d.noticeRecipients(n.property_id);
      message = { title: INBOX_TITLE, body: noticeBody(e, n), url: NOTICE_URL, tag: NOTICE_TAG };
    } else {
      // rain within 3 hours at the house: always told; the sentence mentions the brownout when the caller named one that is still real
      if (e.from.slice(0, 10) < manilaDate(d.nowMs())) return { ok: true, skipped: 'not_important', push: none };
      let brownout = false;
      if (e.brownoutNoticeId) {
        const n = await d.notice(e.brownoutNoticeId);
        if (n === null) return { ok: false, reason: 'rpc_failed', push: none };
        brownout = !!n && n.notice_type === 'brownout' && isImportant(n, d.nowMs());
      }
      subs = await d.noticeRecipients(HOUSE_PROPERTY_ID);
      message = { title: INBOX_TITLE, body: rainBody(e, brownout, d.nowMs()), url: NOTICE_URL, tag: NOTICE_TAG };
    }
  } else {
    subs = await d.recipients();
    message = { title: INBOX_TITLE, body: INBOX_BODY[e.kind], url: INBOX_URL, tag: INBOX_TAG };
  }
  if (subs === null) return { ok: false, reason: 'rpc_failed', push: none };
  if (!subs.length) return { ok: true, skipped: 'no_recipients', push: none };
  const claimed = await d.claim(claimKey(e, d.nowMs()));
  if (claimed === null) return { ok: false, reason: 'rpc_failed', push: none };
  if (!claimed) return { ok: true, skipped: 'already_sent', push: { ...none, subscriptions: subs.length } };

  const push = { ...none, subscriptions: subs.length };
  for (const s of subs) {
    try {
      let r = await d.push(s, message);
      if (!r.ok && r.transient) r = await d.push(s, message); // one retry, never more
      if (r.ok) { push.sent++; await d.touchSub(s.id); }
      else if (r.gone) { push.gone++; await d.deleteSub(s.id); }
      else push.failed++;
    } catch (err) {
      push.failed++;
      d.log(`inbox push: a send threw (${String((err as Error)?.message ?? err).slice(0, 80)})`);
    }
  }
  return { ok: true, push };
}

export const CORS_H = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, x-client-info, content-type, x-cascade-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { ...CORS_H, 'Content-Type': 'application/json' } });

/** The whole request: preflight, method, caller (cron secret or the service-role bearer, both constant-time), body, then runInbox. */
export async function handle(
  req: Request,
  o: { authorized: (req: Request) => boolean; deps: InboxDeps },
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_H });
  if (req.method !== 'POST') return reply({ ok: false, reason: 'method_not_allowed' }, 405);
  if (!o.authorized(req)) return reply({ ok: false, reason: 'unauthorized' }, 401);
  const parsed = parseEvent(await req.json().catch(() => null));
  if (!parsed.ok) return reply({ ok: false, reason: parsed.reason }, 400);
  const out = await runInbox(parsed.value, o.deps);
  return reply(out, out.ok ? 200 : 502);
}
