// A tiny in-memory stand-in for the Supabase client, for tests only (never imported by a deployed function).
// Supports the calls power-watch, brownout.ts and the card taps make: select / insert / update / upsert / delete with
// eq, neq, gt, gte, in, like, order, limit, single, maybeSingle.
// deno-lint-ignore-file no-explicit-any
type Row = Record<string, any>;
type Result = { data: any; error: null | { message: string; code?: string } };
const GENERATED: Record<string, string[]> = { calendar_events: ['nights'] };

class Query implements PromiseLike<Result> {
  private op: 'select' | 'insert' | 'update' | 'upsert' | 'delete' = 'select';
  private payload: any; private conflict = ''; private returning = false;
  private tests: Array<(r: Row) => boolean> = [];
  private lim = Infinity; private one: 'single' | 'maybe' | null = null;
  constructor(private db: FakeDb, private table: string) {}

  select(_cols?: string) { this.returning = true; return this; }
  insert(p: Row | Row[]) { this.op = 'insert'; this.payload = p; return this; }
  update(p: Row) { this.op = 'update'; this.payload = p; return this; }
  upsert(p: Row | Row[], o?: { onConflict?: string }) { this.op = 'upsert'; this.payload = p; this.conflict = o?.onConflict ?? ''; return this; }
  delete() { this.op = 'delete'; return this; }
  eq(c: string, v: any) { this.tests.push((r) => r[c] === v); return this; }
  neq(c: string, v: any) { this.tests.push((r) => r[c] !== v); return this; }
  gt(c: string, v: any) { this.tests.push((r) => r[c] > v); return this; }
  gte(c: string, v: any) { this.tests.push((r) => r[c] >= v); return this; }
  in(c: string, vs: any[]) { this.tests.push((r) => vs.includes(r[c])); return this; }
  like(c: string, pat: string) { const re = new RegExp('^' + pat.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/%/g, '.*') + '$'); this.tests.push((r) => re.test(String(r[c]))); return this; }
  order(_c?: string) { return this; }
  limit(n: number) { this.lim = n; return this; }
  single() { this.one = 'single'; return this; }
  maybeSingle() { this.one = 'maybe'; return this; }

  private run(): Result {
    const rows = this.db.tables[this.table] ??= [];
    // Production refuses writes to generated columns (calendar_events.nights, 2026-10-02 first live run); so does the fake.
    const generated = GENERATED[this.table] ?? [];
    if (this.op !== 'select' && this.op !== 'delete') {
      const bad = ([] as Row[]).concat(this.payload).flatMap((p) => generated.filter((c) => c in p));
      if (bad.length) return { data: null, error: { message: `cannot insert a non-DEFAULT value into column "${bad[0]}"`, code: '428C9' } };
    }
    const match = (r: Row) => this.tests.every((t) => t(r));
    let out: Row[] = [];
    if (this.op === 'select') out = rows.filter(match).slice(0, this.lim);
    else if (this.op === 'insert') {
      for (const p of ([] as Row[]).concat(this.payload)) { const r = { id: crypto.randomUUID(), ...(this.table === 'ops_notices' ? { is_active: true } : {}), ...p }; rows.push(r); out.push(r); }
    } else if (this.op === 'upsert') {
      const keys = this.conflict.split(',').map((k) => k.trim()).filter(Boolean);
      for (const p of ([] as Row[]).concat(this.payload)) {
        const hit = keys.length ? rows.find((r) => keys.every((k) => r[k] === p[k])) : undefined;
        if (hit) { Object.assign(hit, p); out.push(hit); } else { const r = { id: crypto.randomUUID(), ...p }; rows.push(r); out.push(r); }
      }
    } else if (this.op === 'update') {
      for (const r of rows.filter(match)) { Object.assign(r, this.payload); out.push(r); }
    } else {
      for (const r of rows.filter(match)) { rows.splice(rows.indexOf(r), 1); out.push(r); }
    }
    if (this.one === 'single') return out.length === 1 ? { data: out[0], error: null } : { data: null, error: { message: `expected one row, got ${out.length}` } };
    if (this.one === 'maybe') return { data: out[0] ?? null, error: null };
    return { data: this.returning || this.op === 'select' ? out : null, error: null };
  }
  then<A = Result, B = never>(ok?: ((v: Result) => A | PromiseLike<A>) | null, bad?: ((e: unknown) => B | PromiseLike<B>) | null) {
    return Promise.resolve().then(() => this.run()).then(ok, bad);
  }
}

export class FakeDb {
  tables: Record<string, Row[]>;
  constructor(tables: Record<string, Row[]> = {}) { this.tables = tables; }
  from(name: string) { return new Query(this, name); }
  rpc(_name: string, _args: unknown) { return Promise.resolve({ data: null, error: { code: 'PGRST202', message: 'Could not find the function' } }); }
}
