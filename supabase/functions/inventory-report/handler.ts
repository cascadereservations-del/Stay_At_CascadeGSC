// inventory-report / handler.ts (s84 lane I-fn): the request handler. index.ts only wires it to Deno.serve, so tests call makeHandler().
// Env is read per request (tests set it). Every outside call goes through fetch, so a test stubs globalThis.fetch and sees the exact
// RPC names, argument keys and Telegram multipart.
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { hasMoney } from '../_shared/ops-money.ts';
import { redactForLog } from '../_shared/redaction.ts';
import { requireStaffAccess, StaffAuthError, staffAuthResponse } from '../_shared/staff-auth.ts';
import { buildLabels, renderLabels } from './labels.ts';
import { renderPdf } from './pdf.ts';
import { buildReport, type Dest, type Item, KINDS, type Kind, type Link, marksFor, type Purchase, type Shop } from './report.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
    return word ? word[0].toUpperCase() + word.slice(1) : '';
  } catch { return ''; }
}

export function makeHandler(opts: { now?: () => Date } = {}) {
  const now = opts.now ?? (() => new Date());
  return async (req: Request): Promise<Response> => {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_H });
    if (req.method !== 'POST') return reply({ ok: false, error: 'bad_request' }, 405);

    if (Number(req.headers.get('content-length') ?? 0) > 16_384) return reply({ ok: false, error: 'bad_request' }, 413); // before the pre-auth body parse
    const body = await req.json().catch(() => null) as Row | null;
    const isLabels = body?.kind === 'labels'; // s86: labels are for managers; every other kind needs read_operations only
    let who;
    try { who = await requireStaffAccess(req, isLabels ? 'manage_inventory' : 'read_operations', PROPERTY_ID); }
    catch (e) {
      if (isLabels && e instanceof StaffAuthError && e.status === 403) return reply({ ok: false, error: 'manage_only' }, 403);
      const r = staffAuthResponse(e, CORS_H); if (r) return r; throw e;
    }

    const kind = body?.kind as Kind, to: Dest = body?.to == null ? (isLabels ? 'finance' : 'ops') : body.to;
    const ids = body?.item_ids;
    if ((!isLabels && !KINDS.includes(kind)) || (to !== 'ops' && to !== 'finance')
      || (ids != null && (!Array.isArray(ids) || ids.length > 500 || !ids.every((x) => typeof x === 'string' && UUID.test(x))))) return reply({ ok: false, error: 'bad_request' }, 400);

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
    const loadFailed = (e: Row) => { console.error('inventory read failed:', redactForLog(String(e.code ?? ''), 'ops')); return reply({ ok: false, error: 'load_failed' }, 500); };
    let out: { title: string; subtitle: string; caption: string; filename: string; rowCount: number; render: () => Promise<{ bytes: Uint8Array; pages: number }> };

    if (isLabels) {
      // No money anywhere on a label sheet, so no cost column is selected. Codes: the oldest CH- code of each active item.
      const [ir, cr] = await Promise.all([
        db.from('inventory_items').select('id,name').eq('property_id', PROPERTY_ID).eq('is_active', true),
        db.from('inventory_item_codes').select('item_id,code,created_at').eq('property_id', PROPERTY_ID).like('code', 'CH-%').order('created_at', { ascending: true }),
      ]);
      if (ir.error || cr.error) return loadFailed((ir.error ?? cr.error) as Row);
      const code = new Map<string, string>();
      for (const c of (cr.data ?? []) as unknown as Row[]) if (!code.has(String(c.item_id))) code.set(String(c.item_id), String(c.code));
      const want = ids == null ? null : new Set<string>(ids.map((x: string) => x.toLowerCase()));
      const rows = ((ir.data ?? []) as unknown as Row[])
        .filter((r) => code.has(String(r.id)) && (!want || want.has(String(r.id).toLowerCase())))
        .map((r) => ({ name: String(r.name ?? ''), code: code.get(String(r.id))! }))
        .sort((a, b) => a.name.localeCompare(b.name, 'en', { sensitivity: 'base' }));
      if (rows.length === 0) return reply({ ok: false, error: 'nothing_to_print' }, 422);
      const l = buildLabels(rows, now(), await firstName(db, who.userId));
      out = { ...l, render: () => renderLabels(l.labels, l.title, now()) };
    } else {
    const itemCols = COLS + (fin ? ',unit_cost' : '');
    const readItems = (withPar: boolean) => db.from('inventory_items').select(itemCols + (withPar ? ',par_qty' : '')).eq('property_id', PROPERTY_ID).eq('is_active', true);
    let res = await readItems(true);
    if (res.error && /par_qty/.test(`${res.error.message} ${res.error.details ?? ''}`)) res = await readItems(false); // lane I-sql's release not applied yet
    if (res.error) return loadFailed(res.error as Row);
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

    // s86, Finance order/low only: where to buy and the price-up mark. The supplier tables may not exist yet (SQL not applied):
    // any failed read here just leaves the columns blank, it never fails the report.
    if (fin && (kind === 'order' || kind === 'low') && items.length) {
      try {
        const [lr, sr] = await Promise.all([
          db.from('inventory_item_suppliers').select('item_id,supplier_id,is_preferred'),
          db.from('inventory_suppliers').select('id,name').eq('property_id', PROPERTY_ID),
        ]);
        const readPurchases = (withSupplier: boolean) => db.from('inventory_purchases').select('item_id,unit_cost,purchased_at' + (withSupplier ? ',supplier_id' : ''))
          .in('item_id', items.map((i) => i.id)).order('purchased_at', { ascending: false }).order('created_at', { ascending: false }).limit(5000);
        let pr = await readPurchases(true);
        if (pr.error) pr = await readPurchases(false); // no supplier_id column yet: price marks still work
        const links: Link[] = lr.error ? [] : ((lr.data ?? []) as unknown as Row[]).map((r) => ({ itemId: String(r.item_id), supplierId: String(r.supplier_id), preferred: r.is_preferred === true }));
        const suppliers = new Map<string, string>(sr.error ? [] : ((sr.data ?? []) as unknown as Row[]).map((r) => [String(r.id), String(r.name ?? '')] as [string, string]));
        const purchases: Purchase[] = pr.error ? [] : ((pr.data ?? []) as unknown as Row[]).map((r) => ({ itemId: String(r.item_id), supplierId: r.supplier_id ?? null, unitCost: n(r.unit_cost), at: String(r.purchased_at ?? '').slice(0, 10) }));
        const marks = marksFor(items.map((i) => i.id), links, suppliers, purchases, now());
        for (const i of items) { const m = marks.get(i.id); if (m) { i.where = m.where; i.priceUpPct = m.upPct; } }
      } catch (e) { console.warn('supplier marks skipped:', redactForLog(String((e as Error)?.message ?? e), 'ops').slice(0, 120)); }
    }

    const report = buildReport(kind, to, items, shop, now(), await firstName(db, who.userId));
    out = { ...report, render: () => renderPdf(report, now()) };
    }
    // The row count is a machine number ("120 items"); maskMoney would read 100+ as an amount, so guard the words around it.
    const captionText = out.caption.replace(/\b\d+ items?\b/, 'n items');
    if (!fin && [out.title, out.subtitle, captionText].some(hasMoney)) {
      console.error('ops money guard tripped for', kind);
      return reply({ ok: false, error: 'ops_money_guard' }, 500);
    }
    const { bytes, pages } = await out.render();

    const form = new FormData();
    form.append('chat_id', chat);
    form.append('document', new Blob([bytes as unknown as BlobPart], { type: 'application/pdf' }), out.filename);
    form.append('caption', out.caption);
    const tg = await fetch(`https://api.telegram.org/bot${token}/sendDocument`, { method: 'POST', body: form, signal: AbortSignal.timeout(20_000) })
      .then((r) => r.json()).catch(() => null) as Row | null;
    if (!tg?.ok) {
      console.warn('sendDocument failed:', redactForLog(String(tg?.description ?? 'no answer'), 'ops').slice(0, 120));
      return reply({ ok: false, error: 'telegram_failed' }, 502);
    }
    return reply({ ok: true, to, kind, rows: out.rowCount, pages, message_id: tg.result?.message_id ?? null });
  };
}
