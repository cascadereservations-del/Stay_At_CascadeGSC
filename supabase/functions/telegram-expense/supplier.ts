// s86 lane D-tg (SPEC 3.3): supplier step on the "Update inventory?" receipt card. Supplier NAMES only, never a price.
// Pure helpers plus three small db functions (db is injected). If the supplier table or RPCs are not applied yet, state is 'off'
// and the card is exactly what it was before. Callback data is `<prefix>:<pending id>:<short code>`, never the vendor string.
// deno-lint-ignore-file no-explicit-any
import { redactForLog } from '../_shared/redaction.ts';

export type Sup = { id: string; name: string };
export type SupState = {
  state: 'off' | 'matched' | 'pick' | 'chosen' | 'skipped';
  supplier_id?: string | null;
  name?: string | null;
  choices: Sup[]; // up to 3 most-used
};

const esc = (s: unknown) => String(s ?? '').replace(/([_*`\[])/g, '\\$1');
export const lowerVendor = (v: string) => v.trim().toLowerCase().replace(/\s+/g, ' ').slice(0, 80);
export const truncVendor = (v: string, max = 18) => { const t = v.trim().replace(/\s+/g, ' '); return t.length <= max ? t : t.slice(0, max).trimEnd() + '...'; };

/** PostgREST / Postgres "this table / function / column / argument is not there yet". */
export function isMissingSchema(err: any): boolean {
  const code = String(err?.code ?? '');
  return ['PGRST202', 'PGRST204', 'PGRST205', '42P01', '42883', '42703'].includes(code);
}

/** Most-used first (by purchase count), then name; at most `n`. */
export function rankSuppliers(sups: Sup[], purchaseSupplierIds: Array<string | null>, n = 3): Sup[] {
  const count = new Map<string, number>();
  for (const id of purchaseSupplierIds) if (id) count.set(id, (count.get(id) ?? 0) + 1);
  return [...sups].sort((a, b) => (count.get(b.id) ?? 0) - (count.get(a.id) ?? 0) || a.name.localeCompare(b.name)).slice(0, n);
}

export function supplierLine(s: SupState, vendor: string): string | null {
  if (s.state === 'off') return null;
  if (s.state === 'matched' || s.state === 'chosen') return `Supplier: ${esc(s.name)}`;
  if (s.state === 'skipped') return 'Supplier: left blank';
  return `Supplier: not in the list yet ("${esc(vendor)}")`;
}

export function renderSyncCard(p: { items: any[]; unmatched?: string[]; vendor?: string | null; sup?: SupState }): string {
  const lines = p.items.map((m: any) => `  • ${esc(m.item_name)}  +${m.qty}`);
  const tail = p.unmatched?.length ? ['', `_Not tracked: ${esc(p.unmatched.join(', '))}_`] : [];
  const sl = p.sup ? supplierLine(p.sup, p.vendor ?? '') : null;
  return [`📦 *Update inventory?*`, `${p.items.length} item(s) from this receipt match your stock:`, ...lines, ...(sl ? ['', sl] : []), ...tail].join('\n');
}

/** One row: Is it X? (up to 3), New: <vendor>, Skip. `prefix` is invsup (receipt card) or invchs (after apply). */
export function choiceRow(prefix: string, pid: string, choices: Sup[], vendor: string): any[] {
  return [
    ...choices.slice(0, 3).map((c, i) => ({ text: `Is it ${c.name.slice(0, 20)}?`, callback_data: `${prefix}:${pid}:${i}` })),
    ...(vendor ? [{ text: `New: ${truncVendor(vendor)}`, callback_data: `${prefix}:${pid}:n` }] : []),
    { text: 'Skip', callback_data: `${prefix}:${pid}:s` },
  ];
}

export function syncKeyboard(pid: string, s: SupState | undefined, vendor: string) {
  const main = [{ text: '✅ Update stock', callback_data: `invsync_ok:${pid}` }, { text: '⏭️ Skip', callback_data: `invsync_skip:${pid}` }];
  return { inline_keyboard: s?.state === 'pick' ? [choiceRow('invsup', pid, s.choices, vendor), main] : [main] };
}

export function parseCb(data: string, prefix: string): { pid: string; code: string } | null {
  const m = new RegExp(`^${prefix}:([0-9a-f-]{36}):([0-2ns])$`).exec(data);
  return m ? { pid: m[1], code: m[2] } : null;
}

/** Active suppliers, most-used (by purchase count) first, top 3. Returns null when the schema is not there yet. */
export async function topSuppliers(db: any, propertyId: string): Promise<{ list: Sup[]; top: Sup[] } | null> {
  const { data: sups, error } = await db.from('inventory_suppliers').select('id,name').eq('property_id', propertyId).eq('is_active', true);
  if (error) { if (!isMissingSchema(error)) console.error('supplier list failed', redactForLog(String(error.message ?? error)).slice(0, 160)); return null; }
  const list = (sups ?? []) as Sup[];
  const { data: pur } = await db.from('inventory_purchases').select('supplier_id').not('supplier_id', 'is', null).order('purchased_at', { ascending: false }).limit(1000);
  return { list, top: rankSuppliers(list, (pur ?? []).map((r: any) => r.supplier_id)) };
}

/** Resolver + most-used list. Any missing-schema error means the feature is off. Never throws. */
export async function buildSupState(db: any, propertyId: string, vendor: string | null | undefined): Promise<SupState> {
  const off: SupState = { state: 'off', choices: [] };
  const v = String(vendor ?? '').trim();
  if (!v) return off;
  try {
    const { data: rid, error: re } = await db.rpc('s_inventory_supplier_resolve_v1', { p_property_id: propertyId, p_name: v });
    if (re) { if (!isMissingSchema(re)) console.error('supplier resolve failed', redactForLog(String(re.message ?? re)).slice(0, 160)); return off; }
    const t = await topSuppliers(db, propertyId);
    if (!t) return off;
    if (rid) { const hit = t.list.find((s) => s.id === rid); return hit ? { state: 'matched', supplier_id: hit.id, name: hit.name, choices: [] } : off; }
    return { state: 'pick', choices: t.top };
  } catch (e) {
    console.error('supplier step failed', redactForLog(String((e as any)?.message ?? e)).slice(0, 160));
    return off;
  }
}

/** Resolve a tap code to a supplier; teaches the vendor spelling (R11) or creates the supplier (R10). null = nothing changed. */
export async function pickSupplier(db: any, propertyId: string, choices: Sup[], vendor: string, code: string): Promise<Sup | 'skip' | null> {
  if (code === 's') return 'skip';
  const alias = lowerVendor(vendor);
  try {
    if (code === 'n') {
      const { data, error } = await db.rpc('s_inventory_supplier_create_v1', { p_property_id: propertyId, p_name: vendor.trim().slice(0, 80), p_alias: alias });
      if (error || !data?.ok || !data.supplier_id) return null;
      return { id: data.supplier_id, name: vendor.trim().slice(0, 80) };
    }
    const sup = choices[Number(code)];
    if (!sup) return null;
    const { data, error } = await db.rpc('s_inventory_supplier_alias_v1', { p_supplier_id: sup.id, p_alias: alias });
    if (error || data?.ok === false) return null;
    return sup;
  } catch (e) {
    console.error('supplier pick failed', redactForLog(String((e as any)?.message ?? e)).slice(0, 160));
    return null;
  }
}

/** Apply path: p_supplier_id only when a supplier is known; retries without it if the live function lacks the argument. */
export async function applyPurchase(db: any, it: any, payload: any): Promise<{ data: any; error: any }> {
  const base = { p_item_id: it.item_id, p_qty: it.qty, p_unit_cost: it.unit_price ?? null, p_supplier: payload.vendor ?? null, p_purchased_at: payload.date ?? null, p_txn_id: payload.txnId ?? null };
  const sid = payload.sup?.supplier_id;
  if (!sid) return await db.rpc('apply_inventory_purchase', base);
  const r = await db.rpc('apply_inventory_purchase', { ...base, p_supplier_id: sid });
  return r.error && isMissingSchema(r.error) ? await db.rpc('apply_inventory_purchase', base) : r;
}

/** R12: re-point the purchases made by one Apply. */
export async function changePurchasesSupplier(db: any, ids: string[], supplierId: string | null): Promise<boolean> {
  const { data, error } = await db.rpc('s_inventory_purchase_supplier_set_v1', { p_purchase_ids: ids, p_supplier_id: supplierId });
  return !error && data?.ok === true;
}
