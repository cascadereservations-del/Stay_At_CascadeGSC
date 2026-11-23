// ocr-receipt pure helpers (s89): no I/O, so logic.test.ts covers them. index.ts keeps the request handling.
import { matchLine, type Candidate } from './match.ts';

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
    if (!bytes.length) return { ok: false, status: 400, error: 'image_base64_required' };
    // the declared type must match the file: jpeg FF D8 FF, png 89 50 4E 47, webp RIFF....WEBP
    const at = (o: number, ...v: number[]) => v.every((x, k) => bytes[o + k] === x);
    const real = at(0, 0xff, 0xd8, 0xff) ? 'image/jpeg' : at(0, 0x89, 0x50, 0x4e, 0x47) ? 'image/png'
      : at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50) ? 'image/webp' : null;
    if (real !== m) return { ok: false, status: 415, error: 'unsupported_image_type' };
    return { ok: true, bytes, mime: m, ext };
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

/** Which staff capability a request needs: supply mode is open to cleaners and laundry (report_supply); every other mode keeps approve_payment. */
export const gateAction = (body: { mode?: unknown } | null): 'report_supply' | 'approve_payment' => body?.mode === 'supply' ? 'report_supply' : 'approve_payment';

/** D-330: cleaners never see prices. A receipt line's description with any money removed (P/PHP/peso sign amounts and bare decimal amounts like 45.00 or 1,234.50); sizes such as 500ML, 12S, 2PLY, 135G stay. */
export function scrubMoney(description: string): string {
  const out = String(description ?? '')
    .replace(/(?<![A-Za-z0-9])(?:₱|php|p)\.?\s*\d[\d,]*(?:\.\d+)?(?![A-Za-z0-9])/gi, ' ')
    .replace(/(?<![\w.,])\d{1,3}(?:,\d{3})*\.\d{2}(?![\w.])|(?<![\w.,])\d+\.\d{2}(?![\w.])/g, ' ')
    .replace(/\s+/g, ' ').replace(/[\s@=:\-–]+$/, '').replace(/^[\s@=:\-–]+/, '').trim();
  return out || 'Item';
}


// ---------------------------------------------------------------------------------------------------------------------------------------------
// s134 L3 (D-405): receipts for the expense log. Modes `sign` and `attach`, PDF storage, upload proof, `supply` by path. The handlers take their
// dependencies as arguments (a database client, the caller's RPC, the vision read) so logic.test.ts runs them with fakes; index.ts builds the
// real ones. Existing request and response shapes stay valid: everything here is an addition.
// ---------------------------------------------------------------------------------------------------------------------------------------------

export const PDF_MAX_BYTES = 5 * 1024 * 1024;
export const PDF_MAX_B64_CHARS = 7_000_000; // 5 MB is 6,990,508 base64 characters
export const SIGN_SECONDS = 300;
export const SIGN_MAX_IDS = 20;
export const RECEIPTS_BUCKET = 'expense-receipts';
/** The bucket the manual Bought photo lives in (s132 inventory_item receipt check: storage.objects bucket_id = 'inventory-photos'). */
export const INVENTORY_BUCKET = 'inventory-photos';
export const CLEANING_BUCKET = 'cleaning-photos';
export const SYSTEM_CATEGORY_SLUGS = ['guest_refund', 'airbnb_adjustment'];

export type Out = { status: number; body: Record<string, unknown> };
const out = (status: number, body: Record<string, unknown>): Out => ({ status, body });

export type DecodedFile =
  | { ok: true; bytes: Uint8Array; mime: string; ext: string; pdf: boolean }
  | { ok: false; status: number; error: string };

/** decodeImage for the three image types, plus a PDF (<= 5 MB, must start with %PDF-). The old no-mode path keeps calling decodeImage, so it still answers 415 for a PDF. */
export function decodeFile(b64: unknown, mime: unknown): DecodedFile {
  const m = String(mime ?? 'image/jpeg').toLowerCase().trim();
  if (m !== 'application/pdf') {
    const r = decodeImage(b64, mime);
    return r.ok ? { ...r, pdf: false } : r;
  }
  const s = String(b64 ?? '').trim();
  if (!s) return { ok: false, status: 400, error: 'file_base64_required' };
  if (s.length > PDF_MAX_B64_CHARS) return { ok: false, status: 413, error: 'file_too_large' };
  try {
    const bin = atob(s);
    if (bin.length > PDF_MAX_BYTES) return { ok: false, status: 413, error: 'file_too_large' };
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    if (!bytes.length) return { ok: false, status: 400, error: 'file_base64_required' };
    // %PDF-
    if (![0x25, 0x50, 0x44, 0x46, 0x2d].every((v, k) => bytes[k] === v)) return { ok: false, status: 415, error: 'unsupported_file_type' };
    return { ok: true, bytes, mime: 'application/pdf', ext: 'pdf', pdf: true };
  } catch {
    return { ok: false, status: 400, error: 'file_base64_invalid' };
  }
}

