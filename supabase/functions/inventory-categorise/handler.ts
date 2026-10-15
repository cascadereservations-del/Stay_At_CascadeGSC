// inventory-categorise / handler.ts (s86 lane D-cat, spec 9.5): Jev sorts 'Uncategorised' items into the EXISTING categories.
// Never renames a category, never moves an item that already has a real one, never creates one. Fail-open: any Jev problem = no change.
// Env is read per request (tests set it); every outside call goes through fetch, so tests stub globalThis.fetch.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { recordUsage } from '../_shared/cascade-core/usage.ts';
import { redactForLog } from '../_shared/redaction.ts';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';
import { jevCategorise } from './jev.ts';

export const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
export const UNCATEGORISED = 'Uncategorised';
export const MIN_CONFIDENCE = 0.6;
export const MAX_ITEMS = 50;
export const DAILY_BUDGET = 500; // Jev ~USD 0.04 per 1,000 calls (D-271); 500 rows a day is far inside the USD 1 a day OpenRouter cap
const NAMES_PER_CATEGORY = 5, NOTICE_NAMES = 10, CONCURRENCY = 5;
export const CORS_H = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, x-client-info, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Max-Age': '86400',
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function reply(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS_H, 'Content-Type': 'application/json' } });
}

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;
export type Result = { item_id: string; name: string; before: string; after: string; confidence: number };

/** Category -> up to 5 of its item names, categories sorted so the question is stable. Uncategorised is never a choice. */
export function buildCriteria(items: { name: string; category: string }[]): Record<string, string> {
  const by = new Map<string, string[]>();
  for (const i of items) {
    const c = (i.category ?? '').trim();
    if (!c || c === UNCATEGORISED) continue;
    const list = by.get(c) ?? [];
    if (list.length < NAMES_PER_CATEGORY && i.name) list.push(i.name);
    by.set(c, list);
  }
  return Object.fromEntries([...by.keys()].sort().map((c) => [c, by.get(c)!.join(', ') || c]));
}

/** Names only, no money, no exclamation (D-306 voice). */
export function noticeText(results: Result[]): string {
  const shown = results.slice(0, NOTICE_NAMES).map((r) => `${r.name} → ${r.after}`).join(', ');
  const more = results.length > NOTICE_NAMES ? `, and ${results.length - NOTICE_NAMES} more` : '';
  return `Cassy sorted ${results.length} new ${results.length === 1 ? 'item' : 'items'} into categories (${shown}${more}). Change them in Inventory > Tidy categories.`;
}

/** Start of the Manila (UTC+8) day as an ISO instant, for the daily budget window. */
export function manilaDayStart(now: Date): string {
  const shifted = now.getTime() + 8 * 3600_000;
  return new Date(shifted - (shifted % 86_400_000) - 8 * 3600_000).toISOString();
}

export function makeHandler(opts: { now?: () => Date; timeoutMs?: number } = {}) {
  const now = opts.now ?? (() => new Date());
  return async (req: Request): Promise<Response> => {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_H });
    if (req.method !== 'POST') return reply({ ok: false, error: 'bad_request' }, 405);

    try { await requireStaffAccess(req, 'manage_inventory', PROPERTY_ID); }
    catch (e) { const r = staffAuthResponse(e, CORS_H); if (r) return r; throw e; }

    const body = await req.json().catch(() => null) as Row | null;
    const itemId = typeof body?.item_id === 'string' ? body.item_id : null;
    if (!(body?.all === true || (itemId && UUID.test(itemId)))) return reply({ ok: false, error: 'bad_request' }, 400);

    const url = Deno.env.get('SUPABASE_URL'), service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!url || !service) return reply({ ok: false, error: 'not_configured' }, 503);
    const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

    // Budget first: a stop costs nothing. A failed count does not block (fail-open); the model cap is the backstop.
    const used = await db.from('llm_usage').select('id', { count: 'exact', head: true }).eq('title', 'inventory_categorise').gte('at', manilaDayStart(now()));
    if (!used.error && (used.count ?? 0) > DAILY_BUDGET) return reply({ ok: false, error: 'budget' }, 429);

    const res = await db.from('inventory_items').select('id,name,category').eq('property_id', PROPERTY_ID).eq('is_active', true);
    if (res.error) { console.error('inventory read failed:', redactForLog(String(res.error.code ?? ''), 'ops')); return reply({ ok: false, error: 'load_failed' }, 500); }
    const items = ((res.data ?? []) as Row[]).map((r) => ({ id: String(r.id), name: String(r.name ?? ''), category: String(r.category ?? '').trim() }));

    const criteria = buildCriteria(items);
    const pending = items.filter((i) => (i.category === UNCATEGORISED || i.category === '') && (body!.all === true || i.id === itemId));
    const targets = pending.slice(0, MAX_ITEMS);
    const remaining = pending.length - targets.length;
    const none = () => reply({ ok: true, results: [] as Result[], remaining });
    if (!targets.length || !Object.keys(criteria).length) return none();

    const key = Deno.env.get('CASCADE_OPENROUTER_BOT_KEY');
    const results: Result[] = [];
    let rpcMissing = false;
    const work = async (it: { id: string; name: string }) => {
      const j = await jevCategorise(it.name, criteria, key, opts.timeoutMs ?? 4000);
      if (key) recordUsage({ title: 'inventory_categorise', provider: 'openrouter', model: 'typesafe/jev-1.13', ok: j.ok, error: j.ok ? null : j.error ?? 'error' });
      if (!j.pick || j.pick.confidence < MIN_CONFIDENCE) return;
      const { data, error } = await db.rpc('s_inventory_item_category_auto_v1', { p_item_id: it.id, p_category: j.pick.category, p_confidence: j.pick.confidence });
      if (error) {
        if (error.code === 'PGRST202') rpcMissing = true; // SQL release not applied yet: do nothing, never 500
        console.warn('category write failed:', redactForLog(String(error.code ?? ''), 'ops'));
        return;
      }
      if ((data as Row | null)?.ok !== true) return; // not_uncategorised (moved meanwhile) or unknown_category: the RPC is the guard
      results.push({ item_id: it.id, name: it.name, before: String(data.before ?? UNCATEGORISED), after: String(data.after ?? j.pick.category), confidence: j.pick.confidence });
    };
    for (let i = 0; i < targets.length && !rpcMissing; i += CONCURRENCY) await Promise.all(targets.slice(i, i + CONCURRENCY).map(work));
    if (rpcMissing) return none();

    // Order follows the request, not the finish order.
    results.sort((a, b) => targets.findIndex((t) => t.id === a.item_id) - targets.findIndex((t) => t.id === b.item_id));

    // One Finance-group line per call that changed something. Never OPS, never a fallback to it.
    const token = Deno.env.get('TELEGRAM_BOT_TOKEN'), chat = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
    if (results.length && token && chat) {
      const text = noticeText(results);
      const tg = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ chat_id: chat, text }), signal: AbortSignal.timeout(10_000),
      }).then((r) => r.json()).catch(() => null) as Row | null;
      console.log('category notice', JSON.stringify({ sent: tg?.ok === true, line: redactForLog(text, 'finance').slice(0, 200) }));
    }
    return reply({ ok: true, results, remaining });
  };
}
