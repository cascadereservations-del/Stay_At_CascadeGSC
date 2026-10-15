// Handler tests for upload-photo. globalThis.fetch is stubbed (supabase-js, auth and storage all go through it), Date.now and
// crypto.randomUUID are frozen, and Deno.serve is captured so index.ts is exercised as deployed.
// deno test --node-modules-dir=none --allow-env --allow-read upload-photo/index.test.ts
import { assert, assertEquals, assertFalse } from 'jsr:@std/assert@1';

const OPT = { sanitizeOps: false, sanitizeResources: false };
const URL_ = 'https://proj.test';
const PROPERTY = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const SUBMISSION = '11111111-1111-4111-8111-111111111111';
const ITEM = '22222222-2222-4222-8222-222222222222';
const OTHER_ITEM = '33333333-3333-4333-8333-333333333333';
const USER = '3f1c2a52-6b7d-4e0e-9c11-0a5d3f6a7b21';
const OBJ_UUID = '55555555-5555-4555-8555-555555555555';
const ENV = { SUPABASE_URL: URL_, SUPABASE_ANON_KEY: 'anon-key', SUPABASE_SERVICE_ROLE_KEY: 'service-key' };

interface Call { method: string; url: string; headers: Record<string, string>; json?: unknown; bytes?: number }
const json = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });
const bearerKind = (v: string | null) => (v === 'Bearer service-key' ? 'service' : v === 'Bearer anon-key' ? 'anon' : v === 'Bearer staff.jwt' ? 'staff' : String(v));

interface WorldOpts { owned?: string[]; allowed?: string[]; item?: Record<string, unknown> | null; missing?: string[]; uploadError?: boolean }

async function world(o: WorldOpts = {}) {
  const calls: Call[] = [];
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(ENV)) { saved.set(k, Deno.env.get(k)); Deno.env.set(k, v); }
  const realFetch = globalThis.fetch, realServe = Deno.serve, realNow = Date.now;
  const realUuid = crypto.randomUUID.bind(crypto);
  let handler!: (r: Request) => Promise<Response>;
  // deno-lint-ignore no-explicit-any
  (Deno as any).serve = (h: (r: Request) => Promise<Response>) => { handler = h; return {}; };
  Date.now = () => Date.parse('2026-10-15T00:00:00Z');
  crypto.randomUUID = (() => OBJ_UUID) as typeof crypto.randomUUID;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    const url = req.url.replace(URL_, '');
    const headers: Record<string, string> = {};
    for (const k of ['content-type', 'x-upsert', 'cache-control']) { const v = req.headers.get(k); if (v) headers[k] = v; }
    headers.auth = bearerKind(req.headers.get('authorization'));
    const call: Call = { method: req.method, url, headers };
    if (req.method !== 'GET') {
      const buf = new Uint8Array(await req.clone().arrayBuffer());
      if ((req.headers.get('content-type') ?? '').includes('json')) call.json = JSON.parse(new TextDecoder().decode(buf));
      else call.bytes = buf.byteLength;
    }
    calls.push(call);
    if (url.startsWith('/auth/v1/user')) return json({ id: USER, aud: 'authenticated', app_metadata: {}, user_metadata: {} });
    if (url.includes('/rpc/current_staff_authorized')) return json((o.allowed ?? ['submit_cleaning', 'read_operations']).includes(String((call.json as Record<string, unknown>)?.p_action)));
    if (url.startsWith('/storage/v1/object/sign/') && req.method === 'POST') {
      const body = call.json as { paths?: string[] } | undefined;
      if (body?.paths) {
        return json(body.paths.map((p) => (o.missing ?? []).includes(p)
          ? { error: 'Object not found', path: p, signedURL: null }
          : { error: null, path: p, signedURL: `/object/sign/inventory-photos/${p}?token=t` }));
      }
      return json({ signedURL: `${url.replace('/storage/v1', '')}?token=t` });
    }
    if (url.startsWith('/storage/v1/object/') && req.method === 'POST') {
      if (o.uploadError) return json({ message: 'boom', statusCode: '500', error: 'x' }, 500);
      return json({ Key: url.replace('/storage/v1/object/', ''), Id: 'obj' });
    }
    if (url.startsWith('/rest/v1/staff_upload_hashes')) return new Response(null, { status: 201 });
    if (url.startsWith('/rest/v1/inventory_items') && url.includes('id=in.')) {
      // sign ownership lookup: only the ids that belong to the property named in the query come back
      const asked = decodeURIComponent(url.split('id=in.')[1]).replace(/[()"&].*$/, '').split(',');
      return json((o.owned ?? [ITEM]).filter((id) => asked.includes(id) && url.includes(`property_id=eq.${PROPERTY}`)).map((id) => ({ id })));
    }
    if (url.startsWith('/rest/v1/inventory_items')) {
      const item = o.item === undefined ? { id: ITEM, property_id: PROPERTY, is_active: true } : o.item;
      return json(item ? [item] : []);
    }
    return json({ error: 'unexpected ' + url }, 500);
  }) as typeof fetch;
  await import(`./index.ts?w=${Math.random()}`);
  return {
    calls,
    handler,
    done() {
      globalThis.fetch = realFetch; (Deno as { serve: unknown }).serve = realServe; Date.now = realNow; crypto.randomUUID = realUuid;
      for (const [k, v] of saved) { if (v === undefined) Deno.env.delete(k); else Deno.env.set(k, v); }
    },
  };
}

