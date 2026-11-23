// deno test --allow-read telegram-expense/expense-write.test.ts - s134 L3 (D-405): the Telegram expense writes go through two RPCs; the RPCs are faked here (L1 writes the SQL).
import { assert, assertEquals, assertFalse, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  againForVoidedPhoto, bindHoldPrompt, droppedReceipt, HOLD_GONE_LINE, planSave, RECEIPT_LOST_LINE, takeHoldForPrompt, categoryKeyboardFrom, categoryUnion, confirmExpense, FALLBACK_CATEGORIES, keyForMessage, keyForPending, keyForPhoto, lookalikeLine, ocrDate, ocrTxn, onReplayedReceipt, pickableCategories, readableTotal,
  reviewExpense, reviewRefusal, saveExpense, setExpenseAmount, shortDate, SYSTEM_SLUGS, typedTxn, voidExpense, voidMany, writeLineItems,
} from './expense-write.ts';

const PROP = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';

// A fake database whose RPCs behave like the contract: save replays by key, review answers from a table of rows.
function rig(opts: { cats?: string[]; rows?: Record<string, { status: string; locked?: 'bills' | 'pay' }>; throwOn?: string } = {}) {
  const calls: Array<{ fn: string; args: any }> = [];
  const byKey = new Map<string, string>();
  const rows = opts.rows ?? {};
  let n = 0;
  const db = {
    rpc(fn: string, args: any) {
      calls.push({ fn, args });
      if (opts.throwOn === fn) return Promise.reject(new Error('boom'));
      if (fn === 'telegram_expense_save_v1') {
        const cats = opts.cats ?? ['supplies', 'other'];
        if (!cats.includes(args.p_txn.category)) return Promise.resolve({ data: { ok: false, error: 'bad_category' }, error: null });
        const old = byKey.get(args.p_key);
        if (old) return Promise.resolve({ data: { ok: true, id: old, replayed: true, lookalike: null }, error: null });
        const id = `id-${++n}`;
        byKey.set(args.p_key, id);
        return Promise.resolve({ data: { ok: true, id, replayed: false, lookalike: args.p_txn.amount === 1250 ? { id: 'x', date: '2026-11-21', amount: 1250, chip: 'stock' } : null }, error: null });
      }
      const r = rows[args.p_id];
      if (!r) return Promise.resolve({ data: { ok: false, error: 'not_found' }, error: null });
      if (r.locked) return Promise.resolve({ data: { ok: false, error: 'locked', where: r.locked }, error: null });
      if (args.p_action !== 'void' && r.status !== 'pending_review') return Promise.resolve({ data: { ok: false, error: 'not_pending' }, error: null });
      return Promise.resolve({ data: { ok: true }, error: null });
    },
  };
  return { db, calls };
}

const txn = (extra: Record<string, unknown> = {}) => ({ category: 'supplies', amount: 540, payee_name: 'Shop', notes: null, logged_by: 'Lloyd 1', ...extra });

Deno.test('keys: one per message, one per stored question, one per photo; a missing part gives no key', () => {
  assertEquals(keyForMessage(-100123, 77), 'tg:-100123:77');
  assertEquals(keyForPending('abc'), 'tgp:abc');
  assertEquals(keyForPhoto('receipts/5/uniq.jpg'), 'tgocr:receipts/5/uniq.jpg');
  assert(keyForMessage(-100123, 77) !== keyForMessage(-100123, 78), 'a different message is a different key');
  assert(keyForMessage(-100123, 77) !== keyForMessage(-100124, 77), 'a different chat is a different key');
  assert(keyForPhoto('p.jpg') !== keyForPhoto('p.jpg', 'pid1'), 'the "different receipt" tap is its own entry');
  assertEquals([keyForMessage(null, 7), keyForMessage(1, undefined), keyForPending(''), keyForPhoto('')], [null, null, null, null]);
});

Deno.test('save: the key and property go to the RPC; a retry with the same key returns the first id and says replayed', async () => {
  const r = rig();
  const a = await saveExpense(r.db, PROP, txn(), keyForMessage(1, 10));
  const b = await saveExpense(r.db, PROP, txn(), keyForMessage(1, 10));
  const c = await saveExpense(r.db, PROP, txn(), keyForMessage(1, 11));
  assert(a.ok && b.ok && c.ok);
  if (a.ok && b.ok && c.ok) {
    assertEquals([a.id, a.replayed, b.id, b.replayed, c.id], ['id-1', false, 'id-1', true, 'id-2']);
  }
  assertEquals(r.calls[0], { fn: 'telegram_expense_save_v1', args: { p_property_id: PROP, p_txn: txn(), p_key: 'tg:1:10' } });
});

