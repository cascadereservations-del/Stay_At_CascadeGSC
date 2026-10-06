import { assertEquals } from 'jsr:@std/assert@1';
import { appendHostTurn, handleHostReply, handoffCardText, replyWindow, signOffName, staffNameFromUser, withSignOff, type Deps, type Handoff, type Turn } from './logic.ts';
import { maskMoney } from '../_shared/ops-money.ts';

const NOW = new Date('2026-10-06T00:00:00Z');
const PSID = 'zz-psid-1';
const HID = '11111111-1111-4111-8111-111111111111';
const guest = (at: string): Turn => ({ role: 'guest', text: 'hello', at });
const fresh: Turn[] = [guest('2026-10-05T10:00:00Z'), { role: 'bot', text: 'hi', at: '2026-10-05T10:00:05Z' }];

type Calls = { sends: Array<[string, string]>; records: unknown[]; threadLoads: number; claims: number; unclaims: number; cards: Array<[number | string, string]> };
function fake(over: Partial<Deps> = {}, history: Turn[] = fresh, handoff: Handoff | null = { id: HID, psid: PSID, status: 'open' }): { deps: Deps; calls: Calls } {
  const calls: Calls = { sends: [], records: [], threadLoads: 0, claims: 0, unclaims: 0, cards: [] };
  const deps: Deps = {
    authenticate: () => Promise.resolve({ ok: true, staff: { name: 'Lloyd' } }),
    loadThread: (psid) => { calls.threadLoads++; return Promise.resolve(psid === PSID ? { psid, history } : null); },
    loadHandoff: () => Promise.resolve(handoff),
    send: (psid, text) => { calls.sends.push([psid, text]); return Promise.resolve(true); },
    claim: () => { calls.claims++; return Promise.resolve(true); },
    unclaim: () => { calls.unclaims++; return Promise.resolve(); },
    editCard: (id, text) => { calls.cards.push([id, text]); return Promise.resolve(); },
    record: (a) => { calls.records.push(a); return Promise.resolve({ thread: true }); },
    now: () => NOW,
    ...over,
  };
  return { deps, calls };
}
const post = (body: unknown, headers: Record<string, string> = { authorization: 'Bearer owner.jwt' }) =>
  new Request('https://example.test/host-reply', { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) });
const send = { action: 'send', psid: PSID, text: 'We saved the late check-in for you.' };

Deno.test('authz: no bearer token is 401 and nothing is looked up or sent', async () => {
  const { deps, calls } = fake();
  const res = await handleHostReply(post(send, {}), deps);
  assertEquals(res.status, 401);
  assertEquals(calls.sends.length, 0);
  assertEquals(calls.threadLoads, 0);
});

Deno.test('authz: a signed-in user who is not an active owner or admin is refused, nothing sent', async () => {
  const { deps, calls } = fake({ authenticate: () => Promise.resolve({ ok: false, status: 403, error: 'staff_access_denied' }) });
  const res = await handleHostReply(post(send), deps);
  assertEquals(res.status, 403);
  assertEquals((await res.json()).error, 'staff_access_denied');
  assertEquals(calls.sends.length, 0);
  assertEquals(calls.threadLoads, 0);
  assertEquals(calls.records.length, 0);
});

Deno.test('authz: an expired session is 401, nothing sent', async () => {
  const { deps, calls } = fake({ authenticate: () => Promise.resolve({ ok: false, status: 401, error: 'invalid_or_expired_session' }) });
  assertEquals((await handleHostReply(post(send), deps)).status, 401);
  assertEquals(calls.sends.length, 0);
});

Deno.test('explicit action: anything but action "send" is refused before any lookup or send', async () => {
  for (const body of [{ psid: PSID, text: 'x' }, { ...send, action: 'preview' }, { ...send, action: 'SEND' }, { ...send, action: true }]) {
    const { deps, calls } = fake();
    const res = await handleHostReply(post(body), deps);
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error, 'explicit_send_required');
    assertEquals(calls.sends.length, 0);
    assertEquals(calls.threadLoads, 0);
  }
});

Deno.test('explicit action: a GET or malformed body sends nothing', async () => {
  const { deps, calls } = fake();
  assertEquals((await handleHostReply(new Request('https://example.test/host-reply', { method: 'GET', headers: { authorization: 'Bearer owner.jwt' } }), deps)).status, 405);
  assertEquals((await handleHostReply(post('{not json'), deps)).status, 400);
  assertEquals((await handleHostReply(post('null'), deps)).status, 400);
  assertEquals(calls.sends.length, 0);
});

Deno.test('input checks: empty text, oversize text, bad psid and bad handoff id send nothing', async () => {
  const cases: Array<[Record<string, unknown>, string]> = [
    [{ ...send, text: '   ' }, 'invalid_text'], [{ ...send, text: 'x'.repeat(1901) }, 'text_too_long'],
    [{ ...send, psid: '' }, 'invalid_psid'], [{ ...send, psid: 'p'.repeat(65) }, 'invalid_psid'],
    [{ ...send, handoff_id: 'not-a-uuid' }, 'invalid_handoff_id'],
  ];
  for (const [body, error] of cases) {
    const { deps, calls } = fake();
    const res = await handleHostReply(post(body), deps);
    assertEquals((await res.json()).error, error);
    assertEquals(calls.sends.length, 0);
  }
});

