// deno test --no-check --allow-env telegram-expense/guest-flow.test.ts
// The /guest flow against an in-memory telegram_pending and recording fakes for Telegram, the reader and the RPCs.
// Synthetic names and numbers only (public repo).
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type Deps, onGuestNameReply, onGuestTap, startGuestIntake } from './guest-flow.ts';

const GUEST = { guest_id: 'e2000000-0000-4000-8000-0000000000b1', name: 'Jonas Example', checkin: '2026-10-01', checkout: '2026-10-05', last_stay: null, id_on_file: false, has_contact: false, companions: [] };
const JPEG = new Uint8Array(40); JPEG.set([0xff, 0xd8, 0xff, 0xe0]);

/** A table with the few query shapes the flow uses. */
function fakeDb(opts: { rpc?: (fn: string, args: any) => any; uploadError?: string } = {}) {
  const rows: any[] = [];
  const calls: Array<{ fn: string; args: any }> = [];
  const uploads: string[] = [];
  const removed: string[] = [];
  let n = 0;
  const jget = (o: any, path: string) => path.split('->>').reduce((x, k) => x?.[k], o);
  const q = (op: string, arg?: any) => {
    const f: Array<(r: any) => boolean> = []; let patch: any = null;
    const api: any = {
      eq: (c: string, v: unknown) => { f.push((r) => String(c.includes('->>') ? jget(r, c.replace('payload->>', 'payload->>')) : r[c]) === String(v)); return api; },
      gt: (c: string, v: string) => { f.push((r) => r[c] > v); return api; },
      select: () => api, update: (p: any) => { patch = p; return api; },
      maybeSingle: async () => { const hit = rows.filter((r) => f.every((x) => x(r)))[0]; if (op === 'delete' && hit) rows.splice(rows.indexOf(hit), 1); return { data: hit ?? null }; },
      single: async () => ({ data: op === 'insert' ? arg : null }),
      then: (res: any) => { for (const r of rows.filter((x) => f.every((g) => g(x)))) if (patch) Object.assign(r, patch); return Promise.resolve({ error: null }).then(res); },
    };
    if (op === 'insert') { const row = { id: `0b9f2c1e-7a4d-4e1b-9c3a-5d6e7f8a9b0${(++n).toString(16)}`, ...arg }; rows.push(row); api.single = async () => ({ data: row }); }
    return api;
  };
  const db = {
    from: (_t: string) => ({ insert: (r: any) => q('insert', r), select: () => q('select'), delete: () => q('delete'), update: (p: any) => q('select').update(p) }),
    rpc: async (fn: string, args: any) => { calls.push({ fn, args }); return opts.rpc ? opts.rpc(fn, args) : { data: { ok: true, id: 'c0000000-0000-4000-8000-000000000001', guests: [GUEST] } }; },
    storage: { from: (_b: string) => ({ upload: async (p: string) => { uploads.push(p); return { error: opts.uploadError ? { message: opts.uploadError } : null }; }, remove: async (p: string[]) => { removed.push(...p); return {}; } }) },
  };
  return { db, rows, calls, uploads, removed };
}

function deps(f: ReturnType<typeof fakeDb>, readOut: string, over: Partial<Deps> = {}) {
  const sent: any[] = [], edits: any[] = [], answers: any[] = [];
  const d: Deps = {
    db: f.db, propertyId: '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd',
    send: async (chatId, text, extra) => { sent.push({ chatId, text, extra }); return { ok: true, result: { message_id: 500 + sent.length } }; },
    edit: async (chatId, mid, text, rm) => { edits.push({ chatId, mid, text, rm }); return { ok: true }; },
    answer: async (id, text) => { answers.push({ id, text }); return {}; },
    photo: async () => ({ bytes: JPEG, mime: 'image/jpeg' }),
    read: async () => readOut,
    visionReady: () => true, esc: (s) => s, today: () => '2026-10-02', ...over,
  };
  return { d, sent, edits, answers };
}

const photoMsg = { chat: { id: -100123 }, from: { id: 906700001, first_name: 'Ana' }, message_id: 77, photo: [{ file_id: 'F1' }] };
const tap = (data: string, from = 906700001) => ({ id: 'cb1', data, from: { id: from, first_name: from === 906700001 ? 'Ana' : 'Zed' }, message: { chat: { id: -100123 }, message_id: 900, text: 'card' } });
const pidOf = (rm: any, i = 0) => String(rm.inline_keyboard[i][0].callback_data).split(':')[2];