Deno.test('save: an unknown category is refused with a plain message and no id; no key means no call', async () => {
  const r = rig();
  const bad = await saveExpense(r.db, PROP, txn({ category: 'guest_refund' }), keyForMessage(1, 1));
  assertFalse(bad.ok);
  if (!bad.ok) { assertEquals(bad.error, 'bad_category'); assertStringIncludes(bad.message, 'nothing was saved'); assertFalse(/bad_category|error|rpc/i.test(bad.message)); }
  const none = await saveExpense(r.db, PROP, txn(), null);
  assertFalse(none.ok);
  assertEquals(r.calls.length, 1, 'no key, no call');
});

Deno.test('save: an RPC that throws or returns an error saves nothing and says so', async () => {
  const t = await saveExpense(rig({ throwOn: 'telegram_expense_save_v1' }).db, PROP, txn(), 'k');
  assertFalse(t.ok);
  const e = await saveExpense({ rpc: () => Promise.resolve({ data: null, error: { message: 'permission denied' } }) }, PROP, txn(), 'k');
  assertFalse(e.ok);
  const empty = await saveExpense({ rpc: () => Promise.resolve({ data: { ok: true }, error: null }) }, PROP, txn(), 'k');
  assertFalse(empty.ok, 'ok without an id is not a save');
});

Deno.test('save: the OCR row carries the receipt path, the read and the pending status through p_txn', async () => {
  const r = rig();
  const o = txn({ status: 'pending_review', source: 'ocr', receipt_image_path: 'receipts/5/u.jpg', ocr_confidence: 0.9, ocr_raw: { amount: 540 } });
  const out = await saveExpense(r.db, PROP, o, keyForPhoto('receipts/5/u.jpg'));
  assert(out.ok);
  assertEquals(r.calls[0].args.p_key, 'tgocr:receipts/5/u.jpg');
  assertEquals(r.calls[0].args.p_txn.status, 'pending_review');
  assertEquals(r.calls[0].args.p_txn.receipt_image_path, 'receipts/5/u.jpg');
});

Deno.test('look-alike: one extra line with the date and the short reference of the new row', async () => {
  const r = rig();
  const out = await saveExpense(r.db, PROP, txn({ amount: 1250 }), 'k1');
  assert(out.ok);
  if (out.ok) assertEquals(lookalikeLine(out.lookalike, '5EB836FA'), 'Looks like Stock bought 21 Nov. If it is the same purchase: /void 5EB836FA');
  assertEquals(lookalikeLine({ id: 'x', date: '2026-11-03', chip: 'manual' }, 'AB12CD34'), 'Looks like An expense logged 3 Nov. If it is the same purchase: /void AB12CD34');
  assertEquals(lookalikeLine(null, 'AB12CD34'), null);
  assertEquals(lookalikeLine({ chip: 'stock' }, 'AB12CD34'), 'Looks like Stock bought. If it is the same purchase: /void AB12CD34');
  const plain = await saveExpense(r.db, PROP, txn(), 'k2');
  assert(plain.ok && plain.lookalike === null, 'no look-alike, no line');
  assertEquals([shortDate('2026-12-09'), shortDate('nope'), shortDate('2026-13-01')], ['9 Dec', null, null]);
});

Deno.test('void: reason and actor go to the RPC, no note is sent (the RPC keeps the row note), the action is void', async () => {
  const r = rig({ rows: { a: { status: 'confirmed' } } });
  const out = await voidExpense(r.db, 'a', 'Voided via /void', 'Lloyd 1');
  assert(out.ok);
  assertEquals(r.calls[0], { fn: 'telegram_expense_review_v1', args: { p_id: 'a', p_action: 'void', p_payload: { reason: 'Voided via /void' }, p_actor: 'Lloyd 1' } });
  assertFalse('notes' in r.calls[0].args.p_payload);
});

Deno.test('void: a bill or staff-pay row answers where it is undone, and nothing else', async () => {
  const r = rig({ rows: { b: { status: 'confirmed', locked: 'bills' }, p: { status: 'confirmed', locked: 'pay' } } });
  const b = await voidExpense(r.db, 'b', 'x y z', 'A');
  const p = await voidExpense(r.db, 'p', 'x y z', 'A');
  assert(!b.ok && !p.ok);
  if (!b.ok && !p.ok) {
    assertEquals(b.message, 'That one is undone in the app: Bills');
    assertEquals(p.message, 'That one is undone in the app: Pay staff');
    assertEquals([b.error, b.where, p.where], ['locked', 'bills', 'pay']);
  }
  assertEquals(reviewRefusal('locked'), 'That one is undone in the app: Bills / Pay staff');
});