Deno.test('send: one HUMAN_AGENT send with the sign-off, then the turn and the handoff are recorded', async () => {
  const { deps, calls } = fake();
  const res = await handleHostReply(post({ ...send, handoff_id: HID }), deps);
  const j = await res.json();
  assertEquals(res.status, 200);
  assertEquals(j.ok, true);
  assertEquals(calls.sends.length, 1);
  assertEquals(calls.sends[0], [PSID, 'We saved the late check-in for you.\n\n— Lloyd, Cascade Hideaway']);
  assertEquals(j.sent_text, calls.sends[0][1]);
  assertEquals(calls.records.length, 1);
  assertEquals(calls.claims, 1);
  assertEquals(j.handoff_marked, true);
  assertEquals(j.recorded, true);
});

Deno.test('send: without a handoff id nothing is marked sent', async () => {
  const { deps, calls } = fake();
  const j = await (await handleHostReply(post(send), deps)).json();
  assertEquals(calls.sends.length, 1);
  assertEquals(calls.claims, 0);
  assertEquals(j.handoff_marked, false);
});

Deno.test('refused send: Messenger says no -> 502, no history row, no handoff change', async () => {
  let attempts = 0;
  const { deps, calls } = fake({ send: () => { attempts++; return Promise.resolve(false); } });
  const res = await handleHostReply(post({ ...send, handoff_id: HID }), deps);
  assertEquals(res.status, 502);
  assertEquals((await res.json()).error, 'messenger_refused');
  assertEquals(attempts, 1);
  assertEquals(calls.records.length, 0);
  assertEquals(calls.claims, 1);
  assertEquals(calls.unclaims, 1); // the claim is put back so the host can tap again
  assertEquals(calls.cards.length, 0);
});

Deno.test('window: the 7 day HUMAN_AGENT window closed -> 409 and nothing is sent', async () => {
  const old: Turn[] = [guest('2026-09-28T23:59:00Z'), { role: 'bot', text: 'hi', at: '2026-09-28T23:59:05Z' }]; // 7 days and 1 minute before NOW
  const { deps, calls } = fake({}, old);
  const res = await handleHostReply(post(send), deps);
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error, 'reply_window_closed');
  assertEquals(calls.sends.length, 0);
});

Deno.test('window: a thread with no guest turn cannot be replied to', async () => {
  const { deps, calls } = fake({}, [{ role: 'bot', text: 'hi', at: '2026-10-05T10:00:00Z' }]);
  assertEquals((await handleHostReply(post(send), deps)).status, 409);
  assertEquals(calls.sends.length, 0);
});

Deno.test('unknown thread is 404; a handoff that belongs to another thread or is already handled sends nothing', async () => {
  const a = fake();
  assertEquals((await handleHostReply(post({ ...send, psid: 'zz-other' }), a.deps)).status, 404);
  const b = fake({}, fresh, { id: HID, psid: 'zz-other', status: 'open' });
  assertEquals((await handleHostReply(post({ ...send, handoff_id: HID }), b.deps)).status, 404);
  const c = fake({}, fresh, { id: HID, psid: PSID, status: 'sent' });
  const res = await handleHostReply(post({ ...send, handoff_id: HID }), c.deps);
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error, 'handoff_not_open');
  const d = fake({}, fresh, null);
  assertEquals((await handleHostReply(post({ ...send, handoff_id: HID }), d.deps)).status, 404);
  for (const x of [a, b, c, d]) assertEquals(x.calls.sends.length, 0);
});

Deno.test('replyWindow: latest guest turn decides; bad timestamps are ignored; the edge is exclusive', () => {
  assertEquals(replyWindow([guest('2026-10-05T10:00:00Z')], NOW).open, true);
  assertEquals(replyWindow([guest('2026-09-29T00:00:00Z')], NOW).open, false); // exactly 7 days
  assertEquals(replyWindow([guest('2026-09-29T00:00:01Z')], NOW).open, true);
  assertEquals(replyWindow([guest('2026-09-01T00:00:00Z'), guest('2026-10-05T10:00:00Z')], NOW).lastGuestAt, '2026-10-05T10:00:00.000Z');
  assertEquals(replyWindow([guest('garbage')], NOW), { open: false, lastGuestAt: null, closesAt: null });
  assertEquals(replyWindow([], NOW).open, false);
  assertEquals(replyWindow([guest('2026-10-05T10:00:00Z')], NOW).closesAt, '2026-10-12T10:00:00.000Z');
});

