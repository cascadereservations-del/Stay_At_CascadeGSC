// deno test --allow-read supabase/functions/telegram-expense/supplier.test.ts - s86 lane D-tg (SPEC 3.3): supplier on the receipt card.
// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { applyPurchase, buildSupState, changePurchasesSupplier, choiceRow, isMissingSchema, parseCb, pickSupplier, rankSuppliers, renderSyncCard, syncKeyboard, truncVendor } from './supplier.ts';

const PID = '11111111-2222-3333-4444-555555555555';
const SM = { id: 'sm', name: 'SM' }, KCC = { id: 'kcc', name: 'KCC' }, ROB = { id: 'rob', name: 'Robinsons' }, EXTRA = { id: 'x', name: 'Zed' };
const items = [{ item_id: 'i1', item_name: 'Joy Dishwashing', qty: 2, unit_price: 89 }];

// A tiny fake db. `missing` makes the resolver or table answer like an unapplied migration.
function fakeDb(o: { resolve?: string | null; missing?: 'rpc' | 'table'; sups?: any[]; purchases?: any[]; applyRejectsSupplierId?: boolean } = {}) {
  const calls: Array<[string, any]> = [];
  const db = {
    rpc: (name: string, args: any) => {
      calls.push([name, args]);
      if (name === 's_inventory_supplier_resolve_v1') return Promise.resolve(o.missing === 'rpc' ? { data: null, error: { code: 'PGRST202', message: 'no function' } } : { data: o.resolve ?? null, error: null });
      if (name === 's_inventory_supplier_create_v1') return Promise.resolve({ data: { ok: true, supplier_id: 'new1', created: true }, error: null });
      if (name === 's_inventory_supplier_alias_v1') return Promise.resolve({ data: { ok: true }, error: null });
      if (name === 's_inventory_purchase_supplier_set_v1') return Promise.resolve({ data: { ok: true, changed: args.p_purchase_ids.length }, error: null });
      if (name === 'apply_inventory_purchase') return Promise.resolve(o.applyRejectsSupplierId && 'p_supplier_id' in args ? { data: null, error: { code: 'PGRST202', message: 'no such arg' } } : { data: { ok: true, purchase_id: 'p1' }, error: null });
      throw new Error('unexpected rpc ' + name);
    },
    from: (t: string) => {
      const q: any = {
        select: () => q, eq: () => q, not: () => q, order: () => q, limit: () => q,
        then: (res: any) => res(t === 'inventory_suppliers'
          ? (o.missing === 'table' ? { data: null, error: { code: '42P01', message: 'x' } } : { data: o.sups ?? [SM, KCC, ROB, EXTRA], error: null })
          : { data: o.purchases ?? [], error: null }),
      };
      return q;
    },
  };
  return { db, calls };
}

Deno.test('rankSuppliers: most purchases first, max 3, ties by name', () => {
  const r = rankSuppliers([EXTRA, SM, KCC, ROB], ['kcc', 'kcc', 'sm', null, 'rob', 'rob', 'rob']);
  assertEquals(r.map((s) => s.id), ['rob', 'kcc', 'sm']);
  assertEquals(rankSuppliers([EXTRA, SM], []).map((s) => s.id), ['sm', 'x']);
});

Deno.test('card: matched shows one line, no buttons; unmatched shows the not-in-list line and one row', () => {
  const matched = { items, unmatched: ['Foam'], vendor: 'SM SUPERMARKET', sup: { state: 'matched' as const, supplier_id: 'sm', name: 'SM', choices: [] } };
  const t = renderSyncCard(matched);
  assertStringIncludes(t, 'Supplier: SM');
  assertEquals(syncKeyboard(PID, matched.sup, 'SM SUPERMARKET').inline_keyboard.length, 1);

  const pick = { state: 'pick' as const, choices: [SM, KCC] };
  const t2 = renderSyncCard({ items, vendor: 'SM SUPERMARKET GENSAN', sup: pick });
  assertStringIncludes(t2, 'Supplier: not in the list yet ("SM SUPERMARKET GENSAN")');
  const kb = syncKeyboard(PID, pick, 'SM SUPERMARKET GENSAN').inline_keyboard;
  assertEquals(kb.length, 2);
  assertEquals(kb[0].map((b: any) => b.text), ['Is it SM?', 'Is it KCC?', 'New: SM SUPERMARKET GEN...', 'Skip']);
  assertEquals(kb[1].map((b: any) => b.callback_data.split(':')[0]), ['invsync_ok', 'invsync_skip']);
});

Deno.test('card with the step off is exactly the old card', () => {
  const off = { state: 'off' as const, choices: [] };
  const t = renderSyncCard({ items, unmatched: [], vendor: 'SM', sup: off });
  assertFalse(t.includes('Supplier'));
  assertEquals(t, ['📦 *Update inventory?*', '1 item(s) from this receipt match your stock:', '  • Joy Dishwashing  +2'].join('\n'));
  assertEquals(syncKeyboard(PID, off, 'SM').inline_keyboard.length, 1);
});

Deno.test('card text and buttons never carry a price, callback_data stays under 64 bytes', () => {
  const pick = { state: 'pick' as const, choices: [SM, KCC, ROB] };
  const vendor = 'A VERY LONG VENDOR NAME WITH ÑÑÑ AND MORE '.repeat(3);
  const text = renderSyncCard({ items, vendor, sup: pick });
  assertFalse(/₱|PHP|89/.test(text));
  for (const row of [...syncKeyboard(PID, pick, vendor).inline_keyboard, choiceRow('invchs', PID, pick.choices, vendor)])
    for (const b of row) assert(new TextEncoder().encode(b.callback_data).length < 64, b.callback_data);
  assertFalse(JSON.stringify(syncKeyboard(PID, pick, vendor)).includes('VENDOR NAME WITH ÑÑÑ AND MORE A VERY'));
});

