// Handler tests (frozen clock): globalThis.fetch is stubbed, so the mock sees the exact Jev body, the RPC arguments and the Telegram chat.
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'jsr:@std/assert@1';
import { withObservability } from '../_shared/observability.ts';
import { makeHandler } from './handler.ts';

const OPT = { sanitizeOps: false, sanitizeResources: false };
const URL_ = 'https://proj.test';
const NOW = new Date('2026-10-15T04:30:00Z'); // 12:30 pm in Manila
const ENV = {
  SUPABASE_URL: URL_, SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key', CASCADE_OPENROUTER_BOT_KEY: 'or-key',
  TELEGRAM_BOT_TOKEN: 'tok', TELEGRAM_CHAT_ID: '-100OPS', TELEGRAM_FINANCE_CHAT_ID: '-100FIN',
};
const U = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;

interface Item { id: string; name: string; category: string }
const ITEMS: Item[] = [
  { id: U(1), name: 'Broom', category: 'Cleaning Supplies' },
  { id: U(2), name: 'Dustpan', category: 'Cleaning Supplies' },
  { id: U(3), name: 'Shampoo', category: 'Toiletries' },
  { id: U(4), name: 'Towel rack', category: 'Bathroom & Utility' },
  { id: U(10), name: 'Mop', category: 'Uncategorised' },
  { id: U(11), name: 'Conditioner', category: 'Uncategorised' },
];

interface Call { method: string; url: string; json?: Record<string, any>; headers: Headers }
const json = (data: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json', ...headers } });

interface World { items?: Item[]; allowed?: string[]; usageToday?: number; jev?: (name: string) => { choice: string; confidence: number } | 'hang' | 'http500'; rpcMissing?: boolean; noKey?: boolean; noFinChat?: boolean }
function world(o: World = {}) {
  const calls: Call[] = [];
  const items = (o.items ?? ITEMS).map((i) => ({ ...i }));
  const env: Record<string, string | undefined> = { ...ENV, CASCADE_OPENROUTER_BOT_KEY: o.noKey ? undefined : ENV.CASCADE_OPENROUTER_BOT_KEY, TELEGRAM_FINANCE_CHAT_ID: o.noFinChat ? undefined : ENV.TELEGRAM_FINANCE_CHAT_ID };
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(env)) { saved.set(k, Deno.env.get(k)); if (v) Deno.env.set(k, v); else Deno.env.delete(k); }
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    const call: Call = { method: req.method, url: decodeURIComponent(req.url), headers: req.headers };
    if (req.method === 'POST') call.json = await req.clone().json().catch(() => undefined);
    calls.push(call);
    const url = call.url;
    if (url.startsWith('https://api.telegram.org/')) return json({ ok: true, result: { message_id: 5 } });
    if (url.startsWith('https://openrouter.ai/')) {
      const name = String(call.json?.state?.item_name);
      const a = (o.jev ?? (() => ({ choice: 'Cleaning Supplies', confidence: 0.9 })))(name);
      if (a === 'hang') return await new Promise<Response>((_, rej) => init?.signal?.addEventListener('abort', () => rej(new DOMException('timeout', 'TimeoutError'))));
      if (a === 'http500') return json({}, 500);
      return json({ answers: { category: a } });
    }
    if (url.includes('/auth/v1/user')) return json({ id: '3f1c2a52-6b7d-4e0e-9c11-0a5d3f6a7b21', email: 'a@staff.cascade.invalid', app_metadata: {}, user_metadata: {}, aud: 'authenticated' });
    if (url.includes('/rpc/current_staff_authorized')) return json((o.allowed ?? ['manage_inventory']).includes(String(call.json?.p_action)));
    if (url.includes('/rest/v1/llm_usage')) {
      if (req.method === 'POST') return new Response(null, { status: 201 });
      const n = o.usageToday ?? 0;
      return new Response(null, { status: 200, headers: { 'content-range': n ? `0-0/${n}` : '*/0' } });
    }
    if (url.includes('/rest/v1/inventory_items')) return json(items);
    if (url.includes('/rpc/s_inventory_item_category_auto_v1')) {
      if (o.rpcMissing) return json({ code: 'PGRST202', message: 'Could not find the function' }, 404);
      const it = items.find((i) => i.id === call.json?.p_item_id);
      if (!it || it.category !== 'Uncategorised') return json({ ok: false, reason: 'not_uncategorised' });
      const before = it.category; it.category = String(call.json?.p_category);
      return json({ ok: true, item_id: it.id, before, after: it.category });
    }
    return json({ error: 'unexpected ' + url }, 500);
  }) as typeof fetch;
  return {
    calls, items,
    jev: () => calls.filter((c) => c.url.startsWith('https://openrouter.ai/')),
    rpc: () => calls.filter((c) => c.url.includes('/rpc/s_inventory_item_category_auto_v1')),
    tg: () => calls.filter((c) => c.url.includes('api.telegram.org')),
    done() { globalThis.fetch = realFetch; for (const [k, v] of saved) { if (v === undefined) Deno.env.delete(k); else Deno.env.set(k, v); } },
  };
}

