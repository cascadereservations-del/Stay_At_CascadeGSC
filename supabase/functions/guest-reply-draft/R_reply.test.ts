// s82 lane R: fewer misses (second pass, malformed retry, host spoke last), options, staff access and the cleaner privacy rule.
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1';
import { handleGuestReplyDraft, type Deps } from './logic.ts';
import { draftOptions, introducesData, type Impl } from './R_draft.ts';
import type { ReadResult } from './R_transcribe.ts';

const G = 'Hi po, what time is check-in tomorrow?';
const post = (body: unknown) => new Request('https://example.test/guest-reply-draft', { method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer t' }, body: JSON.stringify(body) });
const img = { image: { base64: btoa('png-bytes'), mime: 'image/png' } };
const shot = (messages: ReadResult['messages'], extra: Partial<ReadResult> = {}): ReadResult => ({ guest_name: 'Ana', platform: 'messenger', messages, ...extra });
const NONE = shot([]);

function fake(reads: ReadResult[], over: Partial<Deps> = {}) {
  const passes: number[] = [], drafts: string[] = [], access: string[] = [], logs: string[] = [];
  let clock = 1000, i = 0; // frozen-style clock: deterministic steps
  const deps: Deps = {
    authenticate: () => Promise.resolve({ ok: true, access: 'full' }),
    draft: (t, _n, _th, a) => { drafts.push(t); access.push(a); return Promise.resolve(['header card', 'main reply', 'short reply']); },
    transcribe: (_b, _m, pass = 1) => { passes.push(pass); return Promise.resolve(reads[Math.min(i++, reads.length - 1)]); },
    now: () => (clock += 7), log: (l) => logs.push(l), logError: () => {},
    ...over,
  };
  return { deps, passes, drafts, access, logs };
}

Deno.test('host spoke last: drafts a reply to the last guest message and says so in the header', async () => {
  const { deps, drafts, passes } = fake([shot([{ from: 'guest', text: G }, { from: 'host', text: 'Hello Ana' }])]);
  const res = await handleGuestReplyDraft(post(img), deps);
  const j = await res.json();
  assertEquals(res.status, 200);
  assertEquals(drafts, [G]);
  assertEquals(j.guest_text, G);
  assert(j.header.includes("The last message in the screenshot is yours; this answers the guest's last message."));
  assertEquals(passes, [1]);
});

Deno.test('empty transcription triggers exactly one second pass, which can rescue the draft', async () => {
  const { deps, passes, drafts } = fake([NONE, shot([{ from: 'guest', text: G }])]);
  const res = await handleGuestReplyDraft(post(img), deps);
  assertEquals(res.status, 200);
  assertEquals(passes, [1, 2]);
  assertEquals(drafts, [G]);
});

Deno.test('no guest text after both passes: 422, and the reader ran exactly twice', async () => {
  const { deps, passes, drafts } = fake([NONE, shot([{ from: 'host', text: 'Welcome' }])]);
  const res = await handleGuestReplyDraft(post(img), deps);
  assertEquals([res.status, (await res.json()).error], [422, 'no_guest_message']);
  assertEquals(passes, [1, 2]);
  assertEquals(drafts.length, 0);
});

Deno.test('a good first read costs one reader call, no second pass', async () => {
  const { deps, passes } = fake([shot([{ from: 'guest', text: G }])]);
  await handleGuestReplyDraft(post(img), deps);
  assertEquals(passes, [1]);
});

Deno.test('malformed model JSON retries once instead of reading as no message', async () => {
  const a = fake([shot([], { malformed: true }), shot([{ from: 'guest', text: G }])]);
  assertEquals((await handleGuestReplyDraft(post(img), a.deps)).status, 200);
  assertEquals(a.passes, [1, 1]);
  const b = fake([shot([], { malformed: true }), shot([], { malformed: true })]); // still nothing: then the one stronger pass
  assertEquals((await handleGuestReplyDraft(post(img), b.deps)).status, 422);
  assertEquals(b.passes, [1, 1, 2]);
});

Deno.test('options: the response carries 2-3 distinct labelled texts and replies stays backward compatible', async () => {
  const out = { header: 'header card', options: [{ label: 'Warm', text: 'A' }, { label: 'Short', text: 'B' }, { label: 'With details', text: 'C' }] };
  const { deps } = fake([], { draft: () => Promise.resolve(out) });
  const j = await (await handleGuestReplyDraft(post({ text: G }), deps)).json();
  assertEquals(j.options, out.options);
  assertEquals(j.replies, ['A', 'B', 'C']);
  assertEquals(j.replies[0], j.options[0].text);
  assertEquals(new Set(j.options.map((o: { text: string }) => o.text)).size, 3);
  const legacy = fake([]);
  const k = await (await handleGuestReplyDraft(post({ text: G }), legacy.deps)).json();
  assertEquals(k.replies, ['main reply', 'short reply']);
  assertEquals(k.options.map((o: { label: string }) => o.label), ['Warm', 'Short']);
});

Deno.test('staff access: owner/admin draft with full access; a cleaner (or an unspecified role) gets limited access', async () => {
  const full = fake([]);
  await handleGuestReplyDraft(post({ text: G }), full.deps);
  assertEquals([full.access, JSON.parse(full.logs[0]).role], [['full'], 'owner_or_admin']);
  for (const auth of [{ ok: true as const, access: 'limited' as const }, { ok: true as const }]) {
    const c = fake([], { authenticate: () => Promise.resolve(auth) });
    assertEquals((await handleGuestReplyDraft(post({ text: G }), c.deps)).status, 200);
    assertEquals([c.access, JSON.parse(c.logs[0]).role], [['limited'], 'staff_limited']);
  }
});

Deno.test('unknown or disabled staff still get 403 and nothing runs', async () => {
  const f = fake([], { authenticate: () => Promise.resolve({ ok: false, status: 403, error: 'staff_access_denied' }) });
  const res = await handleGuestReplyDraft(post({ text: G }), f.deps);
  assertEquals([res.status, (await res.json()).error], [403, 'staff_access_denied']);
  assertEquals(f.drafts.length + f.passes.length, 0);
});

// ---- R_draft: options and the cleaner privacy rule ----
const SIGN = '\n\nMarifel & The Cascade Team\nHotel Comfort. Home Warmth.';
const MAIN = `Hi Ana! Yes po, check-in starts at 2:00 PM and check-out is at 11:00 AM. Early arrivals are welcome to leave their bags with us while the unit is made ready.${SIGN}`;
function impl(over: Partial<Impl> = {}): Impl & { calls: string[]; modelArgs: unknown[][] } {
  const calls: string[] = [], modelArgs: unknown[][] = [];
  return {
    calls, modelArgs,
    guestReply: () => { calls.push('guestReply'); return Promise.resolve(['header', MAIN, '']); },
    modelAll: (...a) => { calls.push('modelAll'); modelArgs.push(a.slice(2)); return Promise.resolve({ main: MAIN, variants: { short: 'Hi Ana! Check-in starts at 2:00 PM. See you then.', details: 'Hi Ana! Yes po, check-in starts at 2:00 PM and check-out is at 11:00 AM. Bags can be left with us before the unit is ready. The house is a few minutes from the airport.' } }); },
    variants: () => { calls.push('variants'); return Promise.resolve({ short: 'Hi Ana! Check-in starts at 2:00 PM. See you then.', details: 'Hi Ana! Yes po, check-in starts at 2:00 PM and check-out is at 11:00 AM. Bags can be left with us before the unit is ready. The house is a few minutes from the airport.' }); },
    ...over,
  };
}
// Any touch of the database fails the test: the limited path must not read anything itself.
const NO_DB = new Proxy({}, { get: () => { throw new Error('db touched'); } });

Deno.test('R_draft: a successful call returns Warm, Short and With details, distinct, each with the sign-off', async () => {
  const m = impl();
  const out = await draftOptions(NO_DB, { guestText: G, guestName: 'Ana', thread: {}, access: 'full' }, m);
  assertEquals(out.options.map((o) => o.label), ['Warm', 'Short', 'With details']);
  assertEquals(new Set(out.options.map((o) => o.text)).size, 3);
  assert(out.options[1].text.length < out.options[0].text.length);
  assert(out.options.every((o) => o.text.endsWith('Hotel Comfort. Home Warmth.')));
  assertEquals(m.calls, ['guestReply', 'variants']); // ONE extra model call for both alternatives
});

Deno.test('R_draft: a variant that fails the tone check is dropped, the Warm reply always remains', async () => {
  const m = impl({ variants: () => Promise.resolve({ short: 'Hi Ana! Check-in is at 2 PM! See you soon! Call us on gcash 09171234567.', details: null }) });
  const out = await draftOptions(NO_DB, { guestText: G, guestName: 'Ana', thread: {}, access: 'full' }, m);
  assertEquals(out.options.map((o) => o.label), ['Warm']);
  const broken = impl({ variants: () => Promise.reject(new Error('model down')) });
  assertEquals((await draftOptions(NO_DB, { guestText: G, guestName: 'Ana', thread: {}, access: 'full' }, broken)).options.length, 1);
});

Deno.test('limited path (faked model): draftOptions itself reads no db, skips draftGuestReply, passes ctx = [] and the Airbnb register', async () => {
  const m = impl();
  const out = await draftOptions(NO_DB, { guestText: G, guestName: 'Ana', thread: { before: [{ from: 'host', text: 'Hello' }] }, access: 'limited' }, m);
  assert(!m.calls.includes('guestReply'));
  assertEquals(m.calls, ['modelAll']); // one structured call: no separate variants call
  assertEquals(m.modelArgs[0][0], 'Ana'); // modelAll has no guest-context parameter at all
  assert(out.options.length >= 2);
  assert(!/balance|deposit|PHP|@/i.test(out.header));
});

Deno.test('cleaner: a phone, e-mail or amount that was not in her own input never reaches the response', async () => {
  const leak = `Hi Ana! Yes po. Your balance is PHP 3,500, call 0917 123 4567 or write guest@mail.com.${SIGN}`;
  const m = impl({ modelAll: () => Promise.resolve({ main: leak, variants: { short: 'Hi Ana! Please send PHP 1,000 to 0917 555 1212.', details: 'Hi Ana! Yes po, check-in starts at 2:00 PM.' } }) });
  const out = await draftOptions(NO_DB, { guestText: G, guestName: 'Ana', thread: {}, access: 'limited' }, m);
  const all = out.options.map((o) => o.text).join('\n') + out.header;
  assert(!/PHP|0917|@mail|3,500/.test(all), all);
  assert(out.options.length >= 1);
  // the same amount IS fine when she supplied it herself
  const mine = await draftOptions(NO_DB, { guestText: 'Is PHP 3,500 the right total?', guestName: 'Ana', thread: {}, access: 'limited' },
    impl({ modelAll: () => Promise.resolve({ main: `Hi Ana! Yes po, I will check the PHP 3,500 total and confirm here.${SIGN}`, variants: {} }) }));
  assert(mine.options[0].text.includes('PHP 3,500'));
  assert(introducesData('call 09171234567', 'nothing') && !introducesData('call 0917 123 4567', 'my number 09171234567'));
});

Deno.test('a draft with no main reply still fails (no empty options)', async () => {
  await assertRejects(() => draftOptions(NO_DB, { guestText: G, guestName: null, thread: {}, access: 'full' }, impl({ guestReply: () => Promise.resolve(['header']) })));
});

Deno.test('every active staff role reaches the limited check (index.ts lists all six roles)', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  for (const r of ['owner', 'admin', 'finance', 'inspector', 'cleaner', 'maintenance']) assert(src.includes(`'${r}'`), r);
});

Deno.test('introducesData: tokens, not substrings (10:00 AM is not PHP 1,000), 3.5k and spelled-out amounts are caught', () => {
  assert(introducesData('Please send PHP 1,000.', 'check-in at 10:00 AM?'));
  assert(introducesData('The total is 3.5k.', 'how much?'));
  assert(introducesData('That is three thousand five hundred pesos.', 'how much?'));
  assert(!introducesData('The PHP 3500 total is noted.', 'is 3,500 right?'));
  assert(!introducesData('about 3.5k as you said', 'you said 3.5k'));
});

Deno.test('a throw in the second reading pass keeps the 422 instead of a 502', async () => {
  let n = 0;
  const { deps } = fake([NONE], { transcribe: () => (++n === 2 ? Promise.reject(new Error('vision down')) : Promise.resolve(NONE)) });
  const res = await handleGuestReplyDraft(post(img), deps);
  assertEquals([res.status, (await res.json()).error], [422, 'no_guest_message']);
});

Deno.test('host spoke last: the host trailing message stays in the history given to the drafter', async () => {
  const seen: unknown[] = [];
  const { deps } = fake([shot([{ from: 'guest', text: G }, { from: 'host', text: 'Check-in is at 2 PM po.' }])], { draft: (_t, _n, th) => { seen.push(th.before); return Promise.resolve(['h', 'm']); } });
  await handleGuestReplyDraft(post(img), deps);
  assertEquals(seen, [[{ from: 'host', text: 'Check-in is at 2 PM po.' }]]);
});

Deno.test('a variant that is a near-duplicate of Warm (Jaccard above 0.9) is dropped', async () => {
  const near = MAIN.replace('Early arrivals', 'Early arrival');
  const out = await draftOptions(NO_DB, { guestText: G, guestName: 'Ana', thread: {}, access: 'full' }, impl({ variants: () => Promise.resolve({ short: near, details: null }) }));
  assertEquals(out.options.map((o) => o.label), ['Warm']);
});

Deno.test('time budget: a variants call that outlives the budget is abandoned, Warm goes out alone and the event is logged', async () => {
  const logs: string[] = [];
  const slow = impl({ variants: () => new Promise((r) => setTimeout(() => r({ short: 'Hi Ana! Check-in starts at 2:00 PM. See you then.' }), 500)) });
  const t0 = performance.now();
  const out = await draftOptions(NO_DB, { guestText: G, guestName: 'Ana', thread: {}, access: 'full' }, slow, { budgetMs: 40, log: (l) => logs.push(l) });
  assert(performance.now() - t0 < 300);
  assertEquals(out.options.map((o) => o.label), ['Warm']);
  assertEquals(logs.map((l) => JSON.parse(l).event), ['variants_budget_exceeded']);
  await new Promise((r) => setTimeout(r, 520)); // let the abandoned call settle inside the test
});