const AUTH = { authorization: 'Bearer staff.jwt', apikey: 'anon', 'content-type': 'application/json' };
const post = (body: unknown, headers: Record<string, string> = AUTH) =>
  new Request(`${URL_}/functions/v1/upload-photo`, { method: 'POST', headers, body: JSON.stringify(body) });
const b64 = (n: number) => btoa('a'.repeat(n));
const cleaningBody = (extra: Record<string, unknown> = {}) =>
  ({ fileData: b64(1000), fileName: 'PreClean 1.JPG', mimeType: 'image/jpeg', propertyId: PROPERTY, submissionId: SUBMISSION, ...extra });
const invBody = (extra: Record<string, unknown> = {}) =>
  ({ purpose: 'inventory', fileData: b64(1000), fileName: 'x.webp', mimeType: 'image/webp', propertyId: PROPERTY, itemId: ITEM, ...extra });

const CLEAN_PATH = `${PROPERTY}/${USER}/${SUBMISSION}/${OBJ_UUID}-preclean-1.jpg`;
const SHA = '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3'; // sha256 of 1000 x 'a'

Deno.test({ name: 'cleaning request: the exact storage + RPC + hash calls (snapshot, must pass before and after the inventory change)', ...OPT, fn: async () => {
  const w = await world();
  try {
    const res = await w.handler(post(cleaningBody()));
    assertEquals(res.status, 200);
    assertEquals(await res.json(), { ok: true, path: CLEAN_PATH, signedUrl: `${URL_}/storage/v1/object/sign/cleaning-photos/${CLEAN_PATH}?token=t`, sha256: SHA });
    assertEquals(w.calls, [
      { method: 'GET', url: '/auth/v1/user', headers: { auth: 'staff' } },
      { method: 'POST', url: '/rest/v1/rpc/current_staff_authorized', headers: { 'content-type': 'application/json', auth: 'staff' }, json: { p_action: 'submit_cleaning', p_property_id: PROPERTY } },
      { method: 'POST', url: `/storage/v1/object/cleaning-photos/${CLEAN_PATH}`, headers: { 'content-type': 'image/jpeg', 'x-upsert': 'false', 'cache-control': 'max-age=3600', auth: 'service' }, bytes: 1000 },
      { method: 'POST', url: `/storage/v1/object/sign/cleaning-photos/${CLEAN_PATH}`, headers: { 'content-type': 'application/json', auth: 'service' }, json: { expiresIn: 900 } },
      { method: 'POST', url: '/rest/v1/staff_upload_hashes', headers: { 'content-type': 'application/json', auth: 'service' }, json: { path: CLEAN_PATH, sha256: SHA, uploaded_by: USER } },
    ]);
  } finally { w.done(); }
} });