Deno.test('confirm: sends confirm with an empty payload; a row that is no longer pending is refused in plain words', async () => {
  const r = rig({ rows: { a: { status: 'pending_review' }, c: { status: 'confirmed' } } });
  assert((await confirmExpense(r.db, 'a', 'Lloyd 1')).ok);
  assertEquals(r.calls[0].args, { p_id: 'a', p_action: 'confirm', p_payload: {}, p_actor: 'Lloyd 1' });
  const late = await confirmExpense(r.db, 'c', 'Lloyd 1');
  assert(!late.ok);
  if (!late.ok) assertEquals(late.message, 'That receipt is no longer waiting for review.');
});

Deno.test('receipt total edit goes through the review RPC with the amount, not a table update', async () => {
  const r = rig({ rows: { a: { status: 'pending_review' } } });
  assert((await setExpenseAmount(r.db, 'a', 1706.5, 'Lloyd 1')).ok);
  assertEquals(r.calls[0], { fn: 'telegram_expense_review_v1', args: { p_id: 'a', p_action: 'amount', p_payload: { amount: 1706.5 }, p_actor: 'Lloyd 1' } });
  assertEquals(r.calls.length, 1);
});

Deno.test('review: a thrown RPC and an RPC error come back as not-done, never as success', async () => {
  assertFalse((await reviewExpense(rig({ throwOn: 'telegram_expense_review_v1' }).db, 'a', 'void', { reason: 'abc' }, 'x')).ok);
  assertFalse((await reviewExpense({ rpc: () => Promise.resolve({ data: null, error: { message: 'down' } }) }, 'a', 'confirm', {}, 'x')).ok);
  assertFalse((await reviewExpense({ rpc: () => Promise.resolve({ data: null, error: null }) }, 'a', 'confirm', {}, 'x')).ok);
});

Deno.test('voidMany: counts the rows that went through and keeps the first refusal', async () => {
  const r = rig({ rows: { a: { status: 'confirmed' }, b: { status: 'confirmed', locked: 'bills' }, c: { status: 'confirmed' } } });
  const out = await voidMany(r.db, ['a', 'b', 'c'], 'Voided via Telegram NL', 'Lloyd 1');
  assertEquals([out.done, out.total, out.firstFailure], [2, 3, 'That one is undone in the app: Bills']);
  assertEquals((await voidMany(r.db, [], 'abc', 'x')).total, 0);
});

Deno.test('keyboard: built from the list given, two a row, no system slug, callback data cat:<slug>:<pre>', () => {
  const live = [{ slug: 'supplies', label: 'Supplies' }, { slug: 'guest_refund', label: 'Guest refund' }, { slug: 'loan', label: 'Loan' }, { slug: 'airbnb_adjustment', label: 'Airbnb adjustment' }, { slug: 'other', label: 'Other' }];
  assertEquals(pickableCategories(live).map((c) => c.slug), ['supplies', 'loan', 'other']);
  const kb = categoryKeyboardFrom(live, 540);
  const flat = kb.inline_keyboard.flat();
  assertEquals(flat.map((b) => b.callback_data), ['cat:supplies:540', 'cat:loan:540', 'cat:other:540']);
  assertEquals(kb.inline_keyboard.map((r) => r.length), [2, 1]);
  assertEquals(flat[1].text, 'Loan', 'a slug with no icon shows its label alone');
  assertEquals(flat[0].text, '\u{1F6D2} Supplies');
  for (const s of SYSTEM_SLUGS) assertFalse(flat.some((b) => b.callback_data.includes(s)));
  assertEquals(categoryKeyboardFrom([], 0).inline_keyboard.flat().length, FALLBACK_CATEGORIES.length, 'an unreadable list falls back to the seven');
});

Deno.test('OCR prompt list: the live slugs minus the system ones, odd slugs dropped, fallback when empty', () => {
  assertEquals(categoryUnion(['supplies', 'guest_refund', 'Bad Slug', 'loan']), '"supplies"|"loan"');
  assertEquals(categoryUnion([]), '"supplies"|"utilities"|"cleaning"|"maintenance"|"repairs"|"platform_fees"|"other"');
});

Deno.test('index.ts: no direct transactions write is left except the cleaner fee, the refund and the OCR line items', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  const writes: string[] = [];
  for (const m of src.matchAll(/from\('transactions'\)\s*\.(\w+)/g)) {
    if (m[1] === 'select') continue;
    const tail = src.slice(m.index!, m.index! + 700);
    writes.push(tail.includes("source:'cleaner_fee'") ? 'cleaner_fee' : tail.includes("category:         'guest_refund'") ? 'refund' : 'OTHER:' + tail.slice(0, 80));
  }
  assertEquals(writes.filter((f) => f.startsWith('OTHER')), [], 'every other write goes through the RPCs');
  assertEquals([...writes].sort(), ['cleaner_fee', 'refund']); // s134 fix r1: the line-items update moved to writeLineItems (expense-write.ts), which guards on status
  assertFalse(/status:'void'|status:'confirmed',updated_at|gross_amount:amount,updated_at/.test(src), 'no table update of status or amount remains');
  assertStringIncludes(src, "from './expense-write.ts'");
  assertFalse(/\bcategoryKeyboard\(\s*[0-9a-z]+\s*\)/.test(src.replace(/categoryKeyboard\(db,/g, '')), 'every keyboard call passes the db');
});