const ID_READ = JSON.stringify({ kind: 'id', name: 'SAMPLE, NORA MAE D.', id_type: 'passport' });

Deno.test('photo with /guest: one pick card, nothing read and nothing written yet', async () => {
  const f = fakeDb(); const { d, sent } = deps(f, ID_READ);
  await startGuestIntake(d, photoMsg, 'F1');
  assertEquals(f.calls.map((c) => c.fn), ['telegram_guest_candidates_v1']);
  assertEquals(sent.length, 1);
  assert(sent[0].text.includes('Nothing is saved yet. Whose photo is this?'));
  const kb = sent[0].extra.reply_markup.inline_keyboard;
  assertEquals(kb[0][0].text, 'Jonas Example · in house');
  assertEquals(kb[1].map((b: any) => b.text), ['🔎 Other guest', '❌ Cancel']);
  assertEquals(f.rows.length, 1);
  assertEquals(f.rows[0].kind, 'guest_pick');
  assert(!JSON.stringify(f.rows[0].payload).includes('SAMPLE'));
});

Deno.test('an unlinked Telegram user is told so before anything is read', async () => {
  const f = fakeDb({ rpc: () => ({ data: { ok: false, reason: 'unmapped_telegram_user' } }) });
  let reads = 0; const { d, sent } = deps(f, ID_READ, { read: async () => { reads++; return ID_READ; } });
  await startGuestIntake(d, photoMsg, 'F1');
  assertEquals(reads, 0);
  assert(sent[0].text.includes('not linked to a staff login'));
  assertEquals(f.rows.length, 0);
});

Deno.test('the RPC not deployed yet: a plain "not switched on" message, nothing else', async () => {
  const f = fakeDb({ rpc: () => ({ error: { code: 'PGRST202', message: 'Could not find the function public.telegram_guest_candidates_v1' } }) });
  const { d, sent } = deps(f, ID_READ);
  await startGuestIntake(d, photoMsg, 'F1');
  assert(sent[0].text.includes('not switched on yet'));
});

Deno.test('/guest with no photo answers with how to use it', async () => {
  const f = fakeDb(); const { d, sent } = deps(f, ID_READ);
  await startGuestIntake(d, { ...photoMsg, photo: undefined }, null);
  assert(sent[0].text.startsWith('Send the photo with the caption /guest'));
  assertEquals(f.calls.length, 0);
});

Deno.test('pick then Save: companion first, then the photo in the private bucket under <companion id>/<uuid>.jpg, then ID on file', async () => {
  const f = fakeDb({ rpc: (fn) => fn === 'telegram_guest_candidates_v1' ? { data: { ok: true, guests: [GUEST] } } : { data: { ok: true, id: 'c0000000-0000-4000-8000-000000000001' } } });
  const { d, sent, edits } = deps(f, ID_READ);
  await startGuestIntake(d, photoMsg, 'F1');
  const pid = pidOf(sent[0].extra.reply_markup);
  await onGuestTap(d, tap(`gst:pick:${pid}:0`));
  // the card now asks for one confirmation and nothing has been written
  const confirm = edits[edits.length - 1];
  assert(confirm.text.includes("Save Nora Mae D. Sample's passport photo as a companion of Jonas Example and mark ID on file?"));
  assertEquals(f.calls.filter((c) => c.fn.startsWith('telegram_save')).length, 0);
  assertEquals(f.uploads.length, 0);
  const savePid = pidOf(confirm.rm);
  await onGuestTap(d, tap(`gst:save:${savePid}`));
  assertEquals(f.calls.filter((c) => c.fn.startsWith('telegram_save')).map((c) => c.fn),
    ['telegram_save_guest_companion_v1', 'telegram_save_guest_companion_v1', 'telegram_save_guest_details_v1']);
  const [c1, c2, det] = f.calls.filter((c) => c.fn.startsWith('telegram_save'));
  assertEquals([c1.args.p_name, c1.args.p_id_type, c1.args.p_id_photo_path, c1.args.p_actor_telegram_id], ['Nora Mae D. Sample', 'passport', null, 906700001]);
  assertEquals(f.uploads.length, 1);
  assert(/^c0000000-0000-4000-8000-000000000001\/[0-9a-f-]{36}\.jpg$/.test(f.uploads[0]), 'neutral path: companion id / uuid . ext, no name, no number');
  assertEquals(c2.args.p_id_photo_path, f.uploads[0]);
  assertEquals(det.args.p_patch, { id_on_file: true });
  assert(det.args.p_reason.startsWith('Telegram /guest by Ana'));
  const done = edits[edits.length - 1].text;
  assert(done.startsWith('💬 GUEST'));
  assert(done.includes("Saved Nora Mae D. Sample's passport photo as a companion of Jonas Example and marked ID on file."));
  assertEquals(f.rows.length, 0, 'both pending rows are gone');
});

