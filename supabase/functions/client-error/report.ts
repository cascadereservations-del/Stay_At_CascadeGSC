// D-240: what the checklist and the booking site say about their own errors, made safe and short.
// Pure, so report.test.ts reads every rule. index.ts records it and talks to Telegram.
import { withHeader } from '../_shared/cascade-core/format.ts';

export type App = 'checklist' | 'booking_site';
export type Kind = 'error' | 'rejection' | 'http';
export type Report = { app: App; kind: Kind; message: string; detail: Record<string, unknown> };

const APPS = new Set(['checklist', 'booking_site']);
const KINDS = new Set(['error', 'rejection', 'http']);

/** Guests and cleaners type e-mails and phone numbers; neither belongs in an error log or a Telegram card. */
export function redact(s: unknown, max: number): string {
  return String(s ?? '')
    .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '[email]')
    .replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '[token]')
    .replace(/\+?\d[\d\s-]{6,}\d/g, '[number]')
    .slice(0, max);
}

/** Null when the body is not a report from one of our two pages. */
export function parseReport(body: unknown): Report | null {
  const b = (body ?? {}) as Record<string, unknown>;
  if (!APPS.has(String(b.app)) || !KINDS.has(String(b.kind))) return null;
  const message = redact(b.message, 300).trim();
  if (!message) return null;
  const d = (b.detail && typeof b.detail === 'object' ? b.detail : {}) as Record<string, unknown>;
  const detail: Record<string, unknown> = {};
  for (const k of ['path', 'fn', 'code', 'src']) if (d[k] != null && d[k] !== '') detail[k] = redact(d[k], 120);
  for (const k of ['status', 'line', 'col']) if (d[k] != null && Number.isFinite(Number(d[k]))) detail[k] = Number(d[k]);
  if (d.stack) detail.stack = redact(d.stack, 800);
  if (d.ua) detail.ua = redact(d.ua, 160);
  return { app: b.app as App, kind: b.kind as Kind, message, detail };
}

/** The same error from any device is one fingerprint: numbers and ids are masked out of the message. */
export async function fingerprint(r: Report): Promise<string> {
  const norm = r.message.toLowerCase().replace(/[0-9a-f]{8}-[0-9a-f-]{27,}/g, '#').replace(/\d+/g, '#');
  const key = [r.app, r.kind, norm, r.detail.fn ?? '', r.detail.code ?? '', r.detail.status ?? '', r.detail.src ?? ''].join('|');
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key));
  return [...new Uint8Array(h)].map((x) => x.toString(16).padStart(2, '0')).join('').slice(0, 32);
}

/** A 409 is a refusal the page expects and explains to the person (dates taken, meter backwards): record, no card. */
export const alertable = (r: Report) => !(r.kind === 'http' && Number(r.detail.status) === 409);

const WHERE: Record<App, string> = { checklist: 'The cleaning checklist', booking_site: 'The direct booking site' };

/** The card, for a person: which page, what the person saw, how often, what to do. */
export function card(r: Report, count: number, isNew: boolean): string {
  const d = r.detail;
  const what = r.kind === 'http'
    ? `a server reply failed: ${d.fn ?? 'a request'} answered ${d.status ?? 'an error'}${d.code ? ` (${d.code})` : ''}.`
    : r.kind === 'rejection' ? `a step failed without being handled: ${r.message}` : `the page hit an error: ${r.message}`;
  const lines = [
    `${WHERE[r.app]} showed someone an error - ${what}`,
    isNew ? 'First time this error has been seen.' : `Seen ${count} times; it is still happening.`,
    d.path ? `Page: ${d.path}` : '',
    d.src ? `Where: ${d.src}${d.line ? ` line ${d.line}` : ''}` : '',
    '',
    `Do: ask the ${r.app === 'checklist' ? 'cleaner' : 'guest'} what they were doing, and send this card to the build chat to be fixed.`,
  ].filter((l, i, a) => l !== '' || (i > 0 && a[i - 1] !== ''));
  return withHeader('alert', `${r.app === 'checklist' ? 'checklist' : 'booking site'} error`, lines.join('\n'));
}
