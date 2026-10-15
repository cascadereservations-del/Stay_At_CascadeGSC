// Handler tests: globalThis.fetch is stubbed, so the mock sees the exact Supabase URLs, RPC names, argument keys and the Telegram multipart.
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import { withObservability } from '../_shared/observability.ts';
import { drawnText, it, ITEMS, NOW, SHOP } from './fixtures.ts';
import type { Item } from './report.ts';
import { makeHandler, PROPERTY_ID } from './handler.ts';

const OPT = { sanitizeOps: false, sanitizeResources: false };
const URL_ = 'https://proj.test';
const ENV = { SUPABASE_URL: URL_, SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key', TELEGRAM_BOT_TOKEN: 'tok', TELEGRAM_CHAT_ID: '-100OPS', TELEGRAM_FINANCE_CHAT_ID: '-100FIN' };

interface Call { method: string; url: string; json?: Record<string, unknown>; form?: FormData }
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });

/** Install the stubs for one test. `allowed` = the actions current_staff_authorized says yes to. */
function world(o: { items?: Item[]; allowed?: string[]; noUser?: boolean; tg?: unknown; parMissing?: boolean; env?: Partial<typeof ENV>;
  codes?: unknown[]; links?: unknown[]; suppliers?: unknown[]; purchases?: unknown[]; noSuppliers?: boolean } = {}) {
  const calls: Call[] = [];
  const env = { ...ENV, ...o.env };
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(env)) { saved.set(k, Deno.env.get(k)); if (v) Deno.env.set(k, v); else Deno.env.delete(k); }
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    const url = req.url;
    const call: Call = { method: req.method, url };
    if (init?.body instanceof FormData) call.form = init.body;
    else if (req.method === 'POST') call.json = await req.clone().json().catch(() => undefined);
    calls.push(call);
    if (url.startsWith('https://api.telegram.org/')) return json(o.tg ?? { ok: true, result: { message_id: 77 } });
    if (url.includes('/auth/v1/user')) return o.noUser ? json({ msg: 'bad jwt' }, 401) : json({ id: '3f1c2a52-6b7d-4e0e-9c11-0a5d3f6a7b21', email: 'marifel.santos@staff.cascade.invalid', app_metadata: {}, user_metadata: {}, aud: 'authenticated' });
    if (url.includes('/auth/v1/admin/users/')) return json({ id: '3f1c2a52-6b7d-4e0e-9c11-0a5d3f6a7b21', email: 'marifel.santos@staff.cascade.invalid', app_metadata: { display_name: 'Marifel Santos' }, user_metadata: {} });
    if (url.includes('/rpc/current_staff_authorized')) return json((o.allowed ?? ['read_operations']).includes(String(call.json?.p_action)));
    if (url.includes('/rest/v1/inventory_items')) {
      if (o.parMissing && url.includes('par_qty')) return json({ code: '42703', message: 'column inventory_items.par_qty does not exist', details: null }, 400);
      return json((o.items ?? ITEMS).map((i) => ({
        id: i.id, name: i.name, category: i.category, unit: i.unit, qty_on_hand: i.qty, reorder_below: i.reorder, is_consumable: i.consumable,
        purchase_unit: i.purchaseUnit, units_per_purchase: i.unitsPer, unit_cost: i.cost ?? null, par_qty: i.par,
      })));
    }
    if (url.includes('/rest/v1/inventory_shopping_list')) {
      return json(SHOP.map((s) => ({ item_id: s.itemId, item_name: s.name, quantity: s.quantity, purchase_unit: s.purchaseUnit, reason: s.note, estimated_cost: s.estCost })));
    }
    if (url.includes('/rest/v1/inventory_item_codes')) return json(o.codes ?? []);
    if (url.includes('/rest/v1/inventory_item_suppliers')) return o.noSuppliers ? json({ code: '42P01', message: 'relation does not exist' }, 404) : json(o.links ?? []);
    if (url.includes('/rest/v1/inventory_suppliers')) return o.noSuppliers ? json({ code: '42P01', message: 'relation does not exist' }, 404) : json(o.suppliers ?? []);
    if (url.includes('/rest/v1/inventory_purchases')) {
      if (o.noSuppliers && url.includes('supplier_id')) return json({ code: '42703', message: 'column inventory_purchases.supplier_id does not exist' }, 400);
      return json(o.purchases ?? []);
    }
    return json({ error: 'unexpected ' + url }, 500);
  }) as typeof fetch;
  return {
    calls,
    done() { globalThis.fetch = realFetch; for (const [k, v] of saved) { if (v === undefined) Deno.env.delete(k); else Deno.env.set(k, v); } },
  };
}

