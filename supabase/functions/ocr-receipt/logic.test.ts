import { assert, assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import { attachHandler, storeUpload, UPLOAD_DAILY_LIMIT, checkSupplyPath, decodeFile, type Deps, NO_HINT, pairAllowed, sha256Hex, signHandler, SIGN_SECONDS, stockHint, supplyByPath, buildPrompt, decodeImage, gateAction, mapCategory, receiptPath, scrubMoney, shapeExtraction, validDate } from './logic.ts';

Deno.test('buildPrompt swaps the hardcoded category list for the live slugs and ignores odd ones', () => {
  const base = 'x ONE of: supplies, utilities, cleaning, maintenance, repairs, platform_fees, other y';
  assertEquals(buildPrompt(base, ['supplies', 'loan', 'Bad Slug', 'other']), 'x ONE of: supplies, loan, other y');
  assertEquals(buildPrompt(base, []), base);
});

Deno.test('mapCategory only returns a slug on the canonical list', () => {
  const valid = new Set(['supplies', 'loan', 'other']);
  assertEquals(mapCategory(' Loan ', valid), 'loan');
  assertEquals(mapCategory('platform_fees', valid), 'other');
  assertEquals(mapCategory(null, valid), 'other');
});

Deno.test('decodeImage refuses wrong type, empty, oversized and bad base64; accepts a small jpeg', () => {
  const b64 = (...b: number[]) => btoa(String.fromCharCode(...b));
  const jpeg = b64(0xff, 0xd8, 0xff, 0xe0, 1, 2);
  const ok = decodeImage(jpeg, 'image/jpeg');
  assertEquals(ok.ok && ok.ext, 'jpg');
  assertEquals(decodeImage(b64(0x89, 0x50, 0x4e, 0x47, 1), 'image/png').ok, true);
  assertEquals(decodeImage(b64(0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50), 'image/webp').ok, true);
  // magic bytes must match the declared type
  assertEquals((decodeImage(b64(0x89, 0x50, 0x4e, 0x47, 1), 'image/jpeg') as { status: number }).status, 415);
  assertEquals((decodeImage(btoa('abc'), 'image/jpeg') as { status: number }).status, 415);
  assertEquals((decodeImage(jpeg, 'application/pdf') as { status: number }).status, 415);
  assertEquals((decodeImage('', 'image/png') as { status: number }).status, 400);
  assertEquals((decodeImage('%%%', 'image/png') as { status: number }).status, 400);
  assertEquals((decodeImage('A'.repeat(8_000_001), 'image/webp') as { status: number }).status, 413);
});

Deno.test('receiptPath sits under the property folder the SQL accepts', () => {
  assertEquals(receiptPath('P', 'U', 'jpg', 'I'), 'P/U/I.jpg');
});

Deno.test('validDate rejects the future, ancient and malformed dates', () => {
  const now = Date.parse('2026-10-16T00:00:00Z');
  assertEquals(validDate('2026-10-15', now), '2026-10-15');
  assertEquals(validDate('2026-12-01', now), null);
  assertEquals(validDate('2019-01-01', now), null);
  assertEquals(validDate('10/15/2026', now), null);
});

Deno.test('shapeExtraction maps the hint, clamps confidence, nulls a zero amount, keeps structured items', () => {
  const r = shapeExtraction({ amount: 0, date: '2026-10-15', vendor: 'Zz', category_hint: 'loan', confidence: 4, line_items: ['soap', { description: 'bleach', qty: 2, unit_cost: 30 }] },
    new Set(['loan', 'other']), Date.parse('2026-10-16T00:00:00Z'));
  assertEquals(r.amount, null);
  assertEquals(r.category, 'loan');
  assertEquals(r.confidence, 1);
  assertEquals(r.line_items, [{ description: 'soap', qty: null, unit_cost: null }, { description: 'bleach', qty: 2, unit_cost: 30 }]);
});

Deno.test('supply mode needs report_supply; every other mode, a bad body and a missing mode keep approve_payment', () => {
  assertEquals(gateAction({ mode: 'supply' }), 'report_supply');
  for (const b of [{ mode: 'extract' }, {}, null, { mode: 'Supply' }]) assertEquals(gateAction(b), 'approve_payment');
});

Deno.test('index.ts gates on gateAction before any work, and still names approve_payment nowhere weaker', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertEquals(src.includes('requireStaffAccess(req, gateAction(body), PROPERTY_ID)'), true);
  assertEquals(src.indexOf('gateAction(body)') < src.indexOf("body.mode === 'supply'"), true);
  assertEquals(/requireStaffAccess\(req, 'report_supply'/.test(src), false);
});

Deno.test('scrubMoney strips prices from a description and keeps sizes (D-330)', () => {
  assertEquals(scrubMoney('TISSUE 12S ₱45.00'), 'TISSUE 12S');
  assertEquals(scrubMoney('NATURES SPRING 500ML 25.00'), 'NATURES SPRING 500ML');
  assertEquals(scrubMoney('SAFEGUARD WHT 135G P 52.75'), 'SAFEGUARD WHT 135G');
  assertEquals(scrubMoney('BATH TISSUE 2PLY PHP 1,234.50'), 'BATH TISSUE 2PLY');
  assertEquals(scrubMoney('1,234.50 BLEACH 1.5L'), 'BLEACH 1.5L');
  assertEquals(scrubMoney('P99 SOAP'), 'SOAP');
  assertEquals(scrubMoney('PANTENE SHAMPOO 12S'), 'PANTENE SHAMPOO 12S');
  assertEquals(scrubMoney('₱45.00'), 'Item');
});

// ===== s134 L3 (D-405): sign, attach, PDF, supply by path, upload proof. Handlers run with fakes for the database, storage, the caller's RPC and the vision read. =====
const PROP = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const USER = '11111111-2222-4333-8444-555555555555';
const OTHER = '99999999-2222-4333-8444-555555555555';
const UUID_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const UUID_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const UUID_C = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const OWN_PATH = `${PROP}/${USER}/${UUID_A}.jpg`;
const bytesToB64 = (b: Uint8Array) => { let s = ''; for (const x of b) s += String.fromCharCode(x); return btoa(s); };
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
const JPEG_B64 = bytesToB64(JPEG);
const pdfBytes = (n: number) => { const b = new Uint8Array(n); b.set([0x25, 0x50, 0x44, 0x46, 0x2d]); return b; };

type Cfg = { tables?: Record<string, { data?: unknown[]; count?: number; error?: { message: string } | null; insertError?: boolean }>; objects?: Record<string, Uint8Array>; uploadError?: boolean };

function fakeDb(cfg: Cfg = {}) {
  const inserts: Array<{ table: string; row: Record<string, unknown> }> = [];
  const uploads: Array<{ bucket: string; path: string; contentType: string }> = [];
  const downloads: string[] = [];
  const removes: string[] = [];
  const signed: Array<{ bucket: string; path: string; seconds: number }> = [];
  const objects = new Map(Object.entries(cfg.objects ?? {}));
  // deno-lint-ignore no-explicit-any
  const from = (table: string): any => {
    const t = cfg.tables?.[table] ?? {};
    let ins = false, head = false;
    // deno-lint-ignore no-explicit-any
    const b: any = {};
    for (const m of ['eq', 'neq', 'gte', 'order', 'limit', 'in']) b[m] = () => b;
    b.select = (_c?: string, o?: { head?: boolean }) => { if (o?.head) head = true; return b; };
    b.insert = (row: Record<string, unknown>) => { inserts.push({ table, row }); ins = true; return b; };
    b.single = () => Promise.resolve(ins ? (t.insertError ? { data: null, error: { message: 'insert broke' } } : { data: { id: 'draft-new' }, error: null }) : { data: (t.data ?? [])[0] ?? null, error: null });
    b.then = (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) =>
      Promise.resolve(ins ? { error: t.insertError ? { message: 'insert broke' } : null } : head ? { count: t.count ?? 0, error: t.error ?? null } : { data: t.data ?? [], error: t.error ?? null }).then(res, rej);
    return b;
  };
  const storage = {
    from: (bucket: string) => ({
      upload: (path: string, bytes: Uint8Array, o: { contentType: string }) => { uploads.push({ bucket, path, contentType: o.contentType }); if (cfg.uploadError) return Promise.resolve({ error: { message: 'x' } }); objects.set(path, bytes); return Promise.resolve({ error: null }); },
      download: (path: string) => { downloads.push(path); const o = objects.get(path); return Promise.resolve(o ? { data: { arrayBuffer: () => Promise.resolve(o.buffer.slice(o.byteOffset, o.byteOffset + o.byteLength)) }, error: null } : { data: null, error: { message: 'not found' } }); },
      remove: (paths: string[]) => { removes.push(...paths); return Promise.resolve({ error: null }); },
      createSignedUrl: (path: string, seconds: number) => { signed.push({ bucket, path, seconds }); return Promise.resolve({ data: { signedUrl: `https://signed.example/${bucket}/${path}` }, error: null }); },
    }),
  };
  return { db: { from, storage }, inserts, uploads, downloads, removes, signed };
}

const PARSED = { amount: 540, date: '2026-11-20', vendor: 'Demo shop', category_hint: 'supplies', line_items: [{ description: 'TISSUE 2PLY 12S', qty: 2, unit_cost: 45 }], confidence: 0.9 };
const ITEMS = { inventory_items: { data: [{ id: 'item-1', name: 'Bath tissue 2PLY 12S' }] }, inventory_item_options: { data: [] }, expense_categories: { data: [{ slug: 'supplies' }, { slug: 'guest_refund' }, { slug: 'other' }] } };

function deps(f: ReturnType<typeof fakeDb>, over: Partial<Deps> = {}): Deps & { rpcCalls: Array<{ fn: string; args: Record<string, unknown> }>; reads: number } {
  const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const state = { reads: 0 };
  let n = 0;
  const d: Deps = {
    db: f.db, propertyId: PROP, newId: () => `00000000-0000-4000-8000-00000000000${++n}`, toB64: bytesToB64,
    read: () => { state.reads++; return Promise.resolve(PARSED); },
    callerRpc: (fn, args) => { rpcCalls.push({ fn, args }); return Promise.resolve({ data: [], error: null }); },
    signUrl: async (bucket, path, seconds) => (await f.db.storage.from(bucket).createSignedUrl(path, seconds)).data.signedUrl,
    ...over,
  };
  Object.defineProperty(d, 'reads', { get: () => state.reads });
  return Object.assign(d, { rpcCalls }) as Deps & { rpcCalls: typeof rpcCalls; reads: number };
}

Deno.test('sha256Hex is the standard digest', async () => {
  assertEquals(await sha256Hex(new TextEncoder().encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

Deno.test('decodeFile: a PDF up to 5 MB with %PDF- is accepted; over 5 MB is 413; a PDF mime on image bytes and an image mime on PDF bytes are 415; images behave as decodeImage', () => {
  const ok = decodeFile(bytesToB64(pdfBytes(1000)), 'application/pdf');
  assert(ok.ok && ok.pdf && ok.ext === 'pdf' && ok.mime === 'application/pdf');
  const edge = decodeFile(bytesToB64(pdfBytes(5 * 1024 * 1024)), 'application/pdf');
  assert(edge.ok, 'exactly 5 MB is allowed');
  assertEquals((decodeFile(bytesToB64(pdfBytes(5 * 1024 * 1024 + 1)), 'application/pdf') as { status: number }).status, 413);
  assertEquals((decodeFile(JPEG_B64, 'application/pdf') as { status: number }).status, 415);
  assertEquals((decodeFile(bytesToB64(pdfBytes(100)), 'image/jpeg') as { status: number }).status, 415);
  assertEquals((decodeFile('', 'application/pdf') as { status: number }).status, 400);
  const img = decodeFile(JPEG_B64, 'image/jpeg');
  assert(img.ok && !img.pdf && img.ext === 'jpg');
  assertEquals((decodeImage(bytesToB64(pdfBytes(100)), 'application/pdf') as { status: number }).status, 415, 'the old no-mode path still refuses a PDF');
});

Deno.test('checkSupplyPath: only <property>/<caller>/<uuid>.(jpg|png|webp); another user, a wrong tail, a .pdf and traversal are refused', () => {
  assertEquals(checkSupplyPath(OWN_PATH, PROP, USER), { ok: true, path: OWN_PATH });
  assertEquals((checkSupplyPath(`${PROP}/${OTHER}/${UUID_A}.jpg`, PROP, USER) as { error: string }).error, 'invalid_receipt_path');
  assertEquals((checkSupplyPath(`${PROP}/${USER}/${UUID_A}.jpg.exe`, PROP, USER) as { error: string }).error, 'invalid_receipt_path');
  assertEquals((checkSupplyPath(`${PROP}/${USER}/notes.jpg`, PROP, USER) as { error: string }).error, 'invalid_receipt_path');
  assertEquals((checkSupplyPath(`${PROP}/${USER}/../${OTHER}/${UUID_A}.jpg`, PROP, USER) as { error: string }).error, 'invalid_receipt_path');
  assertEquals((checkSupplyPath(`${PROP}/${USER}/${UUID_A}.pdf`, PROP, USER) as { error: string; status: number }).error, 'unsupported_image_type');
  assertEquals((checkSupplyPath(`other/${USER}/${UUID_A}.jpg`, PROP, USER) as { error: string }).error, 'invalid_receipt_path');
  assertEquals([checkSupplyPath(undefined, PROP, USER).ok, checkSupplyPath(42, PROP, USER).ok], [false, false]);
});

Deno.test('pairAllowed is the kind-to-bucket map, and nothing else', () => {
  for (const [k, b] of [['txn', 'expense-receipts'], ['draft', 'expense-receipts'], ['draft', 'inventory-photos'], ['bill', 'cleaning-photos'], ['stock', 'inventory-photos']]) assert(pairAllowed(k, b), `${k} ${b}`);
  for (const [k, b] of [['txn', 'cleaning-photos'], ['txn', 'inventory-photos'], ['bill', 'expense-receipts'], ['stock', 'cleaning-photos'], ['pay', 'cleaning-photos'], ['txn', 'guest-id-photos'], ['__proto__', 'x'], [null, 'expense-receipts']]) assertFalse(pairAllowed(k, b), `${k} ${b}`);
});

Deno.test('stockHint counts the read lines that match an item or option title; none gives 0', () => {
  const cands = [{ item_id: 'item-1', names: ['Bath tissue 2PLY 12S', 'Tissue roll'] }, { item_id: 'item-2', names: ['Bleach 1L'] }];
  const lines = [{ description: 'TISSUE 2PLY 12S', qty: 1, unit_cost: 45 }, { description: 'BLEACH 1L', qty: 1, unit_cost: 60 }, { description: 'UMBRELLA', qty: 1, unit_cost: 300 }];
  assertEquals(stockHint(lines, cands), { count: 2, names: ['Bath tissue 2PLY 12S', 'Bleach 1L'] });
  assertEquals(stockHint([{ description: 'UMBRELLA', qty: 1, unit_cost: 300 }], cands), { count: 0, names: [] });
  assertEquals(stockHint([], cands), NO_HINT);
});

// ---- sign ----

const ROW = (id: string, over: Record<string, unknown> = {}) => ({ id, kind: 'txn', bucket: 'expense-receipts', path: `${PROP}/${USER}/${id}.jpg`, mime: 'image/jpeg', ...over });

Deno.test('sign: links only for ids the RPC returned, for 300 s, from the pairs the RPC named; nothing from the body', async () => {
  const f = fakeDb();
  const d = deps(f, { callerRpc: (fn, args) => { (d as unknown as { rpcCalls: unknown[] }).rpcCalls.push({ fn, args }); return Promise.resolve({ data: [ROW(UUID_A), ROW(UUID_C), { ...ROW(UUID_B), kind: 'bill', bucket: 'cleaning-photos', path: `${PROP}/${UUID_B}/proof.jpg` }], error: null }); } });
  // the request asks for A and B; it also tries to name a path, a bucket and a different property's file
  const r = await signHandler({ mode: 'sign', property_id: PROP, ids: [UUID_A, UUID_B], path: 'x/y/z.jpg', paths: ['secret.jpg'], bucket: 'guest-id-photos' }, d);
  assertEquals(r.status, 200);
  const links = (r.body as { links: Record<string, { url: string; kind: string }> }).links;
  assertEquals(Object.keys(links).sort(), [UUID_A, UUID_B].sort(), 'C was never asked for, so it is never signed');
  assertEquals(f.signed.map((s) => [s.bucket, s.path, s.seconds]).sort(), [['cleaning-photos', `${PROP}/${UUID_B}/proof.jpg`, 300], ['expense-receipts', `${PROP}/${USER}/${UUID_A}.jpg`, 300]].sort());
  assertEquals(SIGN_SECONDS, 300);
  assertEquals(links[UUID_B].kind, 'bill');
  const only = (d as unknown as { rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> }).rpcCalls;
  assertEquals(only, [{ fn: 'expense_receipt_paths_v1', args: { p_property_id: PROP, p_ids: [UUID_A, UUID_B] } }], 'the RPC gets the function constant and the ids, never a body path or property');
  assertFalse(JSON.stringify(f.signed).includes('secret.jpg') || JSON.stringify(f.signed).includes('guest-id-photos'));
});

Deno.test('sign: a caller the RPC refuses gets no link (cleaner), by error or by an answer that is not a list', async () => {
  for (const reply of [{ data: null, error: { code: '42501', message: 'permission denied' } }, { data: null, error: { message: 'forbidden' } }, { data: { ok: false, error: 'forbidden' }, error: null }]) {
    const f = fakeDb();
    const r = await signHandler({ mode: 'sign', ids: [UUID_A] }, deps(f, { callerRpc: () => Promise.resolve(reply) }));
    assertEquals([r.status, (r.body as { error: string }).error], [403, 'forbidden']);
    assertEquals(f.signed.length, 0);
  }
  const empty = await signHandler({ mode: 'sign', ids: [UUID_A] }, deps(fakeDb()));
  assertEquals([empty.status, (empty.body as { links: object }).links], [200, {}]);
});

Deno.test('sign: a bucket outside the map is refused even when a (faked) RPC row names it; so is a kind-bucket mismatch and a traversal path', async () => {
  const f = fakeDb();
  const rows = [ROW(UUID_A, { bucket: 'guest-id-photos' }), ROW(UUID_B, { kind: 'txn', bucket: 'cleaning-photos' }), ROW(UUID_C, { path: `${PROP}/../x.jpg` })];
  const r = await signHandler({ mode: 'sign', ids: [UUID_A, UUID_B, UUID_C] }, deps(f, { callerRpc: () => Promise.resolve({ data: rows, error: null }) }));
  assertEquals((r.body as { links: object }).links, {});
  assertEquals(f.signed.length, 0, 'the service role signed nothing');
});

Deno.test('sign: more than 20 ids, no ids, a malformed id and a different property are refused before any RPC call', async () => {
  const f = fakeDb();
  const d = deps(f);
  const many = Array.from({ length: 21 }, (_, i) => `aaaaaaaa-aaaa-4aaa-8aaa-${String(i).padStart(12, '0')}`);
  assertEquals((await signHandler({ mode: 'sign', ids: many }, d)).body, { ok: false, error: 'too_many_ids' });
  assertEquals((await signHandler({ mode: 'sign', ids: [] }, d)).status, 400);
  assertEquals((await signHandler({ mode: 'sign' }, d)).status, 400);
  assertEquals((await signHandler({ mode: 'sign', ids: ['not-a-uuid'] }, d)).body, { ok: false, error: 'invalid_ids' });
  const wrong = await signHandler({ mode: 'sign', property_id: OTHER, ids: [UUID_A] }, d);
  assertEquals([wrong.status, (wrong.body as { error: string }).error], [403, 'property_mismatch']);
  assertEquals(d.rpcCalls.length, 0);
  const twenty = Array.from({ length: 20 }, (_, i) => `aaaaaaaa-aaaa-4aaa-8aaa-${String(i).padStart(12, '0')}`);
  assertEquals((await signHandler({ mode: 'sign', ids: twenty }, d)).status, 200, 'exactly 20 is allowed');
});

Deno.test('sign works with no vision key: the handler needs no read, and index.ts runs it before the key check', async () => {
  const f = fakeDb();
  const r = await signHandler({ mode: 'sign', ids: [UUID_A] }, deps(f, { read: null, callerRpc: () => Promise.resolve({ data: [ROW(UUID_A)], error: null }) }));
  assertEquals(r.status, 200);
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  const key = src.indexOf('if (!hasVisionKey())');
  for (const needle of ["body.mode === 'sign'", "body.mode === 'attach'", "body.mode === 'extract' && isPdfMime"]) assert(src.indexOf(needle) > 0 && src.indexOf(needle) < key, needle);
  assert(src.indexOf('requireStaffAccess(req, gateAction(body)') < src.indexOf("body.mode === 'sign'"), 'the staff gate comes first');
  assertFalse(/console\.(log|warn|error)\([^)]*(signedUrl|signUrl|links)/.test(src), 'no link in a log line');
});

// ---- attach ----

Deno.test('attach: a jpeg is stored under <property>/<caller>/, hashed, proof row written, read and returned with a suggestion; no ledger row is written', async () => {
  const f = fakeDb({ tables: ITEMS });
  const d = deps(f);
  const r = await attachHandler({ mode: 'attach', file_base64: JPEG_B64, mime_type: 'image/jpeg' }, { userId: USER }, d);
  assertEquals(r.status, 200);
  const b = r.body as Record<string, any>;
  assertEquals(b.ok, true);
  assertEquals(b.receipt_path, `${PROP}/${USER}/00000000-0000-4000-8000-000000000001.jpg`);
  assertEquals(b.sha256, await sha256Hex(JPEG));
  assertEquals(b.mime, 'image/jpeg');
  assertEquals(b.suggest, { amount: 540, date: '2026-11-20', vendor: 'Demo shop', category: 'supplies', line_items: [{ description: 'TISSUE 2PLY 12S', qty: 2, unit_cost: 45 }], confidence: 0.9 });
  assertEquals(b.stock_hint, { count: 1, names: ['Bath tissue 2PLY 12S'] });
  assertEquals(f.uploads, [{ bucket: 'expense-receipts', path: b.receipt_path, contentType: 'image/jpeg' }]);
  assertEquals(f.inserts, [{ table: 'staff_upload_hashes', row: { path: b.receipt_path, sha256: b.sha256, uploaded_by: USER } }], 'one proof row, nothing in transactions');
  assertEquals(d.reads, 1);
  assertFalse(f.inserts.some((i) => i.table === 'transactions'));
});

Deno.test('attach: a read failure still returns the path and the hash (and the proof row stands)', async () => {
  const f = fakeDb({ tables: ITEMS });
  const r = await attachHandler({ file_base64: JPEG_B64, mime_type: 'image/jpeg' }, { userId: USER }, deps(f, { read: () => Promise.reject(new Error('vision down')) }));
  const b = r.body as Record<string, any>;
  assertEquals([r.status, b.ok, b.suggest, b.unread, typeof b.receipt_path, typeof b.sha256], [200, true, null, 'failed', 'string', 'string']);
  assertEquals(f.inserts.length, 1);
  assertEquals(f.removes, [], 'the file is kept');
});

Deno.test('attach: read:false and no vision key store and hash without a read', async () => {
  const f1 = fakeDb({ tables: ITEMS }); const d1 = deps(f1);
  const a = await attachHandler({ file_base64: JPEG_B64, mime_type: 'image/jpeg', read: false }, { userId: USER }, d1);
  assertEquals([(a.body as any).unread, d1.reads], ['skipped', 0]);
  const b = await attachHandler({ file_base64: JPEG_B64, mime_type: 'image/jpeg' }, { userId: USER }, deps(fakeDb({ tables: ITEMS }), { read: null }));
  assertEquals([(b.body as any).ok, (b.body as any).unread, typeof (b.body as any).receipt_path], [true, 'no_key', 'string']);
});

Deno.test('attach: a PDF is stored and hashed with unread pdf, makes no vision call and works with no key; over 5 MB is 413; wrong type is 415 and nothing is stored', async () => {
  const f = fakeDb({ tables: ITEMS }); const d = deps(f, { read: null });
  const pdf = pdfBytes(2000);
  const r = await attachHandler({ file_base64: bytesToB64(pdf), mime_type: 'application/pdf' }, { userId: USER }, d);
  const b = r.body as Record<string, any>;
  assertEquals([r.status, b.ok, b.unread, b.suggest, b.mime, b.sha256, b.stock_hint], [200, true, 'pdf', null, 'application/pdf', await sha256Hex(pdf), NO_HINT]);
  assert(String(b.receipt_path).startsWith(`${PROP}/${USER}/`) && String(b.receipt_path).endsWith('.pdf'));
  assertEquals(f.uploads[0].contentType, 'application/pdf');
  const f2 = fakeDb(); const d2 = deps(f2);
  assertEquals((await attachHandler({ file_base64: bytesToB64(pdfBytes(5 * 1024 * 1024 + 1)), mime_type: 'application/pdf' }, { userId: USER }, d2)).status, 413);
  assertEquals((await attachHandler({ file_base64: JPEG_B64, mime_type: 'application/pdf' }, { userId: USER }, d2)).status, 415);
  assertEquals((await attachHandler({ file_base64: bytesToB64(pdfBytes(100)), mime_type: 'image/png' }, { userId: USER }, d2)).status, 415);
  assertEquals([f2.uploads.length, f2.inserts.length, d2.reads], [0, 0, 0]);
});

Deno.test('attach: the proof row carries the caller id and the server sha; a missing proof row is a loud failure, an upload failure stores nothing', async () => {
  const f = fakeDb({ tables: { staff_upload_hashes: { insertError: true } } });
  const r = await attachHandler({ file_base64: JPEG_B64, mime_type: 'image/jpeg' }, { userId: USER }, deps(f));
  assertEquals([r.status, (r.body as any).error], [500, 'hash_failed']);
  const g = fakeDb({ uploadError: true });
  const u = await attachHandler({ file_base64: JPEG_B64, mime_type: 'image/jpeg' }, { userId: USER }, deps(g));
  assertEquals([u.status, (u.body as any).error, g.inserts.length], [500, 'upload_failed', 0]);
});

Deno.test('attach cannot write outside <property>/<caller>/: the path is built from the constants, never from the body', async () => {
  const f = fakeDb();
  await attachHandler({ file_base64: JPEG_B64, mime_type: 'image/jpeg', path: 'elsewhere/x.jpg', receipt_path: 'elsewhere/y.jpg', property_id: OTHER, user_id: OTHER }, { userId: USER }, deps(f));
  assertEquals(f.uploads.length, 1);
  assert(f.uploads[0].path.startsWith(`${PROP}/${USER}/`));
  assertFalse(f.uploads[0].path.includes('elsewhere') || f.uploads[0].path.includes(OTHER));
});

// ---- supply by path ----

Deno.test('supply by path: an own file is read and held as a draft; no second upload; the draft carries the path; only the draft id comes back', async () => {
  const f = fakeDb({ tables: { ...ITEMS, inventory_receipt_drafts: { data: [], count: 0 }, transactions: { data: [] } }, objects: { [OWN_PATH]: JPEG } });
  const r = await supplyByPath({ mode: 'supply', receipt_path: OWN_PATH }, { userId: USER }, deps(f));
  assertEquals([r.status, r.body], [200, { ok: true, draft_id: 'draft-new' }]);
  assertEquals(f.uploads.length, 0);
  assertEquals(f.downloads, [OWN_PATH]);
  const ins = f.inserts.find((i) => i.table === 'inventory_receipt_drafts')!.row as Record<string, any>;
  assertEquals([ins.receipt_path, ins.created_by, ins.status, ins.property_id], [OWN_PATH, USER, 'draft', PROP]);
  assertEquals(ins.lines[0].match_item_id, 'item-1');
  assertEquals(f.removes, []);
});

Deno.test('supply by path: another user\'s prefix, a wrong tail and a .pdf are refused before anything is read', async () => {
  const f = fakeDb({ objects: { [`${PROP}/${OTHER}/${UUID_A}.jpg`]: JPEG } });
  const d = deps(f);
  for (const [p, st, er] of [[`${PROP}/${OTHER}/${UUID_A}.jpg`, 400, 'invalid_receipt_path'], [`${PROP}/${USER}/${UUID_A}.jpg/x`, 400, 'invalid_receipt_path'], [`${PROP}/${USER}/${UUID_A}.pdf`, 415, 'unsupported_image_type']] as const) {
    const r = await supplyByPath({ receipt_path: p }, { userId: USER }, d);
    assertEquals([r.status, (r.body as any).error], [st, er]);
  }
  assertEquals([f.downloads.length, f.removes.length, f.inserts.length, d.reads], [0, 0, 0, 0]);
});

Deno.test('supply by path: a missing object is refused and nothing is removed; bytes that are not the declared image are 415', async () => {
  const f = fakeDb({ tables: { inventory_receipt_drafts: { data: [] }, transactions: { data: [] } } });
  const r = await supplyByPath({ receipt_path: OWN_PATH }, { userId: USER }, deps(f));
  assertEquals([r.status, (r.body as any).error, f.removes.length], [404, 'receipt_not_found', 0]);
  const g = fakeDb({ tables: { inventory_receipt_drafts: { data: [] }, transactions: { data: [] } }, objects: { [OWN_PATH]: pdfBytes(50) } });
  assertEquals((await supplyByPath({ receipt_path: OWN_PATH }, { userId: USER }, deps(g))).status, 415);
  assertEquals(g.removes, []);
});

Deno.test('supply by path: a second call with the same path returns the same draft id and creates nothing', async () => {
  const f = fakeDb({ tables: { inventory_receipt_drafts: { data: [{ id: 'draft-first' }] } }, objects: { [OWN_PATH]: JPEG } });
  const d = deps(f);
  const r = await supplyByPath({ receipt_path: OWN_PATH }, { userId: USER }, d);
  assertEquals([r.status, r.body], [200, { ok: true, draft_id: 'draft-first' }]);
  assertEquals([f.inserts.length, f.downloads.length, d.reads], [0, 0, 0]);
});

Deno.test('supply by path: a path held by a non-void expense answers receipt_in_use and the file stays', async () => {
  const f = fakeDb({ tables: { inventory_receipt_drafts: { data: [] }, transactions: { data: [{ id: 'txn-1' }] } }, objects: { [OWN_PATH]: JPEG } });
  const r = await supplyByPath({ receipt_path: OWN_PATH }, { userId: USER }, deps(f));
  assertEquals([r.status, r.body], [409, { ok: false, error: 'receipt_in_use' }]);
  assertEquals([f.removes.length, f.inserts.length], [0, 0]);
});

Deno.test('supply by path: a failed read and a failed draft insert keep the object', async () => {
  const base = { tables: { ...ITEMS, inventory_receipt_drafts: { data: [] }, transactions: { data: [] } }, objects: { [OWN_PATH]: JPEG } } as Cfg;
  const f = fakeDb(base);
  const bad = await supplyByPath({ receipt_path: OWN_PATH }, { userId: USER }, deps(f, { read: () => Promise.reject(new Error('down')) }));
  assertEquals([bad.status, (bad.body as any).error, f.removes.length, f.inserts.length], [502, 'ocr_failed', 0, 0]);
  const g = fakeDb(base);
  const empty = await supplyByPath({ receipt_path: OWN_PATH }, { userId: USER }, deps(g, { read: () => Promise.resolve({ amount: null, line_items: [] }) }));
  assertEquals([empty.status, g.removes.length], [502, 0]);
  const h = fakeDb({ ...base, tables: { ...base.tables, inventory_receipt_drafts: { data: [], insertError: true } } });
  const ins = await supplyByPath({ receipt_path: OWN_PATH }, { userId: USER }, deps(h));
  assertEquals([ins.status, (ins.body as any).error, h.removes.length], [500, 'insert_failed', 0]);
});

Deno.test('supply by path keeps the daily cap; the base64 path in index.ts is untouched and still removes its own orphan', async () => {
  const f = fakeDb({ tables: { inventory_receipt_drafts: { data: [], count: 20 } }, objects: { [OWN_PATH]: JPEG } });
  const r = await supplyByPath({ receipt_path: OWN_PATH }, { userId: USER }, deps(f));
  assertEquals([r.status, (r.body as any).error], [429, 'daily_limit']);
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, "if (!body.image_base64 && body.receipt_path !== undefined)");
  assertEquals(src.split("await db.storage.from(RECEIPTS_BUCKET).remove([path]).catch(() => {});").length - 1, 2, 'both orphan removals of the base64 path remain');
  assertStringIncludes(src, "const img = decodeImage(body.image_base64, body.mime_type);\n  if (!img.ok) return json({ ok: false, error: img.error }, img.status);\n  const db = createClient(SUPABASE_URL, SERVICE_ROLE);\n  // At most");
});

Deno.test('index.ts: extract answers add sha256, stock_hint and the proof flag; the old no-mode path still answers 415 for a PDF; gates per mode are unchanged', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, "if (mimeIsPdf)".replace('mimeIsPdf', 'img.pdf'));
  assertStringIncludes(src, "stock_hint: await stockHintFor(db, PROPERTY_ID, x.line_items), ...proof");
  assertStringIncludes(src, "error: 'pdf_not_supported_inline'");
  assertStringIncludes(src, "if (mime === 'application/pdf') {");
  assertEquals(gateAction({ mode: 'sign' }), 'approve_payment');
  assertEquals(gateAction({ mode: 'attach' }), 'approve_payment');
  assertEquals(gateAction({ mode: 'supply' }), 'report_supply');
});

// ---- s134 fix round 1: per-user daily upload cap ----

Deno.test('upload cap: 100 stored uploads a day per caller; the 101st is refused with 429 and nothing is stored (attach)', async () => {
  assertEquals(UPLOAD_DAILY_LIMIT, 100);
  const under = fakeDb({ tables: { ...ITEMS, staff_upload_hashes: { count: 99 } } });
  const ok = await attachHandler({ file_base64: JPEG_B64, mime_type: 'image/jpeg', read: false }, { userId: USER }, deps(under));
  assertEquals(ok.status, 200);
  assertEquals(under.uploads.length, 1);
  const full = fakeDb({ tables: { ...ITEMS, staff_upload_hashes: { count: 100 } } });
  const d = deps(full);
  const r = await attachHandler({ file_base64: JPEG_B64, mime_type: 'image/jpeg' }, { userId: USER }, d);
  assertEquals([r.status, r.body], [429, { ok: false, error: 'daily_limit' }]);
  assertEquals([full.uploads.length, full.inserts.length, d.reads], [0, 0, 0]);
});

Deno.test('upload cap: the same cap guards storeUpload for extract, and a failed count check stores nothing', async () => {
  const f = fakeDb({ tables: { staff_upload_hashes: { count: 100 } } });
  const img = decodeFile(JPEG_B64, 'image/jpeg');
  if (!img.ok) throw new Error('fixture');
  const st = await storeUpload(img, { userId: USER }, deps(f));
  assertEquals(st.ok, false);
  if (!st.ok) assertEquals([st.out.status, st.out.body], [429, { ok: false, error: 'daily_limit' }]);
  assertEquals(f.uploads.length, 0);
  const g = fakeDb({ tables: { staff_upload_hashes: { error: { message: 'down' } } } });
  const st2 = await storeUpload(img, { userId: USER }, deps(g));
  assertEquals(st2.ok, false);
  if (!st2.ok) assertEquals(st2.out.status, 500);
  assertEquals(g.uploads.length, 0);
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assert(src.includes('storeUpload(img, who, buildDeps(db))'), 'extract mode goes through storeUpload');
});
