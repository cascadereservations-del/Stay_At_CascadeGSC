// ocr-receipt pure helpers (s89): no I/O, so logic.test.ts covers them. index.ts keeps the request handling.

export const EXTRACT_MIMES: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
export const MAX_IMAGE_B64_CHARS = 8_000_000; // about 6 MB of image, under the bucket's 10 MB limit

const DEFAULT_CATEGORY_LIST = 'supplies, utilities, cleaning, maintenance, repairs, platform_fees, other';

/** The model is told the live expense_categories slugs (the one canonical list) instead of a hardcoded set. */
export function buildPrompt(base: string, slugs: string[]): string {
  const list = slugs.filter((s) => /^[a-z0-9_]{1,40}$/.test(s));
  return list.length ? base.replace(DEFAULT_CATEGORY_LIST, list.join(', ')) : base;
}

export function mapCategory(hint: unknown, valid: Set<string>): string {
  const h = String(hint ?? '').toLowerCase().trim();
  return valid.has(h) ? h : 'other';
}

export function clamp01(n: unknown): number {
  const x = Number(n);
  if (!isFinite(x)) return 0;
  return Math.max(0, Math.min(1, x));
}

export function validDate(d: unknown, now = Date.now()): string | null {
  const s = String(d ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null;
  const t = new Date(`${s}T00:00:00Z`).getTime();
  if (isNaN(t)) return null;
  if (t > now + 2 * 86_400_000) return null;
  if (t < new Date('2020-01-01').getTime()) return null;
  return s;
}

export type LineItem = { description: string; qty: number | null; unit_cost: number | null };

function positiveNumberOrNull(n: unknown): number | null {
  const x = Number(n);
  return isFinite(x) && x > 0 ? x : null;
}

// Accepts either the {description, qty, unit_cost}[] shape or a legacy flat string[]; always returns the structured shape.
export function normalizeLineItems(raw: unknown): LineItem[] {
  if (!Array.isArray(raw)) return [];
  return raw
    .map((entry): LineItem | null => {
      if (typeof entry === 'string') {
        const description = entry.trim();
        return description ? { description: description.slice(0, 200), qty: null, unit_cost: null } : null;
      }
      if (entry && typeof entry === 'object') {
        // deno-lint-ignore no-explicit-any
        const e = entry as any;
        const description = String(e.description ?? '').trim();
        if (!description) return null;
        return { description: description.slice(0, 200), qty: positiveNumberOrNull(e.qty), unit_cost: positiveNumberOrNull(e.unit_cost) };
      }
      return null;
    })
    .filter((x): x is LineItem => x !== null)
    .slice(0, 50);
}

export function formatLineItemsForNotes(items: LineItem[]): string | null {
  if (!items.length) return null;
  const parts = items.map((i) => `${i.description}${i.qty && i.unit_cost ? ` (${i.qty} x ₱${i.unit_cost})` : ''}`);
  return `items: ${parts.join(', ').slice(0, 400)}`;
}

/** Decode the base64 photo of an extract request. Refuses anything that is not a small jpeg, png or webp. */
export function decodeImage(b64: unknown, mime: unknown):
  | { ok: true; bytes: Uint8Array; mime: string; ext: string }
  | { ok: false; status: number; error: string } {
  const m = String(mime ?? 'image/jpeg').toLowerCase().trim();
  const ext = EXTRACT_MIMES[m];
  if (!ext) return { ok: false, status: 415, error: 'unsupported_image_type' };
  const s = String(b64 ?? '').trim();
  if (!s) return { ok: false, status: 400, error: 'image_base64_required' };
  if (s.length > MAX_IMAGE_B64_CHARS) return { ok: false, status: 413, error: 'image_too_large' };
  try {
    const bin = atob(s);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes.length ? { ok: true, bytes, mime: m, ext } : { ok: false, status: 400, error: 'image_base64_required' };
  } catch {
    return { ok: false, status: 400, error: 'image_base64_invalid' };
  }
}

/** expense-receipts/<property>/<staff user>/<uuid>.<ext>: the prefix admin_save_transaction_v1 accepts. */
export const receiptPath = (propertyId: string, userId: string, ext: string, id: string) => `${propertyId}/${userId}/${id}.${ext}`;

export type Extracted = { amount: number | null; date: string | null; vendor: string | null; category: string; line_items: LineItem[]; confidence: number };

// deno-lint-ignore no-explicit-any
export function shapeExtraction(parsed: any, valid: Set<string>, now = Date.now()): Extracted {
  const amount = Number(parsed?.amount);
  return {
    amount: isFinite(amount) && amount > 0 ? amount : null,
    date: validDate(parsed?.date, now),
    vendor: parsed?.vendor ? String(parsed.vendor).slice(0, 200) : null,
    category: mapCategory(parsed?.category_hint, valid),
    line_items: normalizeLineItems(parsed?.line_items),
    confidence: clamp01(parsed?.confidence),
  };
}
