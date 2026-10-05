// Session 67b: Telegram /guest intake - the calls. Staff sends one photo with the caption /guest (or replies /guest to a photo):
//   1. pick the guest   2. the photo is read once (ID: name + type only; chat screenshot: names + mobile number)
//   3. a card says exactly what will be saved   4. only the Save tap writes anything (private bucket + audited RPCs).
// Every write goes through telegram_save_guest_details_v1 / telegram_save_guest_companion_v1, which refuse a Telegram user who
// is not an active owner/admin staff profile for this property. State lives in telegram_pending (kinds guest_pick, guest_save),
// 15 minutes, one tap consumes it. Pure parts are in guest.ts. Nothing here logs a name, a number or a photo.
import { withHeader } from '../_shared/cascade-core/format.ts';
import { type Candidate, confirmBody, GUEST_PROMPT, idLabel, type Plan, parseGuestRead, parseGuestTap, pickLabel, planFor, sniffImage } from './guest.ts';

export const GUEST_NAME_PROMPT_HEAD = '🔎 Guest name:';
export const GUEST_NAME_PROMPT = `${GUEST_NAME_PROMPT_HEAD} reply to this message with the guest's name (first or last name is enough).`;
export const GUEST_HELP = 'Send the photo with the caption /guest, or reply /guest to a photo. It can be an ID (I keep the name and ID type, never the number) or a screenshot of the guest chat (I keep the names and mobile number). Nothing is saved until you tap Save.';
export const GUEST_NOT_LINKED = "Your Telegram is not linked to a staff login, so I can't save guest details from here. Ask Lloyd to link it in the admin dashboard (Staff). Nothing was read or saved.";
const BUCKET = 'guest-id-photos';
const TTL_MIN = 15;
const CANCELLED = '❌ Cancelled. Nothing saved.';
const EXPIRED = '⏰ That card expired, so nothing was saved. Send the photo with /guest again.';

export type Deps = {
  db: any;
  propertyId: string;
  send: (chatId: any, text: string, extra?: Record<string, unknown>) => Promise<any>;
  edit: (chatId: any, mid: number, text: string, rm?: unknown) => Promise<any>;
  answer: (cbId: string, text?: string) => Promise<any>;
  /** Download a Telegram file by id. */
  photo: (fileId: string) => Promise<{ bytes: Uint8Array; mime: string } | null>;
  /** One image-to-text call (the shared vision helper, VISION_PROVIDER). */
  read: (prompt: string, bytes: Uint8Array, mime: string) => Promise<string>;
  visionReady: () => boolean;
  esc: (s: string) => string;
  today: () => string;
};

const who = (from: any) => String(from?.first_name ?? from?.username ?? 'Team').slice(0, 30);
const mt = () => new Date().toLocaleTimeString('en-PH', { timeZone: 'Asia/Manila', hour: 'numeric', minute: '2-digit' });
const errText = (e: any) => String(e?.message ?? e ?? 'unknown error').replace(/\s+/g, ' ').slice(0, 140);

async function put(d: Deps, chatId: any, kind: 'guest_pick' | 'guest_save', payload: Record<string, unknown>): Promise<string> {
  const { data } = await d.db.from('telegram_pending')
    .insert({ chat_id: chatId, kind, payload, expires_at: new Date(Date.now() + TTL_MIN * 60_000).toISOString() }).select('id').single();
  return data?.id ?? '';
}
/** Read the pending row; null when gone or expired. `consume` deletes it in the same call so a double tap acts once. */
async function take(d: Deps, pid: string, consume: boolean): Promise<{ kind: string; payload: any } | null> {
  const q = consume ? d.db.from('telegram_pending').delete().eq('id', pid) : d.db.from('telegram_pending').select('kind,payload,expires_at').eq('id', pid);
  const { data } = await (consume ? q.select('kind,payload,expires_at') : q).maybeSingle();
  if (!data || new Date(data.expires_at) < new Date() || !String(data.kind).startsWith('guest_')) return null;
  return { kind: data.kind, payload: data.payload };
}

const header = (subject: string, lines: string[]) => withHeader('attention', subject, lines.join('\n'));