Deno.test('the booker\'s own ID also sets the profile ID type', async () => {
  const f = fakeDb(); const { d, sent, edits } = deps(f, JSON.stringify({ kind: 'id', name: 'Jonas Example', id_type: "driver's license" }));
  await startGuestIntake(d, photoMsg, 'F1');
  await onGuestTap(d, tap(`gst:pick:${pidOf(sent[0].extra.reply_markup)}:0`));
  await onGuestTap(d, tap(`gst:save:${pidOf(edits[edits.length - 1].rm)}`));
  const det = f.calls.find((c) => c.fn === 'telegram_save_guest_details_v1')!;
  assertEquals(det.args.p_patch, { id_on_file: true, id_type: 'drivers_license' });
});

Deno.test('a chat screenshot saves the phone and the new companions, no photo and no upload', async () => {
  const f = fakeDb(); const { d, sent, edits } = deps(f, JSON.stringify({ kind: 'chat', names: ['Ben Test'], phone: '0917 000 1234' }));
  await startGuestIntake(d, photoMsg, 'F1');
  await onGuestTap(d, tap(`gst:pick:${pidOf(sent[0].extra.reply_markup)}:0`));
  const confirm = edits[edits.length - 1];
  assert(confirm.text.includes('• Phone 09170001234') && confirm.text.includes('• Add as companions: Ben Test'));
  await onGuestTap(d, tap(`gst:save:${pidOf(confirm.rm)}`));
  assertEquals(f.uploads.length, 0);
  assertEquals(f.calls.filter((c) => c.fn.startsWith('telegram_save')).map((c) => [c.fn, c.args.p_patch ?? c.args.p_name]),
    [['telegram_save_guest_details_v1', { contact_number: '09170001234' }], ['telegram_save_guest_companion_v1', 'Ben Test']]);
});

Deno.test('Cancel and an unreadable photo save nothing', async () => {
  const f = fakeDb(); const { d, sent, edits } = deps(f, '{"kind":"other"}');
  await startGuestIntake(d, photoMsg, 'F1');
  await onGuestTap(d, tap(`gst:pick:${pidOf(sent[0].extra.reply_markup)}:0`));
  assert(edits[edits.length - 1].text.includes('nothing was saved for Jonas Example'));
  assertEquals(f.calls.filter((c) => c.fn.startsWith('telegram_save')).length, 0);
  const g = fakeDb(); const x = deps(g, ID_READ);
  await startGuestIntake(x.d, photoMsg, 'F1');
  await onGuestTap(x.d, tap(`gst:cancel:${pidOf(x.sent[0].extra.reply_markup)}`));
  assertEquals(x.edits[0].text, '❌ Cancelled. Nothing saved.');
  assertEquals(g.rows.length, 0);
});

Deno.test('only the person who sent the photo can tap; a second Save does nothing', async () => {
  const f = fakeDb(); const { d, sent, edits, answers } = deps(f, ID_READ);
  await startGuestIntake(d, photoMsg, 'F1');
  const pid = pidOf(sent[0].extra.reply_markup);
  await onGuestTap(d, tap(`gst:pick:${pid}:0`, 111));
  assert(String(answers[answers.length - 1].text).includes("Ana's"), 'someone else is told whose card it is');
  assertEquals(edits.length, 0);
  assertEquals(f.rows.length, 1, 'their tap did not consume the row');
  await onGuestTap(d, tap(`gst:pick:${pid}:0`));
  const savePid = pidOf(edits[edits.length - 1].rm);
  await onGuestTap(d, tap(`gst:save:${savePid}`));
  const writes = f.calls.filter((c) => c.fn.startsWith('telegram_save')).length;
  await onGuestTap(d, tap(`gst:save:${savePid}`));
  assertEquals(f.calls.filter((c) => c.fn.startsWith('telegram_save')).length, writes, 'the second tap wrote nothing');
  assert(edits[edits.length - 1].text.includes('expired'));
});