const INV_PATH = `items/${ITEM}/${OBJ_UUID}.webp`;
const noStorage = (calls: Call[]) => assertFalse(calls.some((c) => c.url.startsWith('/storage/')), 'no storage call');
const rpcActions = (calls: Call[]) => calls.filter((c) => c.url.includes('current_staff_authorized')).map((c) => (c.json as Record<string, unknown>).p_action);

Deno.test({ name: 'preflight: 204, the four required headers plus the inventory ones, no calls', ...OPT, fn: async () => {
  const w = await world();
  try {
    const res = await w.handler(new Request(`${URL_}/functions/v1/upload-photo`, { method: 'OPTIONS' }));
    assertEquals(res.status, 204);
    const allowed = (res.headers.get('access-control-allow-headers') ?? '').toLowerCase().split(',').map((x) => x.trim());
    for (const need of ['authorization', 'apikey', 'x-client-info', 'content-type', 'x-cascade-purpose', 'x-cascade-item-id']) assert(allowed.includes(need), `missing ${need}`);
    assertEquals(w.calls.length, 0);
  } finally { w.done(); }
} });

Deno.test({ name: 'inventory upload: read_operations gate, item check, private bucket path, cache and upsert, signed URL, no photo_path write', ...OPT, fn: async () => {
  const w = await world({ allowed: ['read_operations'] }); // a cleaner-level role: no submit_cleaning, no manage_inventory
  try {
    const res = await w.handler(post(invBody()));
    assertEquals(res.status, 200);
    assertEquals(await res.json(), { ok: true, path: INV_PATH, signedUrl: `${URL_}/storage/v1/object/sign/inventory-photos/${INV_PATH}?token=t` });
    assertEquals(rpcActions(w.calls), ['read_operations']);
    const lookup = w.calls.find((c) => c.url.startsWith('/rest/v1/inventory_items'))!;
    assertEquals(lookup.headers.auth, 'service');
    for (const f of [`id=eq.${ITEM}`, `property_id=eq.${PROPERTY}`, 'is_active=eq.true']) assert(lookup.url.includes(f), f);
    const up = w.calls.find((c) => c.url === `/storage/v1/object/inventory-photos/${INV_PATH}`)!;
    assertEquals(up.headers, { 'content-type': 'image/webp', 'x-upsert': 'false', 'cache-control': 'max-age=31536000', auth: 'service' });
    assertEquals(up.bytes, 1000);
    const sign = w.calls.find((c) => c.url === `/storage/v1/object/sign/inventory-photos/${INV_PATH}`)!;
    assertEquals(sign.json, { expiresIn: 604800 });
    assertFalse(w.calls.some((c) => c.method === 'PATCH' || c.url.includes('staff_upload_hashes') || c.url.includes('cleaning-photos')), 'no photo_path write, no hash row, no cleaning bucket');
  } finally { w.done(); }
} });

Deno.test({ name: 'inventory upload: jpeg gets .jpg; raw image body with x-cascade headers works too', ...OPT, fn: async () => {
  const w = await world();
  try {
    let res = await w.handler(post(invBody({ mimeType: 'image/jpeg', fileName: 'whatever.png' })));
    assertEquals((await res.json()).path, `items/${ITEM}/${OBJ_UUID}.jpg`);
    res = await w.handler(new Request(`${URL_}/functions/v1/upload-photo`, {
      method: 'POST',
      headers: { authorization: 'Bearer staff.jwt', 'content-type': 'image/webp', 'x-cascade-purpose': 'inventory', 'x-cascade-item-id': ITEM, 'x-cascade-property-id': PROPERTY },
      body: new Uint8Array(500),
    }));
    assertEquals(res.status, 200);
    assertEquals((await res.json()).path, INV_PATH);
  } finally { w.done(); }
} });

