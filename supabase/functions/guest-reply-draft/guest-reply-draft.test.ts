import { assert, assertEquals } from 'jsr:@std/assert@1';
import { appHeader, handleGuestReplyDraft, MAX_IMAGE_BYTES, type Deps } from './logic.ts';
import type { Line, Platform, Transcript } from '../telegram-cassy/draft.ts';

type Call = { guestText: string; guestName: string | null; thread: { before?: Line[]; platform?: Platform } };
type Rec = { drafts: Call[]; transcribes: Array<[number, string]>; logs: string[]; errors: string[] };

const GUEST = 'Hi po, magkano ang 2 nights sa Oct 10? SECRET-GUEST-WORDS';
const OUT = ['header card', 'main reply', 'short reply'];

function fake(over: Partial<Deps> = {}): { deps: Deps; rec: Rec } {
  const rec: Rec = { drafts: [], transcribes: [], logs: [], errors: [] };
  let clock = 1000;
  const deps: Deps = {
    authenticate: () => Promise.resolve({ ok: true }),
    draft: (guestText, guestName, thread) => { rec.drafts.push({ guestText, guestName, thread }); return Promise.resolve(OUT); },
    transcribe: (bytes, mime) => {
      rec.transcribes.push([bytes.length, mime]);
      return Promise.resolve({ guest_name: 'Ana Reyes', platform: 'messenger', messages: [{ from: 'host', text: 'Hello!' }, { from: 'guest', text: GUEST }] } as Transcript);
    },
    now: () => (clock += 7),
    log: (l) => rec.logs.push(l),
    logError: (l) => rec.errors.push(l),
    ...over,
  };
  return { deps, rec };
}
const post = (body: unknown, headers: Record<string, string> = { authorization: 'Bearer staff.jwt' }) =>
  new Request('https://example.test/guest-reply-draft', { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) });
const img = (base64 = btoa('png-bytes'), mime = 'image/png') => ({ image: { base64, mime } });
const bigB64 = (bytes: number) => { const chunk = btoa('A'.repeat(3000)); return chunk.repeat(Math.floor(bytes / 3000)) + btoa('A'.repeat(bytes % 3000)); };

Deno.test('OPTIONS answers CORS and nothing else runs', async () => {
  const { deps, rec } = fake({ authenticate: () => { throw new Error('must not authenticate'); } });
  const res = await handleGuestReplyDraft(new Request('https://example.test/x', { method: 'OPTIONS' }), deps);
  assertEquals(res.status, 204);
  assertEquals(res.headers.get('Access-Control-Allow-Origin'), '*');
  assert(res.headers.get('Access-Control-Allow-Headers')!.includes('authorization'));
  assertEquals(rec.drafts.length, 0);
});

Deno.test('405 on GET, with CORS headers', async () => {
  const { deps } = fake();
  const res = await handleGuestReplyDraft(new Request('https://example.test/x', { method: 'GET' }), deps);
  assertEquals(res.status, 405);
  assertEquals((await res.json()).error, 'method_not_allowed');
  assertEquals(res.headers.get('Access-Control-Allow-Origin'), '*');
});

Deno.test('401: no bearer token, and an expired session, nothing drafted', async () => {
  const a = fake();
  const nb = await handleGuestReplyDraft(post({ text: GUEST }, {}), a.deps);
  assertEquals(nb.status, 401);
  assertEquals((await nb.json()).error, 'authentication_required');
  const b = fake({ authenticate: () => Promise.resolve({ ok: false, status: 401, error: 'invalid_or_expired_session' }) });
  const res = await handleGuestReplyDraft(post({ text: GUEST }), b.deps);
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error, 'invalid_or_expired_session');
  assertEquals(a.rec.drafts.length + b.rec.drafts.length, 0);
});

Deno.test('403: a signed-in cleaner (not owner or admin) is refused before the body is read, nothing drafted', async () => {
  const { deps, rec } = fake({ authenticate: () => Promise.resolve({ ok: false, status: 403, error: 'staff_access_denied' }) });
  const res = await handleGuestReplyDraft(post({ text: GUEST }), deps);
  assertEquals(res.status, 403);
  assertEquals((await res.json()).error, 'staff_access_denied');
  assertEquals(rec.drafts.length + rec.transcribes.length + rec.logs.length, 0);
});

