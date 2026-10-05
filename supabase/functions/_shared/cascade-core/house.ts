// House knowledge (D-282, DESIGN-house-knowledge-2026-09-29): the how-to facts from the Operations Manual and the welcome
// guide, one row per topic in `house_facts` (service role only). Read by messenger-concierge (public, or guest once the
// stay is verified) and telegram-cassy (every tier). Loaded whole and cached 10 min, like the landmarks block; a fact
// taught in Telegram is live within 10 minutes. The Wi-Fi password and the on-ground contact stay in app_settings and
// are filled in here, so the table never holds a second copy.
import { phDisplay } from './contact.ts';
export type Tier = 'public' | 'guest' | 'staff';
export type HouseRow = { topic: string; title: string; body: string; keywords: string[]; tier: Tier };
type Db = { from: (t: string) => any };

const RANK: Record<Tier, number> = { public: 0, guest: 1, staff: 2 };
let cache: { at: number; rows: HouseRow[] } | null = null;

/** Pure: {{WIFI_SSID}} {{WIFI_PASSWORD}} {{ONGROUND}} from app_settings rows; an unknown value reads as "ask us". */
export function fillPlaceholders(body: string, settings: { key: string; value: unknown }[]): string {
  const get = (k: string) => { const v = settings.find((r) => r.key === k)?.value; return typeof v === 'string' ? v.trim() : ''; };
  const name = get('onground_name'), phone = phDisplay(get('onground_phone'));
  return body
    .replaceAll('{{WIFI_SSID}}', get('wifi_ssid') || 'on the card in the unit')
    .replaceAll('{{WIFI_PASSWORD}}', get('wifi_password') || 'on the card in the unit')
    .replaceAll('{{ONGROUND}}', name && phone ? `${name} (${phone})` : name || phone || 'our on-ground host');
}

export async function loadHouse(db: Db, nowMs = Date.now()): Promise<HouseRow[]> {
  if (cache && nowMs - cache.at < 10 * 60_000) return cache.rows;
  const [f, s] = await Promise.all([
    db.from('house_facts').select('topic, title, body, keywords, tier').eq('is_active', true),
    db.from('app_settings').select('key, value').in('key', ['wifi_ssid', 'wifi_password', 'onground_name', 'onground_phone']),
  ]);
  if (f.error) throw new Error(`house_facts: ${f.error.message}`);
  const rows = ((f.data ?? []) as HouseRow[]).map((r) => ({ ...r, keywords: r.keywords ?? [], body: fillPlaceholders(r.body, s.data ?? []) }));
  cache = { at: nowMs, rows };
  return rows;
}
export const clearHouseCache = () => { cache = null; };

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
/** A keyword counts as a whole word or phrase: "ac" is not in "place", "pan" is not in "Japan". */
const hasPhrase = (text: string, kw: string) => new RegExp(`(^|[^\\p{L}\\p{N}])${esc(kw.toLowerCase())}($|[^\\p{L}\\p{N}])`, 'u').test(text);

/** Rows for this text, best first, never above `allowed`. `locked`: a guest-tier row is the best answer and the reader is
 *  not yet a verified guest (ties go to the open row, so "is there wifi?" is answered and "wifi password" is locked). */
export function matchHouse(rows: HouseRow[], text: string, allowed: Tier, limit = 3): { rows: HouseRow[]; locked: HouseRow | null } {
  const t = text.toLowerCase();
  const scored = rows
    .map((r) => ({ r, n: r.keywords.filter((k) => k && hasPhrase(t, k)).length }))
    .filter((h) => h.n > 0)
    .sort((a, b) => b.n - a.n || RANK[a.r.tier] - RANK[b.r.tier]);
  const open = scored.filter((h) => RANK[h.r.tier] <= RANK[allowed]);
  const guest = RANK[allowed] < RANK.guest ? scored.find((h) => h.r.tier === 'guest') : undefined;
  const locked = guest && guest.n > (open[0]?.n ?? 0) ? guest.r : null;
  return { rows: open.slice(0, limit).map((h) => h.r), locked };
}