export const isPdfMime = (mime: unknown) => String(mime ?? '').toLowerCase().trim() === 'application/pdf';

/** The server's own figure for the stored bytes (same as upload-photo/hash.ts; copied so no other function's file is bundled). */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as unknown as BufferSource));
  return Array.from(d, (b) => b.toString(16).padStart(2, '0')).join('');
}

// deno-lint-ignore no-explicit-any
type Db = any;

/** Upload proof (cross-lane contract 1): staff_upload_hashes(path, sha256, uploaded_by) with the service role. True only when the row is in. */
export async function recordUploadHash(db: Db, row: { path: string; sha256: string; uploaded_by: string }): Promise<boolean> {
  try {
    const { error } = await db.from('staff_upload_hashes').insert(row);
    if (error) { console.warn('ocr_upload_hash_not_recorded', String(error.code ?? error.message ?? error).slice(0, 80)); return false; }
    return true;
  } catch (e) {
    console.warn('ocr_upload_hash_not_recorded', String((e as Error)?.message ?? e).slice(0, 80));
    return false;
  }
}

export type Deps = {
  db: Db; // service role
  propertyId: string;
  newId: () => string;
  /** The vision read, or null when no key is configured. `slugs` null = the function's default prompt. Returns the parsed model answer. */
  read: ((b64: string, mime: string, slugs: string[] | null) => Promise<unknown>) | null;
  toB64: (bytes: Uint8Array) => string;
  /** The caller's own token on the RPC (that call is the gate for `sign`). */
  callerRpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;
  /** Signed link for a (bucket, path); null when it could not be made. Never logged. */
  signUrl: (bucket: string, path: string, seconds: number) => Promise<string | null>;
};

export type Who = { userId: string };

// ---- stock hint and the shared stock matching ----

export type StockHint = { count: number; names: string[] };
export const NO_HINT: StockHint = { count: 0, names: [] };

export async function loadCandidates(db: Db, propertyId: string): Promise<{ ok: true; cands: Candidate[] } | { ok: false }> {
  const [items, opts] = await Promise.all([
    db.from('inventory_items').select('id,name').eq('property_id', propertyId).eq('is_active', true),
    db.from('inventory_item_options').select('item_id,title'), // the real column is title (s110 grant: select (item_id, title)); an option title is an alias; a read error only costs those aliases
  ]);
  if (items.error) { console.warn('ocr_supply_items_failed', items.error.message); return { ok: false }; }
  const names = new Map<string, string[]>((items.data ?? []).map((i: { id: string; name: string }) => [i.id, [String(i.name ?? '')]]));
  for (const o of (opts.error ? [] : opts.data ?? []) as Array<{ item_id: string; title: string }>) names.get(o.item_id)?.push(String(o.title ?? ''));
  return { ok: true, cands: [...names].map(([item_id, n]) => ({ item_id, names: n.filter(Boolean) })) };
}
/** The draft's lines: price scrubbed from the text (D-330), each matched to stock. */
export function draftLines(items: LineItem[], cands: Candidate[]) {
  return items.map((l, i) => {
    const description = scrubMoney(l.description);
    const m = matchLine(description, cands);
    return { line_no: i + 1, description, qty: l.qty, unit_cost: l.unit_cost, match_item_id: m.item_id, match_score: m.score };
  });
}

/** How many read lines match an active item or option title (the matcher mode `supply` uses), and the matched item names. No model call. */
export function stockHint(items: LineItem[], cands: Candidate[]): StockHint {
  const names: string[] = [];
  let count = 0;
  for (const l of items) {
    const m = matchLine(scrubMoney(l.description), cands);
    if (!m.item_id) continue;
    count++;
    const n = cands.find((c) => c.item_id === m.item_id)?.names[0];
    if (n && !names.includes(n) && names.length < 10) names.push(n);
  }
  return { count, names };
}