Deno.test('an authenticated owner or admin passes, and the log carries the generic role only', async () => {
  const { deps, rec } = fake();
  assertEquals((await handleGuestReplyDraft(post({ text: GUEST }), deps)).status, 200);
  assertEquals(JSON.parse(rec.logs[0]).role, 'owner_or_admin');
});

Deno.test('400 bad_json: not JSON, and JSON that is not an object', async () => {
  for (const body of ['{nope', '[1]', 'null', '"x"']) {
    const { deps, rec } = fake();
    const res = await handleGuestReplyDraft(post(body), deps);
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error, 'bad_json');
    assertEquals(rec.drafts.length, 0);
  }
});

Deno.test('400 empty: neither, a blank text, a bare marker, and an empty-string text', async () => {
  for (const body of [{}, { text: '' }, { text: '   \n ' }, { text: 'airbnb:' }, { guest_name: 'Ana' }]) {
    const { deps, rec } = fake();
    const res = await handleGuestReplyDraft(post(body), deps);
    assertEquals(res.status, 400, JSON.stringify(body));
    assertEquals((await res.json()).error, 'empty');
    assertEquals(rec.drafts.length, 0);
  }
});

Deno.test('400 bad_json: a platform other than messenger or airbnb, and a guest_name that is not a string', async () => {
  for (const extra of [{ platform: 'whatsapp' }, { platform: 5 }, { guest_name: 42 }, { guest_name: { first: 'Ana' } }]) {
    const { deps, rec } = fake();
    const res = await handleGuestReplyDraft(post({ text: GUEST, ...extra }), deps);
    assertEquals(res.status, 400, JSON.stringify(extra));
    assertEquals((await res.json()).error, 'bad_json');
    assertEquals(rec.drafts.length, 0);
  }
});

Deno.test('400 both: text and image together', async () => {
  const { deps, rec } = fake();
  const res = await handleGuestReplyDraft(post({ text: GUEST, ...img() }), deps);
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'both');
  assertEquals(rec.drafts.length + rec.transcribes.length, 0);
});

Deno.test('400 too_long: 4001 chars refused, 4000 accepted', async () => {
  const a = fake();
  const res = await handleGuestReplyDraft(post({ text: 'a'.repeat(4001) }), a.deps);
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'too_long');
  assertEquals(a.rec.drafts.length, 0);
  const b = fake();
  assertEquals((await handleGuestReplyDraft(post({ text: ' ' + 'a'.repeat(4000) + ' ' }), b.deps)).status, 200); // trimmed first
});

Deno.test('400 bad_image: wrong mime, not base64, empty, wrong shape', async () => {
  for (const image of [{ base64: btoa('x'), mime: 'image/gif' }, { base64: '%%%not base64%%%', mime: 'image/png' }, { base64: '', mime: 'image/png' }, { base64: btoa('x') }, 'abc', { mime: 'image/png' }]) {
    const { deps, rec } = fake();
    const res = await handleGuestReplyDraft(post({ image }), deps);
    assertEquals(res.status, 400, JSON.stringify(image));
    assertEquals((await res.json()).error, 'bad_image');
    assertEquals(rec.transcribes.length, 0);
  }
});

Deno.test('413 image_too_large: 4_000_001 decoded bytes refused, 4_000_000 accepted', async () => {
  const over = fake();
  const res = await handleGuestReplyDraft(post(img(bigB64(MAX_IMAGE_BYTES + 1), 'image/jpeg')), over.deps);
  assertEquals(res.status, 413);
  assertEquals((await res.json()).error, 'image_too_large');
  assertEquals(over.rec.transcribes.length, 0);
  const wild = fake();
  assertEquals((await handleGuestReplyDraft(post(img('A'.repeat(9_000_000))), wild.deps)).status, 413); // refused before decoding
  const ok = fake();
  assertEquals((await handleGuestReplyDraft(post(img(bigB64(MAX_IMAGE_BYTES), 'image/jpeg')), ok.deps)).status, 200);
  assertEquals(ok.rec.transcribes[0], [MAX_IMAGE_BYTES, 'image/jpeg']);
});