/** The HOUSE section of the concierge's system prompt. */
export function houseBlock(rows: HouseRow[]): string {
  if (!rows.length) return 'HOUSE: none for this turn. For a how-to question FACTS does not answer, do not improvise: say the host will confirm.';
  return `HOUSE (how-to notes for this unit; answer how-to questions from these, in the guest's register, and do not add steps they do not contain):\n${rows.map((r) => `- ${r.title}: ${r.body}`).join('\n')}`;
}

// ── Telegram (D-282 section 4): one read tool for every staff surface, one teach tool behind a confirm card. Kept here, not
// in tools.ts, because tools.ts is also bundled by airbnb-email-sync and submit-booking (Rule 9: smallest set to redeploy).
export const HOUSE_READ_DECL = { name: 'house_info', description: 'How-to facts about the unit from the house reference (aircon, TV, Wi-Fi with its password, door and key card, EcoFlow, outages, emergencies, check-out, turnover steps, supplier contacts). Pass a few words as query; an empty query lists every topic. Answer only from what it returns.',
  parameters: { type: 'object', properties: { query: { type: 'string', description: 'A few words, e.g. "wifi password" or "water heater"' } } } };
export const HOUSE_TEACH_DECL = { name: 'teach_house_fact', description: 'Save, edit or retire a house fact when Lloyd or Marifel says "cassy teach: ...", "cassy edit <topic>: ..." or "cassy retire <topic>". Rewrite the body in Cassy\'s guest voice: calm, precise, warm, English, 2-5 sentences, practical steps, "we" not "I", guide never command ("you may", "once"), no exclamation marks, never a door code, payment number or login. A confirmation card is sent; nothing is saved until it is tapped.',
  parameters: { type: 'object', required: ['topic', 'title', 'tier'], properties: {
    topic: { type: 'string', description: 'Lowercase slug, e.g. "aircon" or "supplier-contacts-staff"; reuse an existing topic to edit it' },
    title: { type: 'string' }, body: { type: 'string', description: 'The fact in Cassy voice (not needed to retire)' },
    tier: { type: 'string', enum: ['public', 'guest', 'staff'], description: 'public = anyone on Messenger; guest = a verified current guest; staff = Telegram only' },
    keywords: { type: 'array', items: { type: 'string' }, description: 'Lowercase words a guest would use, English plus Tagalog/Bisaya' },
    retire: { type: 'boolean', description: 'true to stop using this topic' } } } };

/** house_info: matching rows (every tier), or the topic list when the query is empty or matches nothing. */
export async function houseInfo(db: Db, query: string): Promise<unknown> {
  const rows = await loadHouse(db);
  const q = query.trim();
  const hit = q ? matchHouse(rows, q, 'staff', 5).rows : [];
  if (hit.length) return { facts: hit.map((r) => ({ topic: r.topic, title: r.title, tier: r.tier, body: r.body })) };
  return { ...(q ? { note: `nothing matched "${q}"` } : {}), topics: rows.map((r) => `${r.topic} (${r.tier}): ${r.title}`) };
}

export type HouseTeach = { topic: string; title: string; body: string; tier: Tier; keywords: string[]; retire: boolean; by: string };

/** Pure: the teach tool's arguments made safe, or an error for the model. */
export function teachArgs(args: Record<string, unknown>, by: string): HouseTeach | { error: string } {
  const topic = String(args.topic ?? '').toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40);
  const title = String(args.title ?? '').trim().slice(0, 80), body = String(args.body ?? '').trim().slice(0, 1200);
  const retire = args.retire === true;
  if (!topic || !title) return { error: 'need topic and title' };
  if (!retire && !body) return { error: 'need body' };
  const tier = (['public', 'guest', 'staff'] as const).find((t) => t === args.tier) ?? 'staff'; // unsure -> the narrowest
  const kw = Array.isArray(args.keywords) ? args.keywords.map((k) => String(k).toLowerCase().trim()).filter(Boolean) : [];
  const keywords = [...new Set(kw.length ? kw : title.toLowerCase().split(/[^\p{L}\p{N}-]+/u).filter((w) => w.length > 2))].slice(0, 25);
  return { topic, title, body, tier, keywords, retire, by };
}