Deno.test('parseCb accepts only pending id plus short code', () => {
  assertEquals(parseCb(`invsup:${PID}:2`, 'invsup'), { pid: PID, code: '2' });
  assertEquals(parseCb(`invsup:${PID}:n`, 'invsup'), { pid: PID, code: 'n' });
  assertEquals(parseCb(`invsup:${PID}:9`, 'invsup'), null);
  assertEquals(parseCb(`invchs:${PID}:s`, 'invsup'), null);
});

Deno.test('buildSupState: match, pick (most used first), and off when the vendor is blank', async () => {
  const m = await buildSupState(fakeDb({ resolve: 'sm' }).db, 'prop', 'SM Supermarket');
  assertEquals([m.state, m.supplier_id, m.name], ['matched', 'sm', 'SM']);
  const p = await buildSupState(fakeDb({ purchases: [{ supplier_id: 'rob' }, { supplier_id: 'rob' }, { supplier_id: 'kcc' }] }).db, 'prop', 'Unknown Store');
  assertEquals([p.state, p.choices.map((c) => c.id)], ['pick', ['rob', 'kcc', 'sm']]);
  assertEquals((await buildSupState(fakeDb().db, 'prop', '  ')).state, 'off');
});

Deno.test('buildSupState: SQL not applied yet (missing function or table) behaves like today', async () => {
  assertEquals((await buildSupState(fakeDb({ missing: 'rpc' }).db, 'prop', 'SM')).state, 'off');
  assertEquals((await buildSupState(fakeDb({ missing: 'table' }).db, 'prop', 'SM')).state, 'off');
  for (const c of ['PGRST202', 'PGRST204', '42P01', '42883']) assert(isMissingSchema({ code: c }));
  assertFalse(isMissingSchema({ code: '23505' }));
});

Deno.test('applyPurchase: passes p_supplier_id by name only when known; falls back if the live function lacks it', async () => {
  const a = fakeDb();
  await applyPurchase(a.db, items[0], { vendor: 'SM', date: '2026-10-15', txnId: 't', sup: { state: 'chosen', supplier_id: 'sm' } });
  assertEquals(a.calls[0][1].p_supplier_id, 'sm');
  const b = fakeDb();
  await applyPurchase(b.db, items[0], { vendor: 'SM', txnId: 't', sup: { state: 'off', choices: [] } });
  assertFalse('p_supplier_id' in b.calls[0][1]);
  const c = fakeDb({ applyRejectsSupplierId: true });
  const r = await applyPurchase(c.db, items[0], { vendor: 'SM', txnId: 't', sup: { state: 'chosen', supplier_id: 'sm' } });
  assertEquals(c.calls.length, 2);
  assertFalse('p_supplier_id' in c.calls[1][1]);
  assertEquals(r.data.ok, true);
});

Deno.test('pickSupplier: known teaches the alias (lower-case), New creates with the alias, Skip writes nothing', async () => {
  const a = fakeDb();
  assertEquals(await pickSupplier(a.db, 'prop', [SM, KCC], 'SM SUPERMARKET  GENSAN', '0'), SM);
  assertEquals(a.calls[0], ['s_inventory_supplier_alias_v1', { p_supplier_id: 'sm', p_alias: 'sm supermarket gensan' }]);
  const b = fakeDb();
  assertEquals(await pickSupplier(b.db, 'prop', [], 'Gaisano Mall', 'n'), { id: 'new1', name: 'Gaisano Mall' });
  assertEquals(b.calls[0], ['s_inventory_supplier_create_v1', { p_property_id: 'prop', p_name: 'Gaisano Mall', p_alias: 'gaisano mall' }]);
  const c = fakeDb();
  assertEquals(await pickSupplier(c.db, 'prop', [SM], 'x', 's'), 'skip');
  assertEquals(c.calls.length, 0);
  assertEquals(await pickSupplier(fakeDb().db, 'prop', [SM], 'x', '2'), null); // no such choice
});

Deno.test('changePurchasesSupplier calls R12 with the ids from Apply', async () => {
  const a = fakeDb();
  assert(await changePurchasesSupplier(a.db, ['p1', 'p2'], 'kcc'));
  assertEquals(a.calls[0], ['s_inventory_purchase_supplier_set_v1', { p_purchase_ids: ['p1', 'p2'], p_supplier_id: 'kcc' }]);
});

Deno.test('truncVendor', () => {
  assertEquals(truncVendor('SM SUPERMARKET GENSAN'), 'SM SUPERMARKET GEN...');
  assertEquals(truncVendor('SM'), 'SM');
});

// Wiring: index.ts goes through the module and gates the buttons on the Finance chat (checked on source, no webhook harness exists).
Deno.test('index.ts wiring: Finance-only buttons, apply and change go through supplier.ts', async () => {
  const src = (await Deno.readTextFile(new URL('./index.ts', import.meta.url))).replace(/\r\n/g, '\n');
  assertStringIncludes(src, "isFinanceChat(chatId)?await buildSupState(");
  assertStringIncludes(src, 'await applyPurchase(db,it,payload)');
  assertFalse(src.includes("db.rpc('apply_inventory_purchase'"));
  for (const h of ["data.startsWith('invsup:')", "data.startsWith('invchg:')", "data.startsWith('invchs:')"]) assertStringIncludes(src, h);
  assertEquals(src.split('parseCb(data,').length - 1, 2);
  assertEquals(src.split('||!isFinanceChat(chatId))return;').length - 1, 2);
});