Deno.test('a failed photo upload leaves the companion and says exactly that; no photo path is written', async () => {
  const f = fakeDb({ uploadError: 'bucket offline' }); const { d, sent, edits } = deps(f, ID_READ);
  await startGuestIntake(d, photoMsg, 'F1');
  await onGuestTap(d, tap(`gst:pick:${pidOf(sent[0].extra.reply_markup)}:0`));
  await onGuestTap(d, tap(`gst:save:${pidOf(edits[edits.length - 1].rm)}`));
  const text = edits[edits.length - 1].text;
  assert(text.startsWith('🟡 ATTENTION'));
  assert(text.includes('Storing the photo failed: bucket offline.') && text.includes('Already saved before that: Nora Mae D. Sample as a companion.'));
  assertEquals(f.calls.filter((c) => c.fn === 'telegram_save_guest_companion_v1').length, 1);
  assertEquals(f.calls.filter((c) => c.fn === 'telegram_save_guest_details_v1').length, 0);
});

Deno.test('the RPC refusing at save time is reported, and a linked-photo failure removes the orphan object', async () => {
  let n = 0;
  const f = fakeDb({ rpc: (fn) => {
    if (fn === 'telegram_guest_candidates_v1') return { data: { ok: true, guests: [GUEST] } };
    n++;
    return n === 2 ? { error: { message: 'photo object not found in guest-id-photos' } } : { data: { ok: true, id: 'c0000000-0000-4000-8000-000000000001' } };
  } });
  const { d, sent, edits } = deps(f, ID_READ);
  await startGuestIntake(d, photoMsg, 'F1');
  await onGuestTap(d, tap(`gst:pick:${pidOf(sent[0].extra.reply_markup)}:0`));
  await onGuestTap(d, tap(`gst:save:${pidOf(edits[edits.length - 1].rm)}`));
  assertEquals(f.removed, f.uploads, 'the uploaded object is removed when its row could not be linked');
  assert(edits[edits.length - 1].text.includes('Linking the photo failed'));
});

Deno.test('"Other guest": the name reply finds guests and the new card keeps working with the same photo', async () => {
  const f = fakeDb({ rpc: (fn, a) => fn === 'telegram_guest_candidates_v1' && a.p_search ? { data: { ok: true, guests: [{ ...GUEST, name: 'Quinn Quiet', checkin: null, checkout: null, last_stay: '2026-09-14' }] } } : { data: { ok: true, guests: [GUEST] } } });
  const { d, sent } = deps(f, ID_READ);
  await startGuestIntake(d, photoMsg, 'F1');
  const pid = pidOf(sent[0].extra.reply_markup);
  await onGuestTap(d, tap(`gst:other:${pid}`));
  const prompt = sent[sent.length - 1];
  assert(prompt.text.startsWith('🔎 Guest name:') && prompt.extra.reply_markup.force_reply);
  assertEquals(prompt.extra.reply_to_message_id, 77, 'the prompt replies to the staff members own message so selective force_reply reaches them');
  const handled = await onGuestNameReply(d, { chat: { id: -100123 }, from: { id: 906700001 }, message_id: 80, text: 'quiet', reply_to_message: { message_id: 501 + 1, from: { is_bot: true }, text: prompt.text } });
  assertEquals(handled, true);
  const card = sent[sent.length - 1];
  assert(card.text.includes('These guests match "quiet"'));
  assertEquals(card.extra.reply_markup.inline_keyboard[0][0].text, 'Quinn Quiet · last stay Sep 14');
  assertEquals(f.rows.length, 1, 'still one pending row for the same photo');
  assertEquals(await onGuestNameReply(d, { chat: { id: -100123 }, from: { id: 1 }, message_id: 81, text: 'x', reply_to_message: { message_id: 9, from: { is_bot: true }, text: 'something else' } }), false);
});