const post = (body: unknown, headers: Record<string, string> = { authorization: 'Bearer staff.jwt', apikey: 'anon', 'content-type': 'application/json' }) =>
  new Request(`${URL_}/functions/v1/inventory-categorise`, { method: 'POST', headers, body: JSON.stringify(body) });
const handler = makeHandler({ now: () => NOW, timeoutMs: 50 });
const body = async (r: Response) => await r.json() as Record<string, any>;

Deno.test({ name: 'preflight: 204 and the four allowed headers, through the observability wrapper too', ...OPT, fn: async () => {
  const w = world();
  try {
    const wrapped = withObservability({ functionName: 'inventory-categorise', route: 'ops' }, handler);
    for (const h of [handler, wrapped]) {
      const res = await h(new Request(`${URL_}/functions/v1/inventory-categorise`, { method: 'OPTIONS', headers: { origin: 'https://staff.example', 'access-control-request-method': 'POST' } }));
      assertEquals(res.status, 204);
      const allowed = (res.headers.get('access-control-allow-headers') ?? '').toLowerCase().split(',').map((x) => x.trim());
      for (const need of ['authorization', 'apikey', 'x-client-info', 'content-type']) assert(allowed.includes(need), `missing ${need}: ${allowed}`);
      assertStringIncludes(res.headers.get('access-control-allow-methods') ?? '', 'POST');
    }
    assertEquals(w.calls.length, 0, 'a preflight touches nothing');
  } finally { w.done(); }
} });

Deno.test({ name: 'cleaner JWT (no manage_inventory) -> 403 and nothing is read, asked or written', ...OPT, fn: async () => {
  const w = world({ allowed: ['read_operations'] });
  try {
    const r = await handler(post({ item_id: U(10) }));
    assertEquals(r.status, 403);
    assertEquals(w.jev().length + w.rpc().length + w.tg().length, 0);
    assertFalse(w.calls.some((c) => c.url.includes('/rest/v1/')));
  } finally { w.done(); }
} });

Deno.test({ name: 'no bearer -> 401', ...OPT, fn: async () => {
  const w = world();
  try { assertEquals((await handler(post({ item_id: U(10) }, { 'content-type': 'application/json' }))).status, 401); } finally { w.done(); }
} });

Deno.test({ name: 'bad body -> 400 (neither item_id nor all:true; item_id not a uuid)', ...OPT, fn: async () => {
  const w = world();
  try {
    assertEquals((await handler(post({}))).status, 400);
    assertEquals((await handler(post({ item_id: 'mop' }))).status, 400);
    assertEquals((await handler(post({ all: 'yes' }))).status, 400);
    assertEquals(w.jev().length, 0);
  } finally { w.done(); }
} });