Deno.test({ name: 'inventory upload refusals: png 415, over 1 MB 413, bad ids 400, no access 403, unknown/inactive/other-property item 404, bad purpose 400', ...OPT, fn: async () => {
  let w = await world();
  try {
    assertEquals((await w.handler(post(invBody({ mimeType: 'image/png' })))).status, 415);
    const big = await w.handler(post(invBody({ fileData: b64(1024 * 1024 + 1) })));
    assertEquals(big.status, 413);
    assertEquals((await big.json()).error, 'invalid_image_size');
    assertEquals((await w.handler(post(invBody({ fileData: b64(1024 * 1024) })))).status, 200); // exactly 1 MB is fine
    assertEquals((await w.handler(post(invBody({ itemId: 'nope' })))).status, 400);
    assertEquals((await w.handler(post(invBody({ itemId: undefined })))).status, 400);
    assertEquals((await w.handler(post(invBody({ purpose: 'weddings' })))).status, 400);
  } finally { w.done(); }
  w = await world({ allowed: ['submit_cleaning'] });
  try {
    const res = await w.handler(post(invBody()));
    assertEquals(res.status, 403);
    noStorage(w.calls);
  } finally { w.done(); }
  w = await world({ item: null });
  try {
    const res = await w.handler(post(invBody({ itemId: OTHER_ITEM })));
    assertEquals(res.status, 404);
    assertEquals((await res.json()).error, 'item_not_found');
    noStorage(w.calls);
  } finally { w.done(); }
} });

Deno.test({ name: 'cleaning stays gated by submit_cleaning: read_operations alone cannot upload a cleaning photo', ...OPT, fn: async () => {
  const w = await world({ allowed: ['read_operations'] });
  try {
    assertEquals((await w.handler(post(cleaningBody()))).status, 403);
    assertEquals((await w.handler(post(cleaningBody({ purpose: 'cleaning' })))).status, 403);
    noStorage(w.calls);
  } finally { w.done(); }
} });

Deno.test({ name: 'sign: read_operations gate, one createSignedUrls call for 7 days, missing objects left out', ...OPT, fn: async () => {
  const ok1 = `items/${ITEM}/${OBJ_UUID}.webp`, gone = `items/${OTHER_ITEM}/${OBJ_UUID}.jpg`;
  const w = await world({ allowed: ['read_operations'], missing: [gone] });
  try {
    const res = await w.handler(post({ purpose: 'inventory', action: 'sign', propertyId: PROPERTY, paths: [ok1, gone] }));
    assertEquals(res.status, 200);
    assertEquals(await res.json(), { ok: true, urls: { [ok1]: `${URL_}/storage/v1/object/sign/inventory-photos/${ok1}?token=t` } });
    assertEquals(rpcActions(w.calls), ['read_operations']);
    const own = w.calls.filter((c) => c.url.startsWith('/rest/v1/inventory_items'));
    assertEquals(own.length, 1);
    assertEquals(own[0].headers.auth, 'service');
    assert(own[0].url.includes(`property_id=eq.${PROPERTY}`) && !own[0].url.includes('is_active'), own[0].url);
    const signs = w.calls.filter((c) => c.url === '/storage/v1/object/sign/inventory-photos');
    assertEquals(signs.length, 1);
    assertEquals(signs[0].json, { expiresIn: 604800, paths: [ok1] }); // OTHER_ITEM is not this property's item, so it is left out like a missing object
    assertEquals(signs[0].headers.auth, 'service');
  } finally { w.done(); }
} });

Deno.test({ name: 'sign refusals: bad/empty/too many paths 400 invalid_path before any call, no access 403', ...OPT, fn: async () => {
  const good = `items/${ITEM}/${OBJ_UUID}.jpg`;
  let w = await world();
  try {
    const bad = [[], 'x', [good, 'items/../x.jpg'], [`items/${ITEM}/${OBJ_UUID}.png`], [`cleaning/${ITEM}/${OBJ_UUID}.jpg`], [`items/${ITEM}/${OBJ_UUID}.jpg/`], [42],
      Array(201).fill(good), [`${PROPERTY}/${USER}/${SUBMISSION}/${OBJ_UUID}-a.jpg`]];
    for (const paths of bad) {
      const res = await w.handler(post({ purpose: 'inventory', action: 'sign', propertyId: PROPERTY, paths }));
      assertEquals(res.status, 400);
      assertEquals((await res.json()).error, 'invalid_path');
    }
    assertEquals(w.calls.length, 0, 'validation happens before auth or storage');
    assertEquals((await w.handler(post({ purpose: 'inventory', action: 'sign', propertyId: PROPERTY, paths: Array(200).fill(good) }))).status, 200);
  } finally { w.done(); }
  w = await world({ allowed: ['submit_cleaning'] });
  try {
    const res = await w.handler(post({ purpose: 'inventory', action: 'sign', propertyId: PROPERTY, paths: [good] }));
    assertEquals(res.status, 403);
    noStorage(w.calls);
  } finally { w.done(); }
} });