Deno.test('image: a data: URL prefix and line breaks in the base64 are accepted and not counted', async () => {
  const { deps, rec } = fake();
  const b = btoa('abcdefgh');
  const res = await handleGuestReplyDraft(post(img(`data:image/png;base64,${b.slice(0, 4)}\n${b.slice(4)}`)), deps);
  assertEquals(res.status, 200);
  assertEquals(rec.transcribes, [[8, 'image/png']]);
  const big = fake(); // the prefix does not push a maximal image over the limit
  assertEquals((await handleGuestReplyDraft(post(img('data:image/jpeg;base64,' + bigB64(MAX_IMAGE_BYTES), 'image/jpeg')), big.deps)).status, 200);
});

Deno.test('header: Telegram-only lines and phrases are removed, the rest stays', async () => {
  const tg = ['Guest reply - Airbnb', '1 is a drafted reply.', 'Source unclear, so this is the Airbnb-safe draft. For a Messenger chat: "cassy reply messenger: ..." or a screenshot.', 'Nothing was sent. Long-press an option to copy it. Site: https://example.test'].join('\n');
  assertEquals(appHeader(tg), ['Guest reply - Airbnb', '1 is a drafted reply.', 'Nothing was sent. Site: https://example.test'].join('\n'));
  assertEquals(appHeader('Nothing was sent. Long-press an option to copy it.'), 'Nothing was sent.');
  const { deps } = fake({ draft: () => Promise.resolve([tg, 'main reply']) });
  const j = await (await handleGuestReplyDraft(post({ text: GUEST }), deps)).json();
  assert(!/long-press|cassy reply/i.test(j.header));
  assertEquals(j.replies, ['main reply']);
});

Deno.test('text: 200 with the contract shape, replies are everything after the header, drafting gets the pasted text and the label', async () => {
  const { deps, rec } = fake();
  const res = await handleGuestReplyDraft(post({ text: GUEST, guest_name: ' Ana Reyes ', platform: 'messenger' }), deps);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { ok: true, guest_name: 'Ana Reyes', platform: 'messenger', guest_text: GUEST, header: 'header card', replies: ['main reply', 'short reply'] });
  assertEquals(rec.drafts, [{ guestText: GUEST, guestName: 'Ana Reyes', thread: { platform: 'messenger' } }]);
  assertEquals(rec.transcribes.length, 0);
});

Deno.test('text: unlabelled text drafts the Airbnb-safe register; an "airbnb:" marker is stripped from guest_text; one reply is fine', async () => {
  const { deps, rec } = fake({ draft: () => Promise.resolve(['header', 'only reply']) });
  const res = await handleGuestReplyDraft(post({ text: 'airbnb: Is there parking?' }), deps);
  const j = await res.json();
  assertEquals(res.status, 200);
  assertEquals([j.platform, j.guest_text, j.replies, j.guest_name], ['airbnb', 'Is there parking?', ['only reply'], null]);
});

Deno.test('text: messenger label is honoured, but a text that says Airbnb stays Airbnb (same rule as telegram-cassy)', async () => {
  const a = fake();
  assertEquals((await (await handleGuestReplyDraft(post({ text: 'Hi, available po?', platform: 'messenger' }), a.deps)).json()).platform, 'messenger');
  const b = fake();
  assertEquals((await (await handleGuestReplyDraft(post({ text: 'I booked on airbnb, what time is check-in?', platform: 'messenger' }), b.deps)).json()).platform, 'airbnb');
  const c = fake();
  assertEquals((await (await handleGuestReplyDraft(post({ text: 'Hi, available po?' }), c.deps)).json()).platform, 'airbnb');
});

Deno.test('image: transcribe -> latest guest lines + thread before -> draft; the reader platform and name flow through', async () => {
  const { deps, rec } = fake();
  const res = await handleGuestReplyDraft(post(img(btoa('shot'), 'image/webp')), deps);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { ok: true, guest_name: 'Ana Reyes', platform: 'messenger', guest_text: GUEST, header: 'header card', replies: ['main reply', 'short reply'] });
  assertEquals(rec.transcribes, [[4, 'image/webp']]);
  assertEquals(rec.drafts, [{ guestText: GUEST, guestName: 'Ana Reyes', thread: { before: [{ from: 'host', text: 'Hello!' }], platform: 'messenger' } }]);
});