const post = (body: unknown, headers: Record<string, string> = { authorization: 'Bearer staff.jwt', apikey: 'anon', 'content-type': 'application/json' }) =>
  new Request(`${URL_}/functions/v1/inventory-report`, { method: 'POST', headers, body: typeof body === 'string' ? body : JSON.stringify(body) });
const handler = makeHandler({ now: () => NOW });
const telegram = (calls: Call[]) => calls.filter((c) => c.url.includes('api.telegram.org'));

Deno.test({ name: 'preflight: 204 and the four allowed headers, through the observability wrapper too', ...OPT, fn: async () => {
  const w = world();
  try {
    const wrapped = withObservability({ functionName: 'inventory-report', route: 'ops' }, handler);
    for (const h of [handler, wrapped]) {
      const res = await h(new Request(`${URL_}/functions/v1/inventory-report`, { method: 'OPTIONS', headers: { origin: 'https://staff.example', 'access-control-request-method': 'POST' } }));
      assertEquals(res.status, 204);
      const allowed = (res.headers.get('access-control-allow-headers') ?? '').toLowerCase().split(',').map((x) => x.trim());
      for (const need of ['authorization', 'apikey', 'x-client-info', 'content-type']) assert(allowed.includes(need), `missing ${need}: ${allowed}`);
      assertStringIncludes(res.headers.get('access-control-allow-methods') ?? '', 'POST');
      assertEquals(res.headers.get('access-control-allow-origin'), '*');
    }
    assertEquals(w.calls.length, 0, 'a preflight touches nothing');
  } finally { w.done(); }
} });

Deno.test({ name: 'no bearer -> 401; a bad session -> 401; no Telegram call', ...OPT, fn: async () => {
  const w = world({ noUser: true });
  try {
    assertEquals((await handler(post({ kind: 'low', to: 'ops' }, { 'content-type': 'application/json' }))).status, 401);
    const r = await handler(post({ kind: 'low', to: 'ops' }));
    assertEquals(r.status, 401);
    assertEquals(telegram(w.calls).length, 0);
  } finally { w.done(); }
} });

Deno.test({ name: 'a user without read_operations -> 403; the RPC is called with its exact name and keys', ...OPT, fn: async () => {
  const w = world({ allowed: [] });
  try {
    const r = await handler(post({ kind: 'low', to: 'ops' }));
    assertEquals(r.status, 403);
    const rpc = w.calls.find((c) => c.url.includes('/rpc/current_staff_authorized'))!;
    assertEquals(rpc.json, { p_action: 'read_operations', p_property_id: PROPERTY_ID });
    assertEquals(telegram(w.calls).length, 0);
  } finally { w.done(); }
} });

Deno.test({ name: 'bad kind, bad destination, broken body -> 400, nothing sent', ...OPT, fn: async () => {
  const w = world();
  try {
    for (const b of [{ kind: 'everything', to: 'ops' }, { kind: 'low', to: 'whatsapp' }, {}, 'not json']) {
      const r = await handler(post(b));
      assertEquals(r.status, 400);
      assertEquals((await r.json()).error, 'bad_request');
    }
    assertEquals(telegram(w.calls).length, 0);
  } finally { w.done(); }
} });

