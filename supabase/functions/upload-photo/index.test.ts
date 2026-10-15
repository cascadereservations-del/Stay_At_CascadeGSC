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

interface WorldOpts { allowed?: string[]; item?: Record<string, unknown> | null; missing?: string[]; uploadError?: boolean }

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