Deno.test('image: an unclear screenshot (platform other) is drafted as Airbnb-safe; an explicit label and guest_name win over the reader', async () => {
  const other = fake({ transcribe: () => Promise.resolve({ guest_name: null, platform: 'other', messages: [{ from: 'guest', text: 'Hello?' }] }) });
  const j = await (await handleGuestReplyDraft(post(img()), other.deps)).json();
  assertEquals([j.platform, j.guest_name, j.guest_text], ['airbnb', null, 'Hello?']);
  const lab = fake();
  const k = await (await handleGuestReplyDraft(post({ ...img(), platform: 'airbnb', guest_name: 'Ben' }), lab.deps)).json();
  assertEquals([k.platform, k.guest_name], ['airbnb', 'Ben']);
  assertEquals(lab.rec.drafts[0].thread.platform, 'airbnb');
});

Deno.test('422 no_guest_message: a screenshot with no guest line, or only host lines', async () => {
  for (const messages of [[], [{ from: 'host' as const, text: 'Welcome!' }], [{ from: 'guest' as const, text: 'Hi' }, { from: 'host' as const, text: 'Hello' }]]) {
    const { deps, rec } = fake({ transcribe: () => Promise.resolve({ guest_name: null, platform: 'other', messages }) });
    const res = await handleGuestReplyDraft(post(img()), deps);
    assertEquals(res.status, 422);
    assertEquals((await res.json()).error, 'no_guest_message');
    assertEquals(rec.drafts.length, 0);
  }
});

Deno.test('502 draft_failed: drafting throws, drafting returns nothing, or only a header, or the reader throws', async () => {
  const cases: Array<Partial<Deps>> = [
    { draft: () => Promise.reject(new TypeError(`model said: ${GUEST}`)) },
    { draft: () => Promise.resolve([]) },
    { draft: () => Promise.resolve(['header only']) },
    { draft: () => Promise.resolve(['header', '   ']) },
  ];
  for (const over of cases) {
    const { deps, rec } = fake(over);
    const res = await handleGuestReplyDraft(post({ text: GUEST }), deps);
    assertEquals(res.status, 502);
    assertEquals(await res.json(), { ok: false, error: 'draft_failed' });
    assertEquals(rec.logs.length, 0);
  }
  const t = fake({ transcribe: () => Promise.reject(new Error('no vision key')) });
  assertEquals((await handleGuestReplyDraft(post(img()), t.deps)).status, 502);
});

Deno.test('logs: one line per call with role, input, platform, reply count, ms and no guest text or name', async () => {
  const { deps, rec } = fake({});
  await handleGuestReplyDraft(post({ text: GUEST, guest_name: 'Ana Reyes' }), deps);
  await handleGuestReplyDraft(post(img()), deps);
  assertEquals(rec.logs.length, 2);
  assertEquals(Object.keys(JSON.parse(rec.logs[0])).sort(), ['fn', 'input', 'ms', 'platform', 'replies', 'role']);
  assertEquals(JSON.parse(rec.logs[1]).input, 'image');
  const all = [...rec.logs, ...rec.errors].join('\n');
  for (const secret of ['SECRET-GUEST-WORDS', 'magkano', 'Ana', 'Reyes', 'main reply']) assert(!all.includes(secret), secret);
});

Deno.test('logs: a failed draft logs the error class only, never its message', async () => {
  const { deps, rec } = fake({ draft: () => Promise.reject(new TypeError(`model said: ${GUEST} Ana Reyes`)) });
  await handleGuestReplyDraft(post({ text: GUEST, guest_name: 'Ana Reyes' }), deps);
  assertEquals(rec.errors.length, 1);
  assertEquals(JSON.parse(rec.errors[0]).error, 'TypeError');
  const all = [...rec.logs, ...rec.errors].join('\n');
  for (const secret of ['SECRET-GUEST-WORDS', 'Ana', 'Reyes']) assert(!all.includes(secret), secret);
});