Deno.test('expense-write.ts: its only direct transactions write is the status-guarded line-items update', async () => {
  const src = await Deno.readTextFile(new URL('./expense-write.ts', import.meta.url));
  const writes = [...src.matchAll(/from\('transactions'\)\s*\.(\w+)/g)].filter((m) => m[1] !== 'select');
  assertEquals(writes.length, 1, 'exactly one direct write');
  assertEquals(writes[0][1], 'update');
  assertStringIncludes(src.slice(writes[0].index!, writes[0].index! + 200), ".eq('status', 'pending_review')");
});

Deno.test('index.ts wiring: keys per flow, the look-alike line, review calls, and the replay does not notify twice', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, 'key:keyForMessage(chatId,msg.message_id)');
  assertEquals(src.split('key:keyForMessage(chatId,msg.message_id)').length - 1, 3, 'the fast-entry text, the answered prompt and the answered prompt of a held receipt photo');
  assertStringIncludes(src, "key:keyForPending(data.slice('dup_ok:'.length))");
  assertStringIncludes(src, "key:keyForPending(data.slice('llm_expense_confirm:'.length))");
  assertStringIncludes(src, 'keyForPhoto(objectPath,again)');
  assertStringIncludes(src, "'Voided via /void'");
  assertStringIncludes(src, "'Discarded via Telegram'");
  assertStringIncludes(src, 'confirmExpense(db,txnId,whoFrom(cq.from))');
  assertStringIncludes(src, 'setExpenseAmount(db,String(p.txnId),amount,loggedBy)');
  assertStringIncludes(src, 'if(!r.replayed)notifyOps(');
  assertEquals(src.split('row.id,row.look)').length - 1, 3, 'the three confirmations carry the look-alike line (the held-receipt answer now goes through validateAndInsert, r3)');
  assert(src.includes('Looks like') === false, 'the sentence itself lives in expense-write.ts');
});

// ---- s134 fix round 1 ----

// A table of rows that honours eq / limit / update / maybeSingle, so the status guards are exercised for real.
function table(rows: Array<Record<string, any>>) {
  return {
    from: (_t: string) => {
      const filters: Array<[string, unknown]> = [];
      let patch: Record<string, unknown> | null = null;
      const match = () => rows.filter((r) => filters.every(([c, v]) => r[c] === v));
      // deno-lint-ignore no-explicit-any
      const b: any = {
        select: () => b, limit: () => b,
        eq: (c: string, v: unknown) => { filters.push([c, v]); return b; },
        update: (p: Record<string, unknown>) => { patch = p; return b; },
        maybeSingle: () => Promise.resolve({ data: match()[0] ?? null, error: null }),
        then: (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) => {
          if (patch) { for (const r of match()) Object.assign(r, patch); return Promise.resolve({ error: null }).then(res, rej); }
          return Promise.resolve({ data: match(), error: null }).then(res, rej);
        },
      };
      return b;
    },
  };
}

Deno.test('fix r1 (1): a photo sent again after its receipt was discarded gets a new key, so a new pending row and card appear', async () => {
  const path = 'receipts/-100/AgADu1.jpg';
  const voided = table([{ id: 'old', receipt_image_path: path, status: 'void' }]);
  const again = await againForVoidedPhoto(voided, path, 4412);
  assertEquals(again, 'm4412');
  assert(keyForPhoto(path, again) !== keyForPhoto(path, null), 'a different key from the voided first pass');
  assertEquals(keyForPhoto(path, again), keyForPhoto(path, await againForVoidedPhoto(voided, path, 4412)), 'a webhook retry of the same message keeps the same key');
  // the real save: the first key replays, the new key makes a new row
  const r = rig();
  const first = await saveExpense(r.db, PROP, txn({ amount: 100 }), keyForPhoto(path, null));
  const resendOld = await saveExpense(r.db, PROP, txn({ amount: 100 }), keyForPhoto(path, null));
  const resend = await saveExpense(r.db, PROP, txn({ amount: 100 }), keyForPhoto(path, again));
  assert(first.ok && resendOld.ok && resend.ok);
  if (first.ok && resendOld.ok && resend.ok) {
    assertEquals([resendOld.replayed, resendOld.id === first.id], [true, true]);
    assertEquals([resend.replayed, resend.id === first.id], [false, false]);
  }
  // no void row holds the path (a first send, or a live row): the plain key is kept
  assertEquals(await againForVoidedPhoto(table([{ id: 'x', receipt_image_path: path, status: 'pending_review' }]), path, 4412), null);
  assertEquals(await againForVoidedPhoto(table([]), path, 4412), null);
  assertEquals(await againForVoidedPhoto(voided, path, null), null);
});