export async function stockHintFor(db: Db, propertyId: string, items: LineItem[]): Promise<StockHint> {
  if (!items.length) return NO_HINT;
  const c = await loadCandidates(db, propertyId);
  return c.ok ? stockHint(items, c.cands) : NO_HINT; // a hint is a convenience: a read error costs the hint, never the answer
}

export async function loadSlugs(db: Db, propertyId: string): Promise<string[]> {
  const { data } = await db.from('expense_categories').select('slug').eq('property_id', propertyId).eq('is_active', true).order('sort_order');
  return (data ?? []).map((c: { slug: string }) => c.slug).filter((s: string) => !SYSTEM_CATEGORY_SLUGS.includes(s));
}

// ---- storing an upload (attach, extract) ----

export const UPLOAD_DAILY_LIMIT = 100;
/** Start of today in Manila, as a timestamp Postgres reads. */
const manilaDayStart = () => `${new Date(Date.now() + 8 * 3_600_000).toISOString().slice(0, 10)}T00:00:00+08:00`;

/** s134 fix r1: at most UPLOAD_DAILY_LIMIT stored uploads (attach, extract) per user per Manila day, counted from the proof rows (shared with the bills, staff-pay and meter proof uploads). A missing count fails closed. Null = under the limit. */
export async function uploadLimit(db: Db, userId: string): Promise<Out | null> {
  const used = await db.from('staff_upload_hashes').select('path', { count: 'exact', head: true }).eq('uploaded_by', userId).gte('created_at', manilaDayStart());
  if (used.error || typeof used.count !== 'number') { console.warn('ocr_upload_limit_check_failed', String(used.error?.message ?? used.error ?? 'no count').slice(0, 120)); return out(500, { ok: false, error: 'load_failed' }); }
  if (used.count >= UPLOAD_DAILY_LIMIT) return out(429, { ok: false, error: 'daily_limit' });
  return null;
}

export type Stored = { ok: true; path: string; sha256: string; hashOk: boolean } | { ok: false; out: Out };

/** Upload under <property>/<caller>/<uuid>.<ext>, hash the stored bytes, record the proof row. The object is never removed here. */
export async function storeUpload(f: Extract<DecodedFile, { ok: true }>, who: Who, d: Deps): Promise<Stored> {
  const lim = await uploadLimit(d.db, who.userId);
  if (lim) return { ok: false, out: lim };
  const path = receiptPath(d.propertyId, who.userId, f.ext, d.newId());
  const up = await d.db.storage.from(RECEIPTS_BUCKET).upload(path, f.bytes, { contentType: f.mime, upsert: false });
  if (up.error) { console.warn('ocr_upload_failed', String(up.error.message).slice(0, 120)); return { ok: false, out: out(500, { ok: false, error: 'upload_failed' }) }; }
  const sha256 = await sha256Hex(f.bytes);
  const hashOk = await recordUploadHash(d.db, { path, sha256, uploaded_by: who.userId });
  return { ok: true, path, sha256, hashOk };
}

export type Suggest = { amount: number | null; date: string | null; vendor: string | null; category: string; line_items: LineItem[]; confidence: number };

/** mode attach {file_base64, mime_type, read?}: store, hash, record proof, read an image. It writes no ledger row; the app then calls expense_receipt_set_v1. */
// deno-lint-ignore no-explicit-any
export async function attachHandler(body: any, who: Who, d: Deps): Promise<Out> {
  const f = decodeFile(body?.file_base64, body?.mime_type);
  if (!f.ok) return out(f.status, { ok: false, error: f.error });
  const st = await storeUpload(f, who, d);
  if (!st.ok) return st.out;
  const base = { ok: true, receipt_path: st.path, sha256: st.sha256, mime: f.mime };
  // Without the proof row nothing can attach this file (the SQL requires it), so a failure here is loud rather than a path the app cannot use.
  if (!st.hashOk) return out(500, { ok: false, error: 'hash_failed' });
  if (f.pdf) return out(200, { ...base, suggest: null, unread: 'pdf', stock_hint: NO_HINT });
  if (body?.read === false) return out(200, { ...base, suggest: null, unread: 'skipped', stock_hint: NO_HINT });
  if (!d.read) return out(200, { ...base, suggest: null, unread: 'no_key', stock_hint: NO_HINT });
  try {
    const slugs = await loadSlugs(d.db, d.propertyId);
    const x = shapeExtraction(await d.read(d.toB64(f.bytes), f.mime, slugs), new Set(slugs));
    const suggest: Suggest = { amount: x.amount, date: x.date, vendor: x.vendor, category: x.category, line_items: x.line_items, confidence: x.confidence };
    return out(200, { ...base, suggest, stock_hint: await stockHintFor(d.db, d.propertyId, x.line_items) });
  } catch (e) {
    console.warn('ocr_attach_read_failed', String(e).slice(0, 200));
    return out(200, { ...base, suggest: null, unread: 'failed', stock_hint: NO_HINT }); // a read failure still returns the path
  }
}