async function candidates(d: Deps, actor: unknown, search: string | null): Promise<{ list: Candidate[] } | { error: string }> {
  const t = d.today(), to = new Date(Date.parse(`${t}T00:00:00Z`) + 7 * 86_400_000).toISOString().slice(0, 10);
  const { data, error } = await d.db.rpc('telegram_guest_candidates_v1', { p_actor_telegram_id: actor, p_property_id: d.propertyId, p_from: t, p_to: to, p_search: search });
  if (error) return { error: /could not find the function|PGRST202|42883/i.test(`${error.code} ${error.message}`) ? 'The guest intake is not switched on yet (database update pending). Nothing was saved.' : `I could not load the guests: ${errText(error)}. Nothing was saved.` };
  if (data?.ok === false) return { error: data.reason === 'search_too_short' ? 'Type at least two letters of the name.' : GUEST_NOT_LINKED };
  return { list: (data?.guests ?? []) as Candidate[] };
}

function pickCard(d: Deps, pid: string, list: Candidate[], search: string | null): { text: string; rm: unknown } {
  const t = d.today();
  const lead = list.length
    ? (search ? `Nothing is saved yet. These guests match "${d.esc(search)}". Tap the one this photo belongs to.` : 'Nothing is saved yet. Whose photo is this? Tap the guest it belongs to.')
    : (search ? `No guest matches "${d.esc(search)}". Tap Other guest to try another spelling.` : 'No guest is staying in the next 7 days. Tap Other guest to search by name.');
  const rows = list.map((c, i) => [{ text: pickLabel(c, t), callback_data: `gst:pick:${pid}:${i}` }]);
  rows.push([{ text: '🔎 Other guest', callback_data: `gst:other:${pid}` }, { text: '❌ Cancel', callback_data: `gst:cancel:${pid}` }]);
  return { text: header('guest photo', [lead]), rm: { inline_keyboard: rows } };
}

/** Entry point: a photo captioned /guest, or /guest in reply to a photo. */
export async function startGuestIntake(d: Deps, msg: any, fileId: string | null): Promise<void> {
  const chatId = msg.chat?.id, from = msg.from ?? {};
  if (!fileId) { await d.send(chatId, GUEST_HELP, { reply_to_message_id: msg.message_id }); return; }
  if (!d.visionReady()) { await d.send(chatId, 'Photo reading is switched off right now (no vision key). Nothing was read or saved.', { reply_to_message_id: msg.message_id }); return; }
  const c = await candidates(d, from.id, null);
  if ('error' in c) { await d.send(chatId, c.error, { reply_to_message_id: msg.message_id }); return; }
  const pid = await put(d, chatId, 'guest_pick', { from_id: from.id, from_name: who(from), file_id: fileId, src_mid: msg.message_id, candidates: c.list });
  if (!pid) { await d.send(chatId, 'I could not open that card, so nothing was saved. Try again in a minute.', { reply_to_message_id: msg.message_id }); return; }
  const card = pickCard(d, pid, c.list, null);
  await d.send(chatId, card.text, { reply_markup: card.rm, reply_to_message_id: msg.photo ? msg.message_id : msg.reply_to_message?.message_id ?? msg.message_id });
}

/** A reply to the "Guest name:" prompt. Returns true when it was ours. */
export async function onGuestNameReply(d: Deps, msg: any): Promise<boolean> {
  const chatId = msg.chat?.id, replyTo = msg.reply_to_message;
  if (!replyTo?.from?.is_bot || !String(replyTo.text ?? '').startsWith(GUEST_NAME_PROMPT_HEAD)) return false;
  const { data: row } = await d.db.from('telegram_pending').select('id,payload,expires_at').eq('chat_id', chatId).eq('kind', 'guest_pick')
    .eq('payload->>prompt_mid', String(replyTo.message_id)).gt('expires_at', new Date().toISOString()).maybeSingle();
  if (!row) { await d.send(chatId, EXPIRED, { reply_to_message_id: msg.message_id }); return true; }
  if (String(row.payload.from_id) !== String(msg.from?.id)) { await d.send(chatId, `That search was opened by ${d.esc(String(row.payload.from_name ?? 'someone else'))}. Nothing changed.`, { reply_to_message_id: msg.message_id }); return true; }
  const q = String(msg.text ?? '').trim().slice(0, 60);
  const c = await candidates(d, msg.from?.id, q);
  if ('error' in c) { await d.send(chatId, c.error, { reply_to_message_id: msg.message_id }); return true; }
  await d.db.from('telegram_pending').update({ payload: { ...row.payload, candidates: c.list, prompt_mid: null }, expires_at: new Date(Date.now() + TTL_MIN * 60_000).toISOString() }).eq('id', row.id);
  const card = pickCard(d, row.id, c.list, q);
  await d.send(chatId, card.text, { reply_markup: card.rm, reply_to_message_id: msg.message_id });
  return true;
}