Deno.test('fix r1 (1): a replay of a row that is no longer waiting sends one plain line, never silence; a waiting row still gets its card', async () => {
  const db = table([{ id: 'c1', status: 'confirmed' }, { id: 'p1', status: 'pending_review' }, { id: 'v1', status: 'void' }]);
  const out: string[] = [], cards: string[] = [];
  const deps = {
    loadPending: async (id: string) => (await db.from('transactions').select('id').eq('id', id).eq('status', 'pending_review').maybeSingle()).data,
    sendCard: async (id: string) => { cards.push(id); }, send: async (t: string) => { out.push(t); },
  };
  await onReplayedReceipt(db, 'c1', 'C1REF', deps);
  await onReplayedReceipt(db, 'v1', 'V1REF', deps);
  await onReplayedReceipt(db, 'p1', 'P1REF', deps);
  assertEquals(out, ['That receipt was already logged as Ref C1REF and is now confirmed.', 'That receipt was already logged as Ref V1REF and is now void.']);
  assertEquals(cards, ['p1']);
});

Deno.test('fix r1 (1): index.ts wires the resend key and the replay line into the photo path and runOcr', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, 'againForVoidedPhoto(db,objectPath,msg.message_id)');
  assertStringIncludes(src, 'msg.caption?String(msg.caption).trim():null,cat,again)');
  assertStringIncludes(src, 'onReplayedReceipt(db,txnId,shortRef(txnId)');
});

Deno.test('fix r1 (2): line items change only on a row still pending review; a confirmed row is left alone', async () => {
  const rows = [
    { id: 'p', status: 'pending_review', ocr_raw: { line_items: [{ name: 'a' }], vendor: 'V' } },
    { id: 'c', status: 'confirmed', ocr_raw: { line_items: [{ name: 'a' }], vendor: 'V' } },
  ];
  const db = table(rows);
  await writeLineItems(db, 'p', rows[0].ocr_raw, [{ name: 'a' }, { name: 'b' }]);
  await writeLineItems(db, 'c', rows[1].ocr_raw, [{ name: 'a' }, { name: 'b' }]);
  assertEquals(rows[0].ocr_raw, { line_items: [{ name: 'a' }, { name: 'b' }], vendor: 'V' });
  assertEquals(rows[1].ocr_raw, { line_items: [{ name: 'a' }], vendor: 'V' });
  assertEquals((rows[1] as any).updated_at, undefined, 'the confirmed row was not touched at all');
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, 'await writeLineItems(db,txnId,ocrRaw,items)');
});

// ---- s134 fix round 2 ----

Deno.test('fix r2 (1): the vendor goes to the RPC as payee_name, for a typed /log and for a receipt photo; no payee key is sent', async () => {
  const r = rig();
  await saveExpense(r.db, PROP, typedTxn({ category: 'supplies', amount: 250, payee: 'Demo shop', notes: '250 Demo shop', loggedBy: 'Lloyd 1' }), 'k-typed');
  await saveExpense(r.db, PROP, ocrTxn({ category: 'supplies', amount: 540, vendor: 'Demo store', notes: null, loggedBy: 'Lloyd 1', receipt: 'receipts/5/u.jpg', confidence: 0.9, raw: { amount: 540 }, date: null }), keyForPhoto('receipts/5/u.jpg'));
  assertEquals(r.calls[0].args.p_txn.payee_name, 'Demo shop');
  assertEquals(r.calls[1].args.p_txn.payee_name, 'Demo store');
  for (const c of r.calls) assertFalse('payee' in c.args.p_txn, 'the RPC does not read payee');
  assertEquals(typedTxn({ category: 'other', amount: 1 }).payee_name, null);
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertFalse(/saveExpense\([^)]*\{[^}]*payee\s*:/.test(src), 'index.ts builds no p_txn with a payee key');
  assertStringIncludes(src, 'typedTxn({');
  assertStringIncludes(src, 'ocrTxn({');
});

Deno.test('fix r2 (2): a total that is 0, missing or not a number is not saved; a readable one is', () => {
  assertEquals([readableTotal(0), readableTotal(null), readableTotal(undefined), readableTotal(''), readableTotal('abc'), readableTotal(-5), readableTotal(NaN)], [null, null, null, null, null, null, null]);
  assertEquals([readableTotal(540), readableTotal('1,706'), readableTotal('1706.5')], [540, null, 1706.5]);
});