Deno.test({ name: 'criteria: every current category (sorted), up to 5 item names each, Uncategorised never a choice; state as specified', ...OPT, fn: async () => {
  const many: Item[] = [
    ...['A1', 'A2', 'A3', 'A4', 'A5', 'A6', 'A7'].map((n, i) => ({ id: U(20 + i), name: n, category: 'Kitchen & Dining' })),
    { id: U(1), name: 'Broom', category: 'Cleaning Supplies' },
    { id: U(10), name: 'Mop', category: 'Uncategorised' },
  ];
  const w = world({ items: many });
  try {
    const r = await handler(post({ item_id: U(10) }));
    assertEquals(r.status, 200);
    const sent = w.jev();
    assertEquals(sent.length, 1);
    const j = sent[0].json!;
    assertEquals(j.model, 'typesafe/jev-1.13');
    assertEquals(sent[0].headers.get('authorization'), 'Bearer or-key');
    assertEquals(j.state, { business: 'Cascade Hideaway, a one-unit holiday home', item_name: 'Mop' });
    assertEquals(j.questions.category.type, 'choice');
    assertEquals(j.questions.category.instructions, 'Which storage category fits this household item best?');
    assertEquals(Object.keys(j.questions.category.criteria), ['Cleaning Supplies', 'Kitchen & Dining']);
    assertEquals(j.questions.category.criteria['Kitchen & Dining'], 'A1, A2, A3, A4, A5');
    assertEquals(j.questions.category.criteria['Cleaning Supplies'], 'Broom');
  } finally { w.done(); }
} });

Deno.test({ name: 'confidence 0.59 -> no write; 0.6 -> write with the right RPC arguments', ...OPT, fn: async () => {
  let w = world({ jev: () => ({ choice: 'Cleaning Supplies', confidence: 0.59 }) });
  try {
    const b = await body(await handler(post({ item_id: U(10) })));
    assertEquals(b, { ok: true, results: [], remaining: 0 });
    assertEquals(w.rpc().length, 0);
    assertEquals(w.tg().length, 0);
  } finally { w.done(); }
  w = world({ jev: () => ({ choice: 'Cleaning Supplies', confidence: 0.6 }) });
  try {
    const b = await body(await handler(post({ item_id: U(10) })));
    assertEquals(b.results, [{ item_id: U(10), name: 'Mop', before: 'Uncategorised', after: 'Cleaning Supplies', confidence: 0.6 }]);
    assertEquals(w.rpc().length, 1);
    assertEquals(w.rpc()[0].json, { p_item_id: U(10), p_category: 'Cleaning Supplies', p_confidence: 0.6 });
    assertEquals(w.rpc()[0].headers.get('authorization'), 'Bearer service-key');
  } finally { w.done(); }
} });

Deno.test({ name: 'an item that is not Uncategorised is untouched: no Jev call, no write, no notice', ...OPT, fn: async () => {
  const w = world();
  try {
    const b = await body(await handler(post({ item_id: U(1) })));
    assertEquals(b.results, []);
    assertEquals(w.jev().length + w.rpc().length + w.tg().length, 0);
    assertEquals(w.items.find((i) => i.id === U(1))!.category, 'Cleaning Supplies');
  } finally { w.done(); }
} });

Deno.test({ name: 'a choice outside the category list is never written', ...OPT, fn: async () => {
  const w = world({ jev: () => ({ choice: 'Garage', confidence: 0.99 }) });
  try {
    const b = await body(await handler(post({ item_id: U(10) })));
    assertEquals(b.results, []);
    assertEquals(w.rpc().length, 0);
  } finally { w.done(); }
} });

Deno.test({ name: 'Jev timeout / http error / missing key -> 200 results [] and no write, no notice', ...OPT, fn: async () => {
  for (const o of [{ jev: () => 'hang' as const }, { jev: () => 'http500' as const }, { noKey: true }]) {
    const w = world(o);
    try {
      const r = await handler(post({ item_id: U(10) }));
      assertEquals(r.status, 200);
      assertEquals((await body(r)).results, []);
      assertEquals(w.rpc().length + w.tg().length, 0);
    } finally { w.done(); }
  }
} });