Deno.test({ name: 'a cleaner asking for the Finance group -> 403 finance_only, no read, no Telegram', ...OPT, fn: async () => {
  const w = world({ allowed: ['read_operations'] });
  try {
    const r = await handler(post({ kind: 'order', to: 'finance' }));
    assertEquals(r.status, 403);
    assertEquals((await r.json()).error, 'finance_only');
    const actions = w.calls.filter((c) => c.url.includes('/rpc/')).map((c) => c.json?.p_action);
    assertEquals(actions, ['read_operations', 'read_finance']);
    assertEquals(telegram(w.calls).length, 0);
    assertFalse(w.calls.some((c) => c.url.includes('/rest/v1/inventory_items')), 'no inventory read for a refused caller');
  } finally { w.done(); }
} });

Deno.test({ name: 'OPS send: sendDocument to the OPS chat, multipart PDF, caption, no cost column ever selected, no money in the bytes or caption', ...OPT, fn: async () => {
  const w = world();
  try {
    const r = await handler(post({ kind: 'order', to: 'ops' }));
    assertEquals(r.status, 200);
    assertEquals(await r.json(), { ok: true, to: 'ops', kind: 'order', rows: 4, pages: 1, message_id: 77 });

    const reads = w.calls.filter((c) => c.url.includes('/rest/v1/inventory_'));
    assertEquals(reads.length, 2);
    for (const c of reads) assertFalse(/unit_cost|estimated_cost/.test(decodeURIComponent(c.url)), 'ops never selects a cost column: ' + c.url);
    assertStringIncludes(decodeURIComponent(reads[0].url), 'par_qty');
    assertStringIncludes(decodeURIComponent(reads[0].url), `property_id=eq.${PROPERTY_ID}`);
    assertStringIncludes(decodeURIComponent(reads[1].url), 'status=in.(proposed,approved)');

    const [tg] = telegram(w.calls);
    assertEquals(tg.url, 'https://api.telegram.org/bottok/sendDocument');
    assertEquals(tg.form!.get('chat_id'), '-100OPS');
    const doc = tg.form!.get('document') as File;
    assertEquals(doc.type, 'application/pdf');
    assertEquals(doc.name, 'cascade-order-2026-10-15.pdf');
    const bytes = new Uint8Array(await doc.arrayBuffer());
    assertEquals(String.fromCharCode(...bytes.slice(0, 5)), '%PDF-');
    const caption = String(tg.form!.get('caption'));
    assertEquals(caption, 'Order list, 4 items. Sent from the staff app by Marifel.');
    assertFalse(/PHP|₱|cost|price/i.test(caption));
    assertFalse(new TextDecoder().decode(bytes).includes('PHP'));
  } finally { w.done(); }
} });

Deno.test({ name: 'Finance send: Finance chat, cost columns selected, caller checked for read_finance under its own JWT', ...OPT, fn: async () => {
  const w = world({ allowed: ['read_operations', 'read_finance'] });
  try {
    const r = await handler(post({ kind: 'order', to: 'finance' }));
    assertEquals(r.status, 200);
    const [tg] = telegram(w.calls);
    assertEquals(tg.form!.get('chat_id'), '-100FIN');
    const reads = w.calls.filter((c) => c.url.includes('/rest/v1/inventory_'));
    assertStringIncludes(decodeURIComponent(reads[0].url), 'unit_cost');
    assertStringIncludes(decodeURIComponent(reads[1].url), 'estimated_cost');
    const fin = w.calls.find((c) => c.json?.p_action === 'read_finance')!;
    assertEquals(fin.json, { p_action: 'read_finance', p_property_id: PROPERTY_ID });
  } finally { w.done(); }
} });

Deno.test({ name: 'the shopping list is read only for the order kind', ...OPT, fn: async () => {
  const w = world();
  try {
    assertEquals((await handler(post({ kind: 'low', to: 'ops' }))).status, 200);
    assertFalse(w.calls.some((c) => c.url.includes('inventory_shopping_list')));
  } finally { w.done(); }
} });

Deno.test({ name: 'before the SQL release: par_qty missing -> the read retries without it and still sends', ...OPT, fn: async () => {
  const w = world({ parMissing: true });
  try {
    const r = await handler(post({ kind: 'low', to: 'ops' }));
    assertEquals(r.status, 200);
    const reads = w.calls.filter((c) => c.url.includes('/rest/v1/inventory_items'));
    assertEquals(reads.length, 2);
    assertFalse(decodeURIComponent(reads[1].url).includes('par_qty'));
  } finally { w.done(); }
} });