Deno.test('fix r2 (2): amount 0 -> no save call, the category prompt (pre 0, receipt held) is shown; answering the amount saves one row with the receipt path', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  // wiring: the unreadable-total branch comes before the OCR save and holds the photo
  const iGuard = src.indexOf('readableTotal(extracted.amount)===null');
  const iSave = src.indexOf('saveExpense(db,PROPERTY_ID,ocrTxn(');
  assert(iGuard > 0 && iSave > iGuard, 'the guard sits before the OCR save');
  assertStringIncludes(src.slice(iGuard, iSave), 'categoryKeyboard(db,0,true)');
  assertStringIncludes(src.slice(iGuard, iSave), "'photo_dup',{hold:true,objectPath");
  // the keyboard carries the hold flag; the plain keyboard does not
  const held = categoryKeyboardFrom([{ slug: 'supplies', label: 'Supplies' }, { slug: 'other', label: 'Other' }], 0, true).inline_keyboard.flat();
  assertEquals(held.map((b) => b.callback_data), ['cat:supplies:0:h', 'cat:other:0:h']);
  assert(held.every((b) => b.callback_data.length <= 64));
  assertEquals(categoryKeyboardFrom([{ slug: 'other', label: 'Other' }], 0).inline_keyboard.flat()[0].callback_data, 'cat:other:0');
  // the answer: one save, carrying the receipt path, the typed amount and the vendor as payee_name
  const r = rig();
  const out = await saveExpense(r.db, PROP, typedTxn({ category: 'supplies', amount: 1706, payee: 'Demo shop', notes: 'items: a | Demo shop', loggedBy: 'Lloyd 1', receipt: 'receipts/5/u.jpg' }), keyForMessage(-100, 91));
  assert(out.ok);
  assertEquals(r.calls.length, 1);
  assertEquals(r.calls[0].args.p_txn, { category: 'supplies', amount: 1706, payee_name: 'Demo shop', notes: 'items: a | Demo shop', logged_by: 'Lloyd 1', receipt_image_path: 'receipts/5/u.jpg' });
  assertStringIncludes(src, 'receipt:String(r.objectPath)');
  assertStringIncludes(src, "holdFlag==='h'");
});

Deno.test('fix r2 (3): the receipt date is kept up to Manila tomorrow and dropped after it (boundary at 23:30 and 00:30 Manila)', () => {
  // 2026-11-23 23:30 Manila = 15:30Z; 2026-11-24 00:30 Manila = 16:30Z on the 23rd
  const a = Date.parse('2026-11-23T15:30:00Z'), b = Date.parse('2026-11-23T16:30:00Z');
  assertEquals([ocrDate('2026-11-23', a), ocrDate('2026-11-24', a), ocrDate('2026-11-25', a)], ['2026-11-23', '2026-11-24', null]);
  assertEquals([ocrDate('2026-11-24', b), ocrDate('2026-11-25', b), ocrDate('2026-11-26', b)], ['2026-11-24', '2026-11-25', null]);
  assertEquals([ocrDate('2019-12-31', a), ocrDate('nope', a), ocrDate(null, a), ocrDate('2026-02-30', a)], [null, null, null, null]);
  const kept = ocrTxn({ category: 'other', amount: 1, vendor: null, notes: null, loggedBy: null, receipt: 'p', confidence: 1, raw: {}, date: ocrDate('2026-11-24', a) });
  const dropped = ocrTxn({ category: 'other', amount: 1, vendor: null, notes: null, loggedBy: null, receipt: 'p', confidence: 1, raw: {}, date: ocrDate('2026-11-25', a) });
  assertEquals(kept.transaction_date, '2026-11-24');
  assertFalse('transaction_date' in dropped, 'the RPC then uses Manila today and the save is kept');
});

// ---- s134 fix round 3 ----