Deno.test('sign-off and history helpers match sendHostReply', () => {
  assertEquals(signOffName('  Marifel Santos '), 'Marifel');
  assertEquals(signOffName(''), 'Cascade host');
  assertEquals(signOffName(null), 'Cascade host');
  assertEquals(withSignOff('  Hi  ', 'Lloyd'), 'Hi\n\n— Lloyd, Cascade Hideaway');
  const long: Turn[] = Array.from({ length: 40 }, (_, i) => ({ role: 'guest' as const, text: `t${i}`, at: '2026-10-05T10:00:00Z' }));
  const next = appendHostTurn(long, 'final', '2026-10-06T00:00:00.000Z');
  assertEquals(next.length, 32);
  assertEquals(next[31], { role: 'bot', text: 'final', at: '2026-10-06T00:00:00.000Z' });
  assertEquals(appendHostTurn(null as unknown as Turn[], 'x', 'at').length, 1);
});

Deno.test('claim: a lost claim (zero rows) is 409 handoff_not_open and nothing is sent', async () => {
  const { deps, calls } = fake({ claim: () => Promise.resolve(false) });
  const res = await handleHostReply(post({ ...send, handoff_id: HID }), deps);
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error, 'handoff_not_open');
  assertEquals(calls.sends.length, 0);
  assertEquals(calls.records.length, 0);
});

Deno.test('claim: two concurrent sends on one handoff share one atomic claim -> exactly one Messenger send', async () => {
  let status = 'open';
  const claim = () => { if (status !== 'open') return Promise.resolve(false); status = 'sent'; return Promise.resolve(true); };
  const { deps, calls } = fake({ claim });
  const [a, b] = await Promise.all([handleHostReply(post({ ...send, handoff_id: HID }), deps), handleHostReply(post({ ...send, handoff_id: HID }), deps)]);
  assertEquals([a.status, b.status].sort(), [200, 409]);
  assertEquals(calls.sends.length, 1);
});

Deno.test('duplicate: no handoff, same final text as the last bot turn under 2 minutes -> 409 duplicate_reply, nothing sent', async () => {
  const final = withSignOff(send.text, 'Lloyd');
  const dup: Turn[] = [guest('2026-10-05T10:00:00Z'), { role: 'bot', text: final, at: '2026-10-05T23:59:00Z' }]; // 1 minute before NOW
  const a = fake({}, dup);
  const res = await handleHostReply(post(send), a.deps);
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error, 'duplicate_reply');
  assertEquals(a.calls.sends.length, 0);
  // two minutes or more ago, or different words: allowed
  const old = fake({}, [guest('2026-10-05T10:00:00Z'), { role: 'bot', text: final, at: '2026-10-05T23:58:00Z' }]);
  assertEquals((await handleHostReply(post(send), old.deps)).status, 200);
  const other = fake({}, [guest('2026-10-05T10:00:00Z'), { role: 'bot', text: 'something else', at: '2026-10-05T23:59:30Z' }]);
  assertEquals((await handleHostReply(post(send), other.deps)).status, 200);
});

Deno.test('sign-off: a user with only an e-mail signs Cascade host; a display name is used (first name)', () => {
  assertEquals(staffNameFromUser({}), 'Cascade host');
  assertEquals(staffNameFromUser({ app_metadata: {}, user_metadata: {} }), 'Cascade host');
  assertEquals(staffNameFromUser({ user_metadata: { display_name: 'Marifel Santos' } }), 'Marifel');
  assertEquals(staffNameFromUser({ app_metadata: { display_name: 'Lloyd' }, user_metadata: { display_name: 'Other' } }), 'Lloyd');
});

// D-306: the OPS handoff card is edited after a dashboard reply, and every character of it goes through maskMoney. A host may type a
// price to the guest (the guest's own chat, sent whole); the card the cleaners can read carries no money.
Deno.test('D-306: the OPS card edit goes through maskMoney and carries no money; the guest send stays whole', async () => {
  const money = 'The balance is PHP 4,550, or ₱2,800 for one night.';
  const h: Handoff = { id: HID, psid: PSID, status: 'open', guest_name: 'Zed', guest_text: 'How much for tonight, is 3,500 ok?', tg_message_id: 77 };
  const { deps, calls } = fake({}, fresh, h);
  const res = await handleHostReply(post({ ...send, text: money, handoff_id: HID }), deps);
  assertEquals(res.status, 200);
  assertEquals(calls.sends[0][1].includes('PHP 4,550'), true); // the guest gets the real text
  assertEquals(calls.cards.length, 1);
  const [id, card] = calls.cards[0];
  assertEquals(id, 77);
  assertEquals(card, handoffCardText('Lloyd', h, money));
  assertEquals(card, maskMoney(card)); // masking is idempotent: nothing left to hide
  assertEquals(/4,550|2,800|3,500|₱/.test(card), false);
  assertEquals(card.includes('Replied by Lloyd to Zed'), true);
});

Deno.test('card: no tg_message_id -> no card edit and no error', async () => {
  const { deps, calls } = fake();
  assertEquals((await handleHostReply(post({ ...send, handoff_id: HID }), deps)).status, 200);
  assertEquals(calls.cards.length, 0);
});