Deno.test({ name: 'sign is tied to the property: another property\'s item path is left out of urls and of the storage call', ...OPT, fn: async () => {
  const mine = `items/${ITEM}/${OBJ_UUID}.jpg`, theirs = `items/${OTHER_ITEM}/${OBJ_UUID}.jpg`;
  let w = await world({ owned: [ITEM] });
  try {
    const res = await w.handler(post({ purpose: 'inventory', action: 'sign', propertyId: PROPERTY, paths: [mine, theirs] }));
    assertEquals(res.status, 200);
    assertEquals(Object.keys((await res.json()).urls), [mine]);
    assertEquals(w.calls.find((c) => c.url === '/storage/v1/object/sign/inventory-photos')!.json, { expiresIn: 604800, paths: [mine] });
  } finally { w.done(); }
  w = await world({ owned: [] });
  try {
    const res = await w.handler(post({ purpose: 'inventory', action: 'sign', propertyId: PROPERTY, paths: [theirs] }));
    assertEquals(await res.json(), { ok: true, urls: {} });
    noStorage(w.calls);
  } finally { w.done(); }
} });

Deno.test({ name: 'upper-case itemId is stored under a lower-case path (R7 accepts lower case only); upper-case sign paths are refused', ...OPT, fn: async () => {
  const w = await world();
  try {
    const UPPER = 'ABCDEF01-2222-4222-8222-222222222222';
    const res = await w.handler(post(invBody({ itemId: UPPER })));
    assertEquals(res.status, 200);
    assertEquals((await res.json()).path, `items/${UPPER.toLowerCase()}/${OBJ_UUID}.webp`);
    const bad = await w.handler(post({ purpose: 'inventory', action: 'sign', propertyId: PROPERTY, paths: [`items/${UPPER}/${OBJ_UUID}.jpg`] }));
    assertEquals(bad.status, 400);
  } finally { w.done(); }
} });

Deno.test({ name: 'cleaning raw-body upload (pay receipts, payment proofs): the exact calls (snapshot, must pass before and after)', ...OPT, fn: async () => {
  const w = await world();
  try {
    const res = await w.handler(new Request(`${URL_}/functions/v1/upload-photo`, {
      method: 'POST',
      headers: { authorization: 'Bearer staff.jwt', apikey: 'anon', 'content-type': 'image/jpeg', 'x-cascade-file-name': 'PreClean 1.JPG', 'x-cascade-property-id': PROPERTY, 'x-cascade-submission-id': SUBMISSION },
      body: new TextEncoder().encode('a'.repeat(1000)),
    }));
    assertEquals(res.status, 200);
    assertEquals(await res.json(), { ok: true, path: CLEAN_PATH, signedUrl: `${URL_}/storage/v1/object/sign/cleaning-photos/${CLEAN_PATH}?token=t`, sha256: SHA });
    assertEquals(w.calls, [
      { method: 'GET', url: '/auth/v1/user', headers: { auth: 'staff' } },
      { method: 'POST', url: '/rest/v1/rpc/current_staff_authorized', headers: { 'content-type': 'application/json', auth: 'staff' }, json: { p_action: 'submit_cleaning', p_property_id: PROPERTY } },
      { method: 'POST', url: `/storage/v1/object/cleaning-photos/${CLEAN_PATH}`, headers: { 'content-type': 'image/jpeg', 'x-upsert': 'false', 'cache-control': 'max-age=3600', auth: 'service' }, bytes: 1000 },
      { method: 'POST', url: `/storage/v1/object/sign/cleaning-photos/${CLEAN_PATH}`, headers: { 'content-type': 'application/json', auth: 'service' }, json: { expiresIn: 900 } },
      { method: 'POST', url: '/rest/v1/staff_upload_hashes', headers: { 'content-type': 'application/json', auth: 'service' }, json: { path: CLEAN_PATH, sha256: SHA, uploaded_by: USER } },
    ]);
  } finally { w.done(); }
} });