// A telegram_pending table that honours delete / eq (including payload->>key paths) / select / maybeSingle, delete-returning.
function pendingTable(rows: Array<Record<string, any>>) {
  const val = (r: Record<string, any>, c: string) => (c.startsWith('payload->>') ? (r.payload?.[c.slice(10)] == null ? null : String(r.payload[c.slice(10)])) : r[c]);
  return {
    from: (_t: string) => {
      const filters: Array<[string, unknown]> = [];
      let op: 'select' | 'delete' | 'update' = 'select';
      let patch: Record<string, unknown> | null = null;
      const match = () => rows.filter((r) => filters.every(([c, v]) => val(r, c) === v || String(val(r, c)) === String(v)));
      const run = () => {
        const m = match();
        if (op === 'delete') for (const r of m) rows.splice(rows.indexOf(r), 1);
        if (op === 'update' && patch) for (const r of m) Object.assign(r, patch);
        return m;
      };
      // deno-lint-ignore no-explicit-any
      const b: any = {
        select: () => b,
        delete: () => { op = 'delete'; return b; },
        update: (p: Record<string, unknown>) => { op = 'update'; patch = p; return b; },
        eq: (c: string, v: unknown) => { filters.push([c, v]); return b; },
        maybeSingle: () => Promise.resolve({ data: run()[0] ?? null, error: null }),
        then: (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) => Promise.resolve({ data: run(), error: null }).then(res, rej),
      };
      return b;
    },
  };
}
const future = () => new Date(Date.now() + 3_600_000).toISOString();
const holdRow = (id: string, objectPath: string, mid?: unknown) => ({ id, chat_id: -100, kind: 'photo_dup', expires_at: future(), payload: { hold: true, objectPath, loggedBy: 'Lloyd 1', notes: null, ...(mid != null ? { prompt_mid: mid } : {}) } });

Deno.test('fix r3 (1): two holds, each bound to its own keyboard: the older keyboard gets the older photo, the newer the newer, a second tap gets nothing', async () => {
  const rows: Array<Record<string, any>> = [holdRow('h1', 'receipts/-100/old.jpg'), holdRow('h2', 'receipts/-100/new.jpg')];
  const db = pendingTable(rows);
  // runOcr: after each keyboard is sent, its message id is stored on its own hold row
  assert(await bindHoldPrompt(db, 'h1', rows[0].payload, 501));
  assert(await bindHoldPrompt(db, 'h2', rows[1].payload, 502));
  assertEquals(rows.map((r) => r.payload.prompt_mid), [501, 502]);
  assertFalse(await bindHoldPrompt(db, 'h1', rows[0].payload, undefined), 'no message id: nothing bound');
  // tap on the OLDER keyboard (501): the older photo, not the newest hold
  assertEquals((await takeHoldForPrompt(db, -100, 501))?.objectPath, 'receipts/-100/old.jpg');
  assertEquals(rows.length, 1, 'consumed by delete-returning');
  // a second tap on the same keyboard: nothing, and the other hold is untouched
  assertEquals(await takeHoldForPrompt(db, -100, 501), null);
  assertEquals(rows.length, 1);
  // tap on the newer keyboard: the newer photo
  assertEquals((await takeHoldForPrompt(db, -100, 502))?.objectPath, 'receipts/-100/new.jpg');
  assertEquals(rows.length, 0);
  assertEquals(HOLD_GONE_LINE, 'That receipt is no longer waiting. Send it again.');
  // another chat, an unbound hold and an expired hold are never taken
  const other = [holdRow('x', 'p1', 7), { ...holdRow('y', 'p2', 8), expires_at: new Date(Date.now() - 1000).toISOString() }, holdRow('z', 'p3')];
  const odb = pendingTable(other);
  assertEquals(await takeHoldForPrompt(odb, -999, 7), null);
  assertEquals(await takeHoldForPrompt(odb, -100, 8), null, 'expired');
  assertEquals(await takeHoldForPrompt(odb, -100, 9), null, 'a hold with no prompt id matches no tap');
});

Deno.test('fix r3 (1): index.ts wiring - the hold is bound after the keyboard is sent, and the tap looks it up by the callback message id', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, 'bindHoldPrompt(db,hid,{hold:true,objectPath,loggedBy,notes:notesText},kr?.result?.message_id)');
  assertStringIncludes(src, 'receipt=await takeHoldForPrompt(db,chatId,msgId)');
  assertStringIncludes(src, 'tgSend(chatId,HOLD_GONE_LINE)');
  assertFalse(src.includes("order('expires_at',{ascending:false}).limit(1).maybeSingle();receipt="), 'no newest-hold lookup is left');
});

Deno.test('fix r3: callback data of the hold keyboard stays within 64 bytes for the longest live slug', () => {
  const longest = 'x'.repeat(40); // slugs are 1-40 chars of [a-z0-9_] (categoryUnion)
  const kb = categoryKeyboardFrom([{ slug: longest, label: 'L' }, ...FALLBACK_CATEGORIES], 123456789, true).inline_keyboard.flat();
  for (const b of kb) assert(new TextEncoder().encode(b.callback_data).length <= 64, b.callback_data);
  assertEquals(new TextEncoder().encode(kb[0].callback_data).length, 4 + 40 + 1 + 9 + 2);
});

const LIM = { large: 10_000, recentMin: 500 };