// ---- sign ----

/** Which buckets each receipt kind may live in (R5). The kind fixes the bucket; the path is never taken from the request. */
const KIND_BUCKETS: Record<string, string[]> = {
  txn: [RECEIPTS_BUCKET],
  draft: [RECEIPTS_BUCKET, INVENTORY_BUCKET], // scanned draft: expense-receipts; manual draft: the inventory photo bucket
  bill: [CLEANING_BUCKET], // cleaning-photos is signed for kind bill only (C3: no kind pay)
  stock: [INVENTORY_BUCKET],
};
export const pairAllowed = (kind: unknown, bucket: unknown): boolean =>
  typeof kind === 'string' && typeof bucket === 'string' && Object.prototype.hasOwnProperty.call(KIND_BUCKETS, kind) && KIND_BUCKETS[kind].includes(bucket);

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const safePath = (p: unknown): p is string => typeof p === 'string' && p.length > 0 && p.length <= 500 && !p.includes('..') && !p.startsWith('/');

/** mode sign {property_id?, ids}: the caller's token goes to expense_receipt_paths_v1 (the gate); only the pairs it returns, inside the kind-to-bucket map, are signed with the service role for 300 s. */
// deno-lint-ignore no-explicit-any
export async function signHandler(body: any, d: Deps): Promise<Out> {
  if (body?.property_id !== undefined && body.property_id !== null && String(body.property_id) !== d.propertyId) return out(403, { ok: false, error: 'property_mismatch' });
  const raw = body?.ids;
  if (!Array.isArray(raw) || !raw.length) return out(400, { ok: false, error: 'ids_required' });
  if (raw.length > SIGN_MAX_IDS) return out(400, { ok: false, error: 'too_many_ids' });
  if (!raw.every((i: unknown) => typeof i === 'string' && UUID_RE.test(i))) return out(400, { ok: false, error: 'invalid_ids' });
  const ids = [...new Set(raw.map((i: string) => i.toLowerCase()))];
  const r = await d.callerRpc('expense_receipt_paths_v1', { p_property_id: d.propertyId, p_ids: ids });
  if (r.error) {
    const refused = r.error.code === '42501' || /forbidden|not allowed|permission/i.test(String(r.error.message ?? ''));
    return refused ? out(403, { ok: false, error: 'forbidden' }) : out(502, { ok: false, error: 'sign_failed' });
  }
  // The RPC answers [] (not an error) to a caller who may not see receipts, so that caller gets ok with no links; the 403 branches stay for a refusing error.
  const rows = r.data;
  if (!Array.isArray(rows)) {
    // deno-lint-ignore no-explicit-any
    return (rows as any)?.error === 'forbidden' ? out(403, { ok: false, error: 'forbidden' }) : out(502, { ok: false, error: 'sign_failed' });
  }
  const asked = new Set(ids);
  const links: Record<string, { url: string; kind: string; mime: string | null }> = {};
  for (const row of rows as Array<Record<string, unknown>>) {
    const id = String(row?.id ?? '').toLowerCase();
    if (!asked.has(id) || links[id]) continue; // only ids that were asked for, once
    if (!pairAllowed(row.kind, row.bucket) || !safePath(row.path)) continue; // a pair outside the map is never signed
    const url = await d.signUrl(String(row.bucket), row.path, SIGN_SECONDS);
    if (url) links[id] = { url, kind: String(row.kind), mime: typeof row.mime === 'string' ? row.mime : null };
  }
  return out(200, { ok: true, links });
}

// ---- supply by path ----

/** The exact shape of a file the caller attached: <property>/<caller>/<uuid>.(jpg|png|webp). A prefix match with a wrong tail is refused. */
export function checkSupplyPath(raw: unknown, propertyId: string, userId: string):
  | { ok: true; path: string }
  | { ok: false; status: number; error: string } {
  const p = typeof raw === 'string' ? raw : '';
  const prefix = `${propertyId}/${userId}/`;
  if (!p || !p.startsWith(prefix) || p.includes('..')) return { ok: false, status: 400, error: 'invalid_receipt_path' };
  const tail = p.slice(prefix.length);
  if (/^[0-9a-f-]{36}\.pdf$/.test(tail)) return { ok: false, status: 415, error: 'unsupported_image_type' };
  if (!/^[0-9a-f-]{36}\.(jpg|png|webp)$/.test(tail)) return { ok: false, status: 400, error: 'invalid_receipt_path' };
  return { ok: true, path: p };
}