Deno.test({ name: 'Telegram says not ok -> 502 telegram_failed; no answer at all -> 502', ...OPT, fn: async () => {
  for (const tg of [{ ok: false, description: 'Bad Request: chat not found' }, 'garbage']) {
    const w = world({ tg });
    try {
      const r = await handler(post({ kind: 'low', to: 'ops' }));
      assertEquals(r.status, 502);
      assertEquals((await r.json()).error, 'telegram_failed');
    } finally { w.done(); }
  }
} });

Deno.test({ name: 'missing token or chat id -> 503 not_configured, nothing read or sent', ...OPT, fn: async () => {
  for (const [env, to] of [[{ TELEGRAM_BOT_TOKEN: '' }, 'ops'], [{ TELEGRAM_CHAT_ID: '' }, 'ops'], [{ TELEGRAM_FINANCE_CHAT_ID: '' }, 'finance']] as const) {
    const w = world({ allowed: ['read_operations', 'read_finance'], env });
    try {
      const r = await handler(post({ kind: 'low', to }));
      assertEquals(r.status, 503);
      assertEquals((await r.json()).error, 'not_configured');
      assertEquals(telegram(w.calls).length, 0);
    } finally { w.done(); }
  }
} });

Deno.test({ name: 'OPS "all" with 120 items: the count in the caption does not trip the money guard (F1)', ...OPT, fn: async () => {
  const items = Array.from({ length: 120 }, (_, k) => it({ id: `i${k}`, name: `Item ${k}`, qty: k }));
  const w = world({ items });
  try {
    const r = await handler(post({ kind: 'all', to: 'ops' }));
    assertEquals(r.status, 200);
    assertEquals(telegram(w.calls)[0].form!.get('caption'), 'Full inventory, 120 items. Sent from the staff app by Marifel.');
  } finally { w.done(); }
} });

// ---------- s86 D-report ----------
const U1 = '11111111-1111-4111-8111-111111111111', U2 = '22222222-2222-4222-8222-222222222222', U3 = '33333333-3333-4333-8333-333333333333';
const labelItems = [it({ id: U1, name: 'Bath towel' }), it({ id: U2, name: 'Alarm clock' }), it({ id: U3, name: 'No code item' })];
const codes = [{ item_id: U1, code: 'CH-AAAAAAAAAA', created_at: '2026-10-01' }, { item_id: U2, code: 'CH-BBBBBBBBBB', created_at: '2026-10-01' }];
const bytesOf = async (c: Call) => new Uint8Array(await (c.form!.get('document') as File).arrayBuffer());

Deno.test({ name: 'labels: manage_inventory gate -> 403 manage_only without it; nothing read or sent', ...OPT, fn: async () => {
  const w = world({ allowed: ['read_operations'], items: labelItems, codes });
  try {
    const r = await handler(post({ kind: 'labels' }));
    assertEquals(r.status, 403);
    assertEquals((await r.json()).error, 'manage_only');
    assertEquals(w.calls.find((c) => c.url.includes('/rpc/'))!.json, { p_action: 'manage_inventory', p_property_id: PROPERTY_ID });
    assertEquals(telegram(w.calls).length, 0);
    assertFalse(w.calls.some((c) => c.url.includes('/rest/v1/') && !c.url.includes('/rpc/')));
  } finally { w.done(); }
} });