Deno.test('fix r3 (2): a held answer over the large-amount threshold asks first; confirming saves one row that carries the receipt', async () => {
  const opts = { category: 'supplies', amount: 12_500, label: 'Supplies', payee: 'Demo shop', notes: 'a | Demo shop', loggedBy: 'Lloyd 1', receipt: 'receipts/-100/u.jpg' };
  const plan = planSave(opts, [], '2026-11-23', LIM);
  assertEquals(plan.kind, 'large');
  assertEquals(plan.payload.receipt, 'receipts/-100/u.jpg');
  const r = rig();
  assertEquals(r.calls.length, 0, 'nothing saved before the confirm');
  // the confirm tap: the stored payload goes back through typedTxn (insertExpense) with the pending key
  // deno-lint-ignore no-explicit-any
  const p = plan.payload as any;
  const out = await saveExpense(r.db, PROP, typedTxn({ category: p.category, amount: p.amount, payee: p.payee, notes: p.notes, loggedBy: p.loggedBy, receipt: p.receipt }), keyForPending('pid-1'));
  assert(out.ok);
  assertEquals(r.calls.length, 1);
  assertEquals(r.calls[0].args.p_txn.receipt_image_path, 'receipts/-100/u.jpg');
  assertEquals(r.calls[0].args.p_txn.amount, 12_500);
});

Deno.test('fix r3 (2): a held answer with a same-day same-category amount, or a similar recent one, asks first and keeps the receipt; a plain one saves', () => {
  const o = { category: 'supplies', amount: 700, receipt: 'receipts/-100/u.jpg' };
  const today = planSave(o, [{ id: 'a', category: 'supplies', transaction_date: '2026-11-23' }], '2026-11-23', LIM);
  assertEquals([today.kind, today.dupe?.id, today.payload.receipt], ['duplicate_today', 'a', 'receipts/-100/u.jpg']);
  const recent = planSave(o, [{ id: 'b', category: 'utilities', transaction_date: '2026-11-20' }], '2026-11-23', LIM);
  assertEquals([recent.kind, recent.dupe?.id, recent.payload.receipt], ['duplicate_recent', 'b', 'receipts/-100/u.jpg']);
  assertEquals(planSave({ category: 'supplies', amount: 300 }, [{ id: 'c', category: 'x', transaction_date: '2026-11-20' }], '2026-11-23', LIM).kind, 'save', 'under the recent floor');
  assertEquals(planSave(o, [], '2026-11-23', LIM).kind, 'save');
  assertFalse('receipt' in planSave({ category: 'supplies', amount: 12_000 }, [], '2026-11-23', LIM).payload, 'a typed /log carries no receipt key');
});

Deno.test('fix r3 (2): index.ts wiring - the held answer goes through validateAndInsert; every pending payload comes from planSave', async () => {
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, "await validateAndInsert(db,chatId,{category:String(p.slug),amount:a.amount,label,payee:a.vendor,notes:[r.notes,a.vendor].filter(Boolean).join(' | ')||null,loggedBy:r.loggedBy??loggedBy,key:keyForMessage(chatId,msg.message_id),receipt:String(r.objectPath)})");
  assertStringIncludes(src, "createPending(db,chatId,'large_amount',plan.payload)");
  assertEquals(src.split("createPending(db,chatId,'duplicate',plan.payload)").length - 1, 2);
  assertFalse(src.includes("createPending(db,chatId,'duplicate',{amount"), 'no payload that forgets the receipt');
});

Deno.test('fix r3 (2): a new question that replaces an open answer carrying a receipt says so; one without a receipt stays silent', async () => {
  const rows = [
    { id: 'a1', chat_id: -100, kind: 'awaiting_reply', payload: { flow: 'expense', from_id: 5, receipt: { objectPath: 'p' } } },
    { id: 'a2', chat_id: -100, kind: 'awaiting_reply', payload: { flow: 'expense', from_id: 6 } },
  ];
  const db = pendingTable(rows);
  // the same delete awaiting() runs: returning the dropped rows
  const gone5 = (await db.from('telegram_pending').delete().eq('chat_id', -100).eq('kind', 'awaiting_reply').eq('payload->>from_id', '5').select('payload')).data;
  assert(droppedReceipt(gone5));
  const gone6 = (await db.from('telegram_pending').delete().eq('chat_id', -100).eq('kind', 'awaiting_reply').eq('payload->>from_id', '6').select('payload')).data;
  assertFalse(droppedReceipt(gone6));
  assertFalse(droppedReceipt(null));
  assertEquals(RECEIPT_LOST_LINE, 'The receipt you sent earlier was not saved. Send it again.');
  const src = await Deno.readTextFile(new URL('./index.ts', import.meta.url));
  assertStringIncludes(src, 'if(droppedReceipt(gone))await tgSend(chatId,RECEIPT_LOST_LINE)');
});