/** Every gst: button. */
export async function onGuestTap(d: Deps, cq: any): Promise<void> {
  const chatId = cq.message?.chat?.id, mid = cq.message?.message_id, tap = parseGuestTap(String(cq.data ?? ''));
  if (!tap) { await d.answer(cq.id, 'That button is not valid. Nothing changed.'); return; }
  const peek = await take(d, tap.pid, false);
  if (!peek) { await d.answer(cq.id); await d.edit(chatId, mid, EXPIRED); return; }
  if (peek.payload.from_id != null && String(peek.payload.from_id) !== String(cq.from?.id)) { // from_id null = a card posted by airbnb-email-sync for any owner/admin; the save RPCs still refuse an unmapped Telegram user
    await d.answer(cq.id, `That card is ${String(peek.payload.from_name ?? 'someone else')}'s. Nothing changed.`); return; }

  if (tap.act === 'cancel') { await take(d, tap.pid, true); await d.answer(cq.id); await d.edit(chatId, mid, CANCELLED); return; }

  if (tap.act === 'other') {
    if (peek.kind !== 'guest_pick') { await d.answer(cq.id, 'That card has moved on. Nothing changed.'); return; }
    await d.answer(cq.id);
    const r = await d.send(chatId, GUEST_NAME_PROMPT, { reply_markup: { force_reply: true, selective: true, input_field_placeholder: 'Guest name' }, reply_to_message_id: peek.payload.src_mid ?? mid }); // selective force_reply targets the sender of the message it replies to: the staff member, not the bot
    const pm = r?.result?.message_id;
    if (!pm) { await d.send(chatId, 'I could not open the name prompt. Nothing changed.'); return; }
    await d.db.from('telegram_pending').update({ payload: { ...peek.payload, prompt_mid: pm }, expires_at: new Date(Date.now() + TTL_MIN * 60_000).toISOString() }).eq('id', tap.pid);
    return;
  }

  if (tap.act === 'pick') {
    const g = (peek.kind === 'guest_pick' ? peek.payload.candidates : [])?.[tap.i] as Candidate | undefined;
    if (!g) { await d.answer(cq.id, 'That guest is no longer on the list. Nothing changed.'); return; }
    const got = await take(d, tap.pid, true);
    if (!got) { await d.answer(cq.id); return; }
    await d.answer(cq.id);
    await d.edit(chatId, mid, header('guest photo', [`Reading the photo for ${d.esc(g.name)}. Nothing is saved yet.`]));
    let raw = '';
    try {
      const ph = await d.photo(String(got.payload.file_id));
      if (!ph) { await d.edit(chatId, mid, header('guest photo', ['I could not download that photo from Telegram, so nothing was read or saved. Send it again with /guest.'])); return; }
      raw = await d.read(GUEST_PROMPT, ph.bytes, ph.mime);
    } catch (e) { await d.edit(chatId, mid, header('guest photo', [`I could not read that photo (${d.esc(errText(e))}). Nothing was saved. Send it again with /guest.`])); return; }
    const plan = planFor(parseGuestRead(raw), g);
    if (!plan) { await d.edit(chatId, mid, header('guest photo', [`I could not find an ID or a guest's names and number in that photo, so nothing was saved for ${d.esc(g.name)}. Send a clearer photo with /guest.`])); return; }
    const spid = await put(d, chatId, 'guest_save', { from_id: got.payload.from_id, from_name: got.payload.from_name, file_id: got.payload.file_id, plan });
    if (!spid) { await d.edit(chatId, mid, header('guest photo', ['I could not open the confirm step, so nothing was saved. Try again in a minute.'])); return; }
    await d.edit(chatId, mid, header('guest photo', confirmBody(plan, d.esc)), { inline_keyboard: [[{ text: '✅ Save', callback_data: `gst:save:${spid}` }, { text: '❌ Cancel', callback_data: `gst:cancel:${spid}` }]] });
    return;
  }

  // save
  if (peek.kind !== 'guest_save') { await d.answer(cq.id, 'Pick the guest first. Nothing changed.'); return; }
  const got = await take(d, tap.pid, true);
  if (!got) { await d.answer(cq.id); return; }
  await d.answer(cq.id);
  const out = await savePlan(d, got.payload.plan as Plan, cq.from, String(got.payload.file_id));
  await d.edit(chatId, mid, withHeader(out.ok ? 'guest' : 'attention', 'guest details', [...out.lines, '', `${out.ok ? 'Done' : 'Stopped'} by ${d.esc(who(cq.from))} at ${mt()}.`].join('\n')));
}