Deno.test({ name: 'Finance notice: only when something changed, to the Finance chat never OPS, names only, no price words', ...OPT, fn: async () => {
  let w = world({ jev: (n) => (n === 'Mop' ? { choice: 'Cleaning Supplies', confidence: 0.9 } : { choice: 'Toiletries', confidence: 0.4 }) });
  try {
    const b = await body(await handler(post({ all: true })));
    assertEquals(b.results.length, 1);
    const tg = w.tg();
    assertEquals(tg.length, 1);
    assertStringIncludes(tg[0].url, '/bottok/sendMessage');
    assertEquals(tg[0].json!.chat_id, '-100FIN');
    const text = String(tg[0].json!.text);
    assertEquals(text, 'Cassy sorted 1 new item into categories (Mop → Cleaning Supplies). Change them in Inventory > Tidy categories.');
    assertFalse(/price|cost|₱|php|peso|\$|\d{3,}|!/i.test(text), text);
    assertFalse(JSON.stringify(tg).includes('-100OPS'));
  } finally { w.done(); }
  w = world({ jev: () => ({ choice: 'Cleaning Supplies', confidence: 0.1 }) });
  try { await handler(post({ all: true })); assertEquals(w.tg().length, 0, 'nothing changed -> no message'); } finally { w.done(); }
  w = world({ noFinChat: true });
  try {
    const r = await handler(post({ all: true }));
    assertEquals(r.status, 200);
    assertEquals(w.tg().length, 0, 'no Finance chat configured -> no message, and never a fallback to OPS');
  } finally { w.done(); }
} });

Deno.test({ name: 'all:true sorts at most 50 items per call and reports how many remain', ...OPT, fn: async () => {
  const many: Item[] = [{ id: U(1), name: 'Broom', category: 'Cleaning Supplies' },
    ...Array.from({ length: 53 }, (_, i) => ({ id: U(100 + i), name: `Thing ${i}`, category: 'Uncategorised' }))];
  const w = world({ items: many });
  try {
    const b = await body(await handler(post({ all: true })));
    assertEquals(w.jev().length, 50);
    assertEquals(b.results.length, 50);
    assertEquals(b.remaining, 3);
  } finally { w.done(); }
} });

Deno.test({ name: 'budget: 500 usage rows today is fine, 501 -> 429 budget before any Jev call; the window is the Manila day', ...OPT, fn: async () => {
  let w = world({ usageToday: 501 });
  try {
    const r = await handler(post({ item_id: U(10) }));
    assertEquals(r.status, 429);
    assertEquals((await body(r)).error, 'budget');
    assertEquals(w.jev().length + w.rpc().length, 0);
    const q = w.calls.find((c) => c.url.includes('/rest/v1/llm_usage') && c.method !== 'POST')!;
    assertStringIncludes(q.url, 'title=eq.inventory_categorise');
    assertStringIncludes(q.url, 'at=gte.2026-10-14T16:00:00.000Z');
  } finally { w.done(); }
  w = world({ usageToday: 500 });
  try { assertEquals((await handler(post({ item_id: U(10) }))).status, 200); } finally { w.done(); }
} });

Deno.test({ name: 'each Jev call is logged as one llm_usage row titled inventory_categorise', ...OPT, fn: async () => {
  const w = world();
  try {
    await handler(post({ all: true }));
    await new Promise((r) => setTimeout(r, 20));
    const rows = w.calls.filter((c) => c.url.includes('/rest/v1/llm_usage') && c.method === 'POST').map((c) => c.json!);
    assertEquals(rows.length, 2);
    for (const row of rows) { assertEquals(row.title, 'inventory_categorise'); assertEquals(row.provider, 'openrouter'); assertEquals(row.model, 'typesafe/jev-1.13'); assertEquals(row.ok, true); }
  } finally { w.done(); }
} });

Deno.test({ name: 'RPC missing (PGRST202) -> 200 results [] and no notice, never 500', ...OPT, fn: async () => {
  const w = world({ rpcMissing: true });
  try {
    const r = await handler(post({ all: true }));
    assertEquals(r.status, 200);
    assertEquals((await body(r)).results, []);
    assertEquals(w.tg().length, 0);
  } finally { w.done(); }
} });

Deno.test({ name: 'the RPC refusing (not_uncategorised, a race) leaves no result and no notice', ...OPT, fn: async () => {
  const w = world();
  try {
    // The item moves between our read and our write: the RPC is the guard, the function trusts it.
    const real = globalThis.fetch;
    globalThis.fetch = ((i: RequestInfo | URL, init?: RequestInit) => String(i instanceof Request ? i.url : i).includes('/rpc/s_inventory_item_category_auto_v1')
      ? Promise.resolve(json({ ok: false, reason: 'not_uncategorised' })) : real(i, init)) as typeof fetch;
    const b = await body(await handler(post({ all: true })));
    assertEquals(b.results, []);
    assertEquals(w.tg().length, 0);
  } finally { w.done(); }
} });