// Session 72: a card posted by airbnb-email-sync has no owner (from_id null). Only an owner/admin tapper gets past the staff check (before any take); the save RPCs check again.
const airbnbCard = async (f: ReturnType<typeof fakeDb>) => (await f.db.from('telegram_pending').insert({
  chat_id: -100123, kind: 'guest_save', expires_at: new Date(Date.now() + 3_600_000).toISOString(),
  payload: { from_id: null, from_name: 'Airbnb e-mail', file_id: '', plan: { kind: 'chat', guestId: GUEST.guest_id, guestName: GUEST.name, phone: '09171230000', replacesPhone: false, newNames: ['Ben Test'], knownNames: [], via: 'airbnb' } },
}).select('id').single()).data.id as string;

Deno.test('an Airbnb e-mail card: an admin tapper can Save, the actor sent to the RPC is the tapper, and the companion note says Airbnb', async () => {
  const f = fakeDb(); const { d, edits } = deps(f, ID_READ);
  const pid = await airbnbCard(f);
  await onGuestTap(d, tap(`gst:save:${pid}`, 111));
  const saves = f.calls.filter((c) => c.fn.startsWith('telegram_save'));
  assertEquals(saves.map((c) => [c.fn, c.args.p_actor_telegram_id]), [['telegram_save_guest_details_v1', 111], ['telegram_save_guest_companion_v1', 111]]);
  assertEquals(saves[0].args.p_patch, { contact_number: '09171230000' });
  assertEquals(saves[1].args.p_notes, 'Added from the Airbnb message');
  assert(edits[edits.length - 1].text.includes('Saved for Jonas Example: phone 09171230000, companion Ben Test'));
  assertEquals(f.rows.length, 0, 'the tap consumed the card');
});

// A tapper who is not owner/admin staff: the candidates RPC (the staff check) answers ok:false for them.
const notStaff = () => fakeDb({ rpc: (fn) => fn === 'telegram_guest_candidates_v1' ? { data: { ok: false, reason: 'unmapped_telegram_user' } } : { data: { ok: true } } });

Deno.test('an Airbnb e-mail card: a tapper who is not owner/admin is refused on Save before anything is consumed, written or edited', async () => {
  const f = notStaff(); const { d, edits, answers } = deps(f, ID_READ);
  const pid = await airbnbCard(f);
  await onGuestTap(d, tap(`gst:save:${pid}`, 222));
  assertEquals(answers.map((a) => a.text), ['Only the owner or admin can use this card. Nothing changed.']);
  assertEquals(edits.length, 0, 'the card text is untouched');
  assertEquals(f.rows.length, 1, 'the pending row is still there');
  assertEquals(f.calls.filter((c) => c.fn.startsWith('telegram_save')).length, 0);
});

Deno.test('an Airbnb e-mail card: a tapper who is not owner/admin cannot Cancel it either; an admin then still can Save', async () => {
  const f = notStaff(); const { d, edits, answers } = deps(f, ID_READ);
  const pid = await airbnbCard(f);
  await onGuestTap(d, tap(`gst:cancel:${pid}`, 333));
  assertEquals(answers[0].text, 'Only the owner or admin can use this card. Nothing changed.');
  assertEquals(edits.length, 0);
  assertEquals(f.rows.length, 1, 'the card is not removed by a refused tapper');
  const ok = fakeDb(); const t = deps(ok, ID_READ); // an admin: the staff check passes
  const pid2 = await airbnbCard(ok);
  await onGuestTap(t.d, tap(`gst:save:${pid2}`, 111));
  assert(t.edits[t.edits.length - 1].text.includes('Saved for Jonas Example'));
});

Deno.test('an Airbnb e-mail card: an admin Cancel writes nothing and removes the card', async () => {
  const f = fakeDb(); const { d, edits } = deps(f, ID_READ);
  const pid = await airbnbCard(f);
  await onGuestTap(d, tap(`gst:cancel:${pid}`, 333));
  assertEquals(edits[0].text, '❌ Cancelled. Nothing saved.');
  assertEquals(f.calls.filter((c) => c.fn.startsWith('telegram_save')).length, 0);
  assertEquals(f.rows.length, 0);
});