type Out = { ok: boolean; lines: string[] };

/** The writes, in order; stops at the first failure and says what already landed. */
async function savePlan(d: Deps, p: Plan, from: any, fileId: string): Promise<Out> {
  const by = `Telegram /guest by ${who(from)}`;
  const done: string[] = [];
  const fail = (what: string, e: unknown): Out => ({ ok: false, lines: [`${what} failed: ${d.esc(errText(e))}.`, done.length ? `Already saved before that: ${done.join('; ')}.` : 'Nothing was saved.'] });
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await d.db.rpc(fn, args);
    if (error) throw new Error(error.message ?? String(error));
    if (data?.ok === false) throw new Error(data.reason === 'unmapped_telegram_user' ? 'your Telegram is not linked to a staff login' : String(data.reason ?? 'refused'));
    return data;
  };
  const details = (patch: Record<string, unknown>) => rpc('telegram_save_guest_details_v1', { p_guest_id: p.guestId, p_patch: patch, p_actor_telegram_id: from.id, p_reason: by });
  const companion = (name: string, idType: string | null, path: string | null, notes: string | null) =>
    rpc('telegram_save_guest_companion_v1', { p_guest_id: p.guestId, p_name: name, p_id_type: idType, p_id_photo_path: path, p_contact: null, p_notes: notes, p_actor_telegram_id: from.id, p_reason: by });

  if (p.kind === 'chat') {
    try {
      if (p.phone) { await details({ contact_number: p.phone }); done.push(`phone ${p.phone}`); }
    } catch (e) { return fail('Saving the phone number', e); }
    for (const n of p.newNames) {
      try { await companion(n, null, null, p.via === 'airbnb' ? 'Added from the Airbnb message' : 'Added from the guest chat screenshot'); done.push(`companion ${d.esc(n)}`); }
      catch (e) { return fail(`Adding ${d.esc(n)}`, e); }
    }
    return { ok: true, lines: [`Saved for ${d.esc(p.guestName)}: ${done.join(', ')}. The dashboard shows them now.`] };
  }

  let id: string;
  try { id = String((await companion(p.companionName, p.idType, null, null)).id); }
  catch (e) { return fail(`Saving ${d.esc(p.name)} as a companion`, e); }
  done.push(`${d.esc(p.companionName)} as a companion`);
  let path: string;
  try {
    const ph = await d.photo(fileId);
    const kind = ph ? sniffImage(ph.bytes) : null;
    if (!ph || !kind) throw new Error('the photo is gone from Telegram or is not a JPEG, PNG or WebP under 10 MB');
    path = `${id}/${crypto.randomUUID()}.${kind.ext}`;
    const { error } = await d.db.storage.from(BUCKET).upload(path, ph.bytes, { contentType: kind.mime, upsert: false });
    if (error) throw new Error(error.message ?? String(error));
  } catch (e) { return fail('Storing the photo', e); }
  try { await companion(p.companionName, p.idType, path, null); done.push('photo in the private ID store'); }
  catch (e) {
    await d.db.storage.from(BUCKET).remove([path]).catch(() => null); // an object no row points at helps nobody
    return fail('Linking the photo', e);
  }
  try { await details(p.own ? { id_on_file: true, id_type: p.idType } : { id_on_file: true }); done.push('ID on file'); }
  catch (e) { return fail('Marking ID on file', e); }
  const whose = p.own ? `${d.esc(p.guestName)}'s own ${idLabel(p.idType)}` : `${d.esc(p.name)}'s ${idLabel(p.idType)}`;
  return { ok: true, lines: [`Saved ${whose} photo${p.own ? ' on' : ' as a companion of'} ${p.own ? 'their guest record' : d.esc(p.guestName)} and marked ID on file. It is in the dashboard under Companions.`] };
}