export const SUPPLY_DAILY_LIMIT = 20;

/** At most SUPPLY_DAILY_LIMIT drafts per user per Manila day (one vision read each). Null = under the limit. */
export async function supplyLimit(db: Db, userId: string): Promise<Out | null> {
  const dayStart = `${new Date(Date.now() + 8 * 3_600_000).toISOString().slice(0, 10)}T00:00:00+08:00`;
  const used = await db.from('inventory_receipt_drafts').select('id', { count: 'exact', head: true }).eq('created_by', userId).gte('created_at', dayStart);
  if (used.error) { console.warn('ocr_supply_limit_check_failed', used.error.message); return out(500, { ok: false, error: 'load_failed' }); }
  if ((used.count ?? 0) >= SUPPLY_DAILY_LIMIT) return out(429, { ok: false, error: 'daily_limit' });
  return null;
}

const MIME_OF_EXT: Record<string, string> = { jpg: 'image/jpeg', png: 'image/png', webp: 'image/webp' };

/** mode supply with receipt_path (no image_base64): continue a scan made in Expenses without a second upload. The object is never removed. */
// deno-lint-ignore no-explicit-any
export async function supplyByPath(body: any, who: Who, d: Deps): Promise<Out> {
  const chk = checkSupplyPath(body?.receipt_path, d.propertyId, who.userId);
  if (!chk.ok) return out(chk.status, { ok: false, error: chk.error });
  const path = chk.path;
  // a second call with the same path is a replay: the same draft, nothing created
  const same = await d.db.from('inventory_receipt_drafts').select('id').eq('receipt_path', path).neq('status', 'cancelled').limit(1);
  if (same.error) { console.warn('ocr_supply_replay_check_failed', same.error.message); return out(500, { ok: false, error: 'load_failed' }); }
  if (same.data?.length) return out(200, { ok: true, draft_id: same.data[0].id });
  const held = await d.db.from('transactions').select('id').eq('receipt_image_path', path).neq('status', 'void').limit(1);
  if (held.error) { console.warn('ocr_supply_inuse_check_failed', held.error.message); return out(500, { ok: false, error: 'load_failed' }); }
  if (held.data?.length) return out(409, { ok: false, error: 'receipt_in_use' });
  const lim = await supplyLimit(d.db, who.userId);
  if (lim) return lim;
  const dl = await d.db.storage.from(RECEIPTS_BUCKET).download(path);
  if (dl.error || !dl.data) return out(404, { ok: false, error: 'receipt_not_found' });
  const bytes = new Uint8Array(await dl.data.arrayBuffer());
  const b64 = d.toB64(bytes);
  const img = decodeImage(b64, MIME_OF_EXT[path.slice(path.lastIndexOf('.') + 1)]);
  if (!img.ok) return out(img.status, { ok: false, error: img.error });
  if (!d.read) return out(500, { ok: false, error: 'no_vision_key' });
  let x: ReturnType<typeof shapeExtraction>;
  try {
    x = shapeExtraction(await d.read(b64, img.mime, null), new Set(['other']));
    if (!x.line_items.length) throw new Error('no_lines_read');
  } catch (e) {
    console.warn('ocr_supply_failed', String(e).slice(0, 300));
    return out(502, { ok: false, error: 'ocr_failed' }); // the object stays: it may be on an expense
  }
  const c = await loadCandidates(d.db, d.propertyId);
  if (!c.ok) return out(500, { ok: false, error: 'load_failed' });
  const { data: row, error } = await d.db.from('inventory_receipt_drafts').insert({
    property_id: d.propertyId, created_by: who.userId, receipt_path: path, vendor: x.vendor, purchased_on: x.date, total: x.amount, lines: draftLines(x.line_items, c.cands), status: 'draft',
  }).select('id').single();
  if (error || !row) { console.warn('ocr_supply_insert_failed', String(error?.message).slice(0, 200)); return out(500, { ok: false, error: 'insert_failed' }); }
  return out(200, { ok: true, draft_id: row.id });
}
