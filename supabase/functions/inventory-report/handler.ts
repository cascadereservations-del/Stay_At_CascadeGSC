// inventory-report / handler.ts (s84 lane I-fn): the request handler. index.ts only wires it to Deno.serve, so tests call makeHandler().
// Env is read per request (tests set it). Every outside call goes through fetch, so a test stubs globalThis.fetch and sees the exact
// RPC names, argument keys and Telegram multipart.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { hasMoney } from '../_shared/ops-money.ts';
import { redactForLog } from '../_shared/redaction.ts';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';
import { renderPdf } from './pdf.ts';
import { buildReport, type Dest, type Item, KINDS, type Kind, type Shop } from './report.ts';

export const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
export const CORS_H = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, x-client-info, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Max-Age': '86400',
};

function reply(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS_H, 'Content-Type': 'application/json' } });
}

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;
const n = (v: unknown): number | null => (v == null || v === '' || !Number.isFinite(Number(v)) ? null : Number(v));
const COLS = 'id,name,category,unit,qty_on_hand,reorder_below,is_consumable,purchase_unit,units_per_purchase';

/** First word of the staff member's name, from the auth profile; never an e-mail address. Falls back to "the team". */
// deno-lint-ignore no-explicit-any
async function firstName(db: any, userId: string): Promise<string> {
  try {
    const { data } = await db.auth.admin.getUserById(userId);
    const u = data?.user;
    const meta = (u?.app_metadata ?? {}) as Row, umeta = (u?.user_metadata ?? {}) as Row;
    const raw = [meta.display_name, umeta.display_name, umeta.full_name, umeta.name].find((x) => typeof x === 'string' && x.trim()) ?? (u?.email ?? '').split('@')[0].replace(/[._-]+/g, ' ');
    const word = String(raw).trim().split(/\s+/)[0].replace(/[^\p{L}'-]/gu, '');
    return word ? word[0].toUpperCase() + word.slice(1) : 'the team';
  } catch { return 'the team'; }
}

export function makeHandler(opts: { now?: () => Date } = {}) {
  const now = opts.now ?? (() => new Date());
  return async (req: Request): Promise<Response> => {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_H });
    if (req.method !== 'POST') return reply({ ok: false, error: 'bad_request' }, 405);

    let who;
    try { who = await requireStaffAccess(req, 'read_operations', PROPERTY_ID); }
    catch (e) { const r = staffAuthResponse(e, CORS_H); if (r) return r; throw e; }

    const body = await req.json().catch(() => null) as Row | null;
    const kind = body?.kind as Kind, to: Dest = body?.to == null ? 'ops' : body.to;
    if (!KINDS.includes(kind) || (to !== 'ops' && to !== 'finance')) return reply({ ok: false, error: 'bad_request' }, 400);

    const url = Deno.env.get('SUPABASE_URL'), anon = Deno.env.get('SUPABASE_ANON_KEY'), service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (to === 'finance') {
      const me = createClient(url!, anon!, { global: { headers: { Authorization: `Bearer ${who.accessToken}` } }, auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });
      const { data: ok, error } = await me.rpc('current_staff_authorized', { p_action: 'read_finance', p_property_id: PROPERTY_ID });
      if (error || ok !== true) return reply({ ok: false, error: 'finance_only' }, 403);
    }

    const token = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
    const chat = (to === 'finance' ? Deno.env.get('TELEGRAM_FINANCE_CHAT_ID') : Deno.env.get('TELEGRAM_CHAT_ID')) ?? '';
    if (!token || !chat || !service) return reply({ ok: false, error: 'not_configured' }, 503);

    // Service-role reads. An OPS send never selects a cost column at all.
    const db = createClient(url!, service, { auth: { persistSession: false, autoRefreshToken: false } });
    const fin = to === 'finance';
    const itemCols = COLS + (fin ? ',unit_cost' : '');
    const readItems = (withPar: boolean) => db.from('inventory_items').select(itemCols + (withPar ? ',par_qty' : '')).eq('property_id', PROPERTY_ID).eq('is_active', true);
    let res = await readItems(true);
    if (res.error && /par_qty/.test(`${res.error.message} ${res.error.details ?? ''}`)) res = await readItems(false); // lane I-sql's release not applied yet
    if (res.error) { console.error('inventory read failed:', redactForLog(String(res.error.code ?? ''), 'ops')); return reply({ ok: false, error: 'load_failed' }, 500); }
    const items: Item[] = ((res.data ?? []) as unknown as Row[]).map((r) => ({
      id: String(r.id), name: String(r.name ?? ''), category: r.category ?? null, unit: r.unit ?? null, qty: n(r.qty_on_hand) ?? 0,
      reorder: n(r.reorder_below), par: n(r.par_qty), consumable: r.is_consumable === true, purchaseUnit: r.purchase_unit ?? null,
      unitsPer: n(r.units_per_purchase), ...(fin ? { cost: n(r.unit_cost) } : {}),
    }));

    let shop: Shop[] = [];
    if (kind === 'order') {
      const sres = await db.from('inventory_shopping_list').select('item_id,item_name,quantity,purchase_unit,reason' + (fin ? ',estimated_cost' : ''))
        .eq('property_id', PROPERTY_ID).in('status', ['proposed', 'approved']);
      if (sres.error) console.warn('shopping list not read:', redactForLog(String(sres.error.code ?? ''), 'ops'));
      shop = ((sres.data ?? []) as unknown as Row[]).map((r) => ({
        itemId: r.item_id ?? null, name: String(r.item_name ?? ''), quantity: n(r.quantity) ?? 1, purchaseUnit: r.purchase_unit ?? null, note: r.reason ?? null,
        ...(fin ? { estCost: n(r.estimated_cost) } : {}),
      }));
    }

    const report = buildReport(kind, to, items, shop, now(), await firstName(db, who.userId));
    if (!fin && [report.title, report.subtitle, report.caption].some(hasMoney)) {
      console.error('ops money guard tripped for', kind);
      return reply({ ok: false, error: 'ops_money_guard' }, 500);
    }
    const { bytes, pages } = await renderPdf(report, now());

    const form = new FormData();
    form.append('chat_id', chat);
    form.append('document', new Blob([bytes as unknown as BlobPart], { type: 'application/pdf' }), report.filename);
    form.append('caption', report.caption);
    const tg = await fetch(`https://api.telegram.org/bot${token}/sendDocument`, { method: 'POST', body: form, signal: AbortSignal.timeout(20_000) })
      .then((r) => r.json()).catch(() => null) as Row | null;
    if (!tg?.ok) {
      console.warn('sendDocument failed:', redactForLog(String(tg?.description ?? 'no answer'), 'ops').slice(0, 120));
      return reply({ ok: false, error: 'telegram_failed' }, 502);
    }
    return reply({ ok: true, to, kind, rows: report.rowCount, pages, message_id: tg.result?.message_id ?? null });
  };
}