/** The confirm card. The tap (llm_house_confirm, telegram-expense) saves it; llm_cancel is already handled there. */
export async function teachCard(db: Db, chatId: string | number, args: Record<string, unknown>, by: string): Promise<{ card: { text: string; keyboard: { text: string; callback_data: string }[][] } | null; result: unknown }> {
  const t = teachArgs(args, by);
  if ('error' in t) return { card: null, result: t };
  const { data: old } = await db.from('house_facts').select('title, body, is_active').eq('topic', t.topic).maybeSingle();
  if (t.retire && !old) return { card: null, result: { error: `no topic ${t.topic}` } };
  const { data, error } = await db.from('telegram_pending').insert({ chat_id: chatId, kind: 'llm_house', payload: t }).select('id').single();
  if (error || !data?.id) throw new Error(`telegram_pending: ${error?.message ?? 'no id'}`);
  const text = t.retire
    ? `📘 Retire "${old.title}" (${t.topic})? Cassy stops using it within 10 minutes of the tap.`
    : [`📘 Save "${t.title}" (${t.tier}, topic ${t.topic})?`, '', t.body, ...(old ? ['', `was: ${old.body}`] : []), '', `Keywords: ${t.keywords.join(', ')}`, 'Cassy uses it within 10 minutes of the tap.'].join('\n');
  return { card: { text, keyboard: [[{ text: '✅ Save it', callback_data: `llm_house_confirm:${data.id}` }, { text: '❌ Cancel', callback_data: `llm_cancel:${data.id}` }]] }, result: { card_sent: true, topic: t.topic, tier: t.tier, retire: t.retire } };
}

/** D-283: who may save a taught fact - any tap in the Finance chat (Lloyd, Marifel; she stays unmapped, D-186), or a mapped,
 *  enabled owner/admin anywhere (Lloyd in a DM). Everyone else is refused and the card stays for someone who may. */
export async function mayTeach(db: Db, chatId: unknown, fromId: unknown, financeChat: string): Promise<boolean> {
  if (financeChat && String(chatId ?? '') === financeChat) return true;
  if (!fromId) return false;
  const { data } = await db.from('staff_access_profiles').select('role').eq('telegram_user_id', fromId).is('disabled_at', null).maybeSingle();
  return ['owner', 'admin'].includes(String(data?.role ?? ''));
}

/** The card's line after the tap. A retire card carries no real tier (teachArgs defaults it), so none is shown. */
export function houseTapLine(p: HouseTeach, who: string, esc: (s: string) => string = (s) => s): string {
  return p.retire
    ? `📘 Retired "${esc(p.title)}" by ${who}. Cassy stops using it within 10 minutes.`
    : `📘 Saved "${esc(p.title)}" (${p.tier}) by ${who}. Cassy uses it within 10 minutes.`;
}

/** The tap: upsert on topic, or retire. Returns an error message, or null when saved. */
export async function applyHouseFact(db: Db, p: HouseTeach, tappedBy: string): Promise<string | null> {
  const at = new Date().toISOString(), by = `${tappedBy} (asked by ${p.by})`.slice(0, 200);
  const { error } = p.retire
    ? await db.from('house_facts').update({ is_active: false, updated_by: by, updated_at: at }).eq('topic', p.topic)
    : await db.from('house_facts').upsert({ topic: p.topic, title: p.title, body: p.body, keywords: p.keywords, tier: p.tier, is_active: true, updated_by: by, updated_at: at });
  clearHouseCache();
  return error ? String(error.message ?? error).slice(0, 150) : null;
}