Deno.test({ name: 'labels: Finance group by default, only coded items, name order, no cost column; to ops also allowed', ...OPT, fn: async () => {
  const w = world({ allowed: ['manage_inventory', 'read_operations', 'read_finance'], items: labelItems, codes });
  try {
    const r = await handler(post({ kind: 'labels' }));
    assertEquals(r.status, 200);
    assertEquals(await r.json(), { ok: true, to: 'finance', kind: 'labels', rows: 2, pages: 1, message_id: 77 });
    const [tg] = telegram(w.calls);
    assertEquals(tg.form!.get('chat_id'), '-100FIN');
    assertEquals(tg.form!.get('caption'), 'Item labels, 2 items. Sent from the staff app by Marifel.');
    assertEquals((tg.form!.get('document') as File).name, 'cascade-labels-2026-10-15.pdf');
    const t = drawnText(await bytesOf(tg));
    assert(t.indexOf('Alarm clock') < t.indexOf('Bath towel'), 'name order');
    assertFalse(t.includes('No code item'));
    for (const c of w.calls.filter((x) => x.url.includes('/rest/v1/'))) assertFalse(/unit_cost|estimated_cost/.test(decodeURIComponent(c.url)), c.url);
  } finally { w.done(); }
  const w2 = world({ allowed: ['manage_inventory', 'read_operations'], items: labelItems, codes });
  try {
    const r = await handler(post({ kind: 'labels', to: 'ops' }));
    assertEquals(r.status, 200);
    assertEquals(telegram(w2.calls)[0].form!.get('chat_id'), '-100OPS');
  } finally { w2.done(); }
} });

Deno.test({ name: 'labels: item_ids narrows the sheet; a bad id list -> 400; nothing coded -> 422', ...OPT, fn: async () => {
  const w = world({ allowed: ['manage_inventory', 'read_operations', 'read_finance'], items: labelItems, codes });
  try {
    const r = await handler(post({ kind: 'labels', item_ids: [U2, U3] }));
    assertEquals((await r.json()).rows, 1);
    assertEquals((await handler(post({ kind: 'labels', item_ids: ['x'] }))).status, 400);
    assertEquals((await handler(post({ kind: 'labels', item_ids: 'all' }))).status, 400);
    assertEquals((await handler(post({ kind: 'labels', item_ids: [U3] }))).status, 422);
  } finally { w.done(); }
} });

const SUP = [{ id: 'sup-sm', name: 'SM Supermarket' }];
const buys = [
  { item_id: 's', unit_cost: 125, purchased_at: '2026-10-01', supplier_id: 'sup-sm' },
  { item_id: 's', unit_cost: 100, purchased_at: '2026-09-01', supplier_id: 'sup-sm' },
  { item_id: 's', unit_cost: 100, purchased_at: '2026-08-01', supplier_id: 'sup-sm' },
];

Deno.test({ name: 'Finance order PDF: Where shows the supplier and UP 25% follows the unit cost', ...OPT, fn: async () => {
  const w = world({ allowed: ['read_operations', 'read_finance'], suppliers: SUP, purchases: buys });
  try {
    assertEquals((await handler(post({ kind: 'order', to: 'finance' }))).status, 200);
    const t = drawnText(await bytesOf(telegram(w.calls)[0]));
    assertStringIncludes(t, 'Where');
    assertStringIncludes(t, 'Supermarket');
    assertStringIncludes(t, 'UP 25%');
  } finally { w.done(); }
} });

Deno.test({ name: 'OPS order PDF for items that have a supplier: no supplier name, no supplier read at all', ...OPT, fn: async () => {
  const w = world({ suppliers: SUP, purchases: buys });
  try {
    assertEquals((await handler(post({ kind: 'order', to: 'ops' }))).status, 200);
    assertFalse(w.calls.some((c) => /inventory_suppliers|inventory_item_suppliers|inventory_purchases/.test(c.url)));
    const t = drawnText(await bytesOf(telegram(w.calls)[0]));
    assertFalse(/SM Supermarket|Where|UP 25/.test(t));
  } finally { w.done(); }
} });

Deno.test({ name: 'before the SQL release: supplier tables missing -> Finance PDF still sends, Where blank, price marks survive', ...OPT, fn: async () => {
  const w = world({ allowed: ['read_operations', 'read_finance'], noSuppliers: true, purchases: buys });
  try {
    assertEquals((await handler(post({ kind: 'low', to: 'finance' }))).status, 200);
    const t = drawnText(await bytesOf(telegram(w.calls)[0]));
    assertStringIncludes(t, 'Where');
    assertFalse(t.includes('SM Supermarket'));
  } finally { w.done(); }
} });
