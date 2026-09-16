// cascade-core tools (Cassy, 2026-09-13, D-104). Read-only registry over existing data.
// Every tool is a declaration the model sees plus a function that returns rows. No tool writes.
// Stays are read from the two booking tables directly: `admin_stays_v1` and the metrics RPCs grant
// EXECUTE only to `authenticated`, so the service role is refused (live probe, 2026-09-13 14:00Z).
// The union below mirrors admin_stays_v1: Airbnb accommodation = gross_earnings - cleaning_fee when
// the transactions row exists, else host_payout + host_service_fee; direct = quoted total_amount.
import type { ToolDecl } from './providers.ts';

export const PROPERTY_ID = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
export const manilaToday = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });
const addDays = (ymd: string, n: number) => { const d = new Date(ymd + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const isYmd = (s: unknown): s is string => typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s);

type Stay = { stay_kind: string; code: string; guest_name: string | null; checkin: string; checkout: string; nights: number; status: string; accommodation_total: number | null };

const num = (v: unknown) => (v == null || v === '' ? null : Number(v));
const nightsOf = (a: string, b: string) => Math.max(0, Math.round((Date.parse(b) - Date.parse(a)) / 86_400_000));

async function stays(db: any, from: string, to: string): Promise<Stay[]> {
  const [air, direct] = await Promise.all([
    db.from('airbnb_reservations').select('confirmation_code,guest_name,checkin_date,checkout_date,status,host_payout,host_service_fee')
      .eq('property_id', PROPERTY_ID).neq('status', 'cancelled').gt('checkout_date', from).lte('checkin_date', to),
    db.from('booking_inquiries').select('id,guest_name,checkin_date,checkout_date,status,total_amount')
      .eq('property_id', PROPERTY_ID).in('status', ['confirmed', 'completed']).gt('checkout_date', from).lte('checkin_date', to),
  ]);
  if (air.error) throw new Error(`airbnb_reservations: ${air.error.message}`);
  if (direct.error) throw new Error(`booking_inquiries: ${direct.error.message}`);
  const codes = (air.data ?? []).map((r: any) => r.confirmation_code).filter(Boolean);
  const tx = codes.length
    ? await db.from('airbnb_transactions').select('confirmation_code,gross_earnings,cleaning_fee').eq('property_id', PROPERTY_ID).eq('row_type', 'reservation').in('confirmation_code', codes)
    : { data: [] };
  const gross = new Map<string, { g: number; c: number }>();
  for (const t of (tx.data ?? []) as any[]) {
    const cur = gross.get(t.confirmation_code) ?? { g: 0, c: 0 };
    gross.set(t.confirmation_code, { g: Math.max(cur.g, num(t.gross_earnings) ?? 0), c: Math.max(cur.c, num(t.cleaning_fee) ?? 0) });
  }
  const rows: Stay[] = [
    ...((air.data ?? []) as any[]).map((r): Stay => {
      const g = gross.get(r.confirmation_code);
      const total = g ? Math.round((g.g - g.c) * 100) / 100 : (num(r.host_payout) != null ? Math.round(((num(r.host_payout) ?? 0) + (num(r.host_service_fee) ?? 0)) * 100) / 100 : null);
      return { stay_kind: 'airbnb', code: r.confirmation_code, guest_name: r.guest_name, checkin: r.checkin_date, checkout: r.checkout_date, nights: nightsOf(r.checkin_date, r.checkout_date), status: r.status, accommodation_total: total };
    }),
    ...((direct.data ?? []) as any[]).map((i): Stay => ({ stay_kind: 'direct', code: 'DIR-' + String(i.id).slice(0, 8).toUpperCase(), guest_name: i.guest_name, checkin: i.checkin_date, checkout: i.checkout_date, nights: nightsOf(i.checkin_date, i.checkout_date), status: i.status, accommodation_total: num(i.total_amount) })),
  ];
  return rows.sort((a, b) => a.checkin.localeCompare(b.checkin));
}

/** Nights of `s` that fall inside [from, to) and the revenue share for them (accommodation_total / nights per night). */
export function nightsIn(s: { checkin: string; checkout: string; nights: number; accommodation_total: number | null }, from: string, to: string): { nights: number; revenue: number | null } {
  const start = s.checkin > from ? s.checkin : from;
  const end = s.checkout < to ? s.checkout : to;
  const n = Math.max(0, Math.round((Date.parse(end) - Date.parse(start)) / 86_400_000));
  const perNight = s.accommodation_total != null && s.nights > 0 ? Number(s.accommodation_total) / s.nights : null;
  return { nights: n, revenue: perNight == null ? null : Math.round(perNight * n) };
}

export const TOOL_DECLS: ToolDecl[] = [
  { name: 'stays', description: 'Arrivals, departures and in-house guests between two dates (default: today to 7 days ahead). Returns each stay with guest name, check-in, check-out, nights, status and quoted accommodation total.',
    parameters: { type: 'object', properties: { from: { type: 'string', description: 'YYYY-MM-DD, default today' }, to: { type: 'string', description: 'YYYY-MM-DD, default from + 7 days' } } } },
  { name: 'period_metrics', description: 'Occupancy and accommodation revenue for a date range (default: this month to date). Returns nights sold, nights available, occupancy percent, revenue in PHP, stays counted and how many stays have no revenue figure.',
    parameters: { type: 'object', properties: { from: { type: 'string', description: 'YYYY-MM-DD inclusive' }, to: { type: 'string', description: 'YYYY-MM-DD exclusive' } } } },
  { name: 'low_stock', description: 'Inventory items at or below their reorder point, with quantity, unit and reorder point. Also reports how many active items have no reorder point set.',
    parameters: { type: 'object', properties: {} } },
  { name: 'inventory_report', description: 'Full consumables list with quantity on hand, unit, and days of coverage (measured usage history if available, else an estimate). Use for a general stock check, not just a low-stock alert.',
    parameters: { type: 'object', properties: {} } },
  { name: 'guest_history', description: 'What we know about one guest by name: stays so far, last stay dates, any [URGENT] issue the cleaner logged after their last stay, stay preferences, tags, VIP reason, host note, birthday and open follow-ups. Only fields with data are returned.',
    parameters: { type: 'object', required: ['name'], properties: { name: { type: 'string', description: 'Guest name or its first words' } } } },
];

// ── Guest context (Telegram plan §1, session 26). One RPC (guest_context_v1, security definer:
// guest_profile_details is revoked from service_role) shared by the booking cards and Cassy.
export type GuestContext = {
  found: boolean; guest_id?: string; name?: string; tier?: string | null; total_stays?: number; total_nights?: number;
  first_stay?: string; last_stay_checkin?: string; last_stay_checkout?: string; last_issue?: string; last_issue_on?: string;
  preferences?: string; tags?: string[]; vip_reason?: string; note?: string; birthday?: string; open_follow_ups?: string[];
};
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const dm = (d?: string | null) => { if (!d) return ''; const x = new Date(d.slice(0, 10) + 'T00:00:00Z'); return `${x.getUTCDate()} ${MON[x.getUTCMonth()]}`; };

export async function guestContext(db: any, by: { guestId?: string | null; name?: string | null }): Promise<GuestContext> {
  const { data, error } = await db.rpc('guest_context_v1', { p_property_id: PROPERTY_ID, p_guest_id: by.guestId ?? null, p_name: by.name ?? null });
  if (error) { console.warn('guest_context_v1 failed (non-fatal):', error.message); return { found: false }; }
  return (data ?? { found: false }) as GuestContext;
}

/** Card lines for a booking notification; only what exists, at most five. Plain text — HTML callers escape. */
export function guestContextLines(g: GuestContext): string[] {
  if (!g.found) return [];
  const out: string[] = [];
  if ((g.total_stays ?? 0) >= 2) {
    const last = g.last_stay_checkin ? ` · last stay ${dm(g.last_stay_checkin)}–${dm(g.last_stay_checkout)}` : '';
    out.push(`🔄 Stay #${g.total_stays}${last}${g.vip_reason ? ` · ⭐ ${g.vip_reason}` : ''}`);
  } else if (g.vip_reason) out.push(`⭐ ${g.vip_reason}`);
  if (g.last_issue) out.push(`🧹 Last time: "${g.last_issue}" (URGENT, ${dm(g.last_issue_on)}) — check it is fixed`);
  if (g.preferences) out.push(`💡 Prefers: ${g.preferences}`);
  if (g.note) out.push(`📝 ${g.note}`);
  if (g.tags?.length) out.push(`🏷 ${g.tags.join(', ')}`);
  if (g.birthday) out.push(`🎂 Birthday ${dm(g.birthday)}`);
  if (g.open_follow_ups?.length) out.push(`📌 Open: ${g.open_follow_ups.slice(0, 2).join('; ')}`);
  return out.slice(0, 5);
}

// ── Write tools (deploy 3): Cassy never writes. She inserts a `telegram_pending` row in the exact
// shape telegram-expense already consumes and returns a card; the tap in telegram-expense executes.
export const WRITE_TOOL_DECLS: ToolDecl[] = [
  { name: 'log_expense', description: 'Record an expense or purchase in the ledger (finance chat only). Call whenever someone describes money spent. A confirmation card is sent; nothing is saved until it is tapped.',
    parameters: { type: 'object', required: ['amount', 'category'], properties: { amount: { type: 'number', description: 'Amount in PHP' }, category: { type: 'string', enum: ['supplies', 'utilities', 'cleaning', 'maintenance', 'repairs', 'platform_fees', 'guest_refund', 'other'] }, payee: { type: 'string', description: 'Vendor or store' }, memo: { type: 'string', description: 'Short note' } } } },
  { name: 'create_notice', description: 'Schedule a brownout, holiday, event or reminder on the operations board. A confirmation card is sent; nothing is saved until it is tapped.',
    parameters: { type: 'object', required: ['notice_type', 'title', 'effective_date'], properties: { notice_type: { type: 'string', enum: ['brownout', 'holiday', 'event', 'reminder'] }, title: { type: 'string' }, effective_date: { type: 'string', description: 'YYYY-MM-DD' }, effective_time: { type: 'string', description: 'HH:MM:00, required for brownouts' }, duration_hours: { type: 'number' } } } },
];

export type Card = { text: string; keyboard: { text: string; callback_data: string }[][] };
export type ToolCtx = { chatId: string | number; from: { id?: number; first_name?: string; username?: string }; surface: 'finance' | 'ops' };
const whoFrom = (f: ToolCtx['from']) => [f?.first_name, f?.username ? `@${f.username}` : null, f?.id].filter(Boolean).join(' ');
const peso = (n: number) => n.toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const NOTICE_ICON: Record<string, string> = { brownout: '⚡', holiday: '🎉', event: '📅', reminder: '⏰' };

async function pending(db: any, chatId: string | number, kind: string, payload: Record<string, unknown>): Promise<string> {
  const { data, error } = await db.from('telegram_pending').insert({ chat_id: chatId, kind, payload }).select('id').single();
  if (error || !data?.id) throw new Error(`telegram_pending: ${error?.message ?? 'no id'}`);
  return data.id;
}

/** Builds the confirm card for a write tool. Returns null when the args are unusable. */
export async function writeTool(db: any, ctx: ToolCtx, name: string, args: Record<string, unknown>): Promise<{ card: Card | null; result: unknown }> {
  if (name === 'log_expense') {
    if (ctx.surface !== 'finance') return { card: null, result: { error: 'expenses can only be logged in the finance chat' } };
    const amount = Number(args.amount);
    if (!isFinite(amount) || amount <= 0) return { card: null, result: { error: 'amount must be a positive number' } };
    const { data } = await db.from('expense_categories').select('slug,label').eq('property_id', PROPERTY_ID).eq('is_active', true);
    const cats = (data ?? []) as { slug: string; label: string }[];
    const cat = cats.find((c) => c.slug === String(args.category)) ?? cats.find((c) => c.slug === 'other') ?? { slug: 'other', label: 'Other' };
    const payee = args.payee ? String(args.payee).slice(0, 200) : null;
    const memo = args.memo ? String(args.memo).slice(0, 500) : null;
    const pid = await pending(db, ctx.chatId, 'llm_expense', { amount, category: cat.slug, label: cat.label, payee, notes: memo ?? payee, loggedBy: whoFrom(ctx.from) });
    const text = `🧾 ₱${peso(amount)} ${cat.label}${payee ? ` — ${payee}` : ''}?`;
    return { card: { text, keyboard: [[{ text: '✅ Log it', callback_data: `llm_expense_confirm:${pid}` }, { text: '❌ Cancel', callback_data: `llm_cancel:${pid}` }]] }, result: { card_sent: true, amount, category: cat.slug, payee } };
  }
  if (name === 'create_notice') {
    const t = String(args.notice_type ?? ''), title = String(args.title ?? '').trim(), date = args.effective_date;
    if (!NOTICE_ICON[t] || !title || !isYmd(date)) return { card: null, result: { error: 'need notice_type, title and effective_date YYYY-MM-DD' } };
    if (t === 'brownout' && !args.effective_time) return { card: null, result: { error: 'a brownout needs effective_time HH:MM:00' } };
    const params = { notice_type: t, title, effective_date: date, effective_time: args.effective_time ?? null, duration_hours: args.duration_hours ?? null };
    const pid = await pending(db, ctx.chatId, 'llm_notice', { params, from: { first_name: ctx.from?.first_name, username: ctx.from?.username, id: ctx.from?.id } });
    const text = `${NOTICE_ICON[t]} Save ${t} on ${date}${params.effective_time ? ' at ' + String(params.effective_time).slice(0, 5) : ''}${params.duration_hours ? ' for ' + params.duration_hours + 'h' : ''} — ${title}?`;
    return { card: { text, keyboard: [[{ text: '✅ Save it', callback_data: `llm_confirm:${pid}` }, { text: '❌ Cancel', callback_data: `llm_cancel:${pid}` }]] }, result: { card_sent: true, ...params } };
  }
  return { card: null, result: { error: `unknown tool ${name}` } };
}

export const isWriteTool = (name: string) => WRITE_TOOL_DECLS.some((t) => t.name === name);

export async function runTool(db: any, name: string, args: Record<string, unknown>): Promise<unknown> {
  const today = manilaToday();
  switch (name) {
    case 'stays': {
      const from = isYmd(args.from) ? args.from : today;
      const to = isYmd(args.to) ? args.to : addDays(from, 7);
      const rows = await stays(db, from, to);
      return { from, to, today, stays: rows.slice(0, 20).map((s) => ({ code: s.code, guest: s.guest_name, checkin: s.checkin, checkout: s.checkout, nights: s.nights, status: s.status, source: s.stay_kind, accommodation_total: s.accommodation_total })) };
    }
    case 'period_metrics': {
      const from = isYmd(args.from) ? args.from : today.slice(0, 8) + '01';
      const to = isYmd(args.to) ? args.to : addDays(today, 1);
      const rows = await stays(db, from, to);
      let sold = 0, revenue = 0, missing = 0;
      for (const s of rows) { const x = nightsIn(s, from, to); sold += x.nights; if (x.revenue == null) missing++; else revenue += x.revenue; }
      const available = Math.max(0, Math.round((Date.parse(to) - Date.parse(from)) / 86_400_000));
      return { from, to_exclusive: to, nights_sold: sold, nights_available: available, occupancy_pct: available ? Math.round((sold / available) * 100) : null, revenue_php: revenue, stays: rows.length, stays_without_revenue_figure: missing };
    }
    case 'low_stock': {
      const { data, error } = await db.from('inventory_items').select('name,qty_on_hand,reorder_below,unit,unit_cost').eq('property_id', PROPERTY_ID).eq('is_active', true);
      if (error) throw new Error(`inventory_items: ${error.message}`);
      const rows = (data ?? []) as any[];
      const tracked = rows.filter((r) => r.reorder_below != null);
      const low = tracked.filter((r) => Number(r.qty_on_hand) <= Number(r.reorder_below)).map((r) => ({ name: r.name, qty: Number(r.qty_on_hand), reorder_below: Number(r.reorder_below), unit: r.unit, unit_cost: r.unit_cost }));
      return { low, tracked_items: tracked.length, items_without_reorder_point: rows.length - tracked.length };
    }
    case 'inventory_report': {
      // get_inventory_catalogue_v1 (what the admin dashboard's Inventory page
      // calls) requires admin_require('read_operations', ...) -- a real signed-in
      // staff session, which a bot never has (same wall D-146/D-148 hit for
      // inventory writes). Replicates its estimated-coverage formula
      // (consumption_per_booking x 60-day turnover rate) via plain table reads
      // instead, matching low_stock's own already-working raw-select pattern.
      // No unit_cost/pricing field is read at all, so there is nothing for
      // stripMoney to need to catch on the ops surface.
      const sixtyDaysAgo = new Date(Date.now() - 60 * 86_400_000).toISOString();
      const [itemsRes, turnoverRes] = await Promise.all([
        db.from('inventory_items').select('name,qty_on_hand,unit,consumption_per_booking').eq('property_id', PROPERTY_ID).eq('is_active', true).eq('is_consumable', true),
        db.from('cleaning_sessions').select('id', { count: 'exact', head: true }).eq('property_id', PROPERTY_ID).in('cleaning_type', ['turnover', 'deep_clean']).gte('cleaned_at', sixtyDaysAgo),
      ]);
      if (itemsRes.error) throw new Error(`inventory_items: ${itemsRes.error.message}`);
      if (turnoverRes.error) throw new Error(`cleaning_sessions: ${turnoverRes.error.message}`);
      const turnoverRate = (turnoverRes.count ?? 0) / 60;
      const rows = (itemsRes.data ?? []) as any[];
      return {
        turnover_rate_per_day: Math.round(turnoverRate * 10_000) / 10_000,
        count: rows.length,
        items: rows.map((r) => {
          const cpb = r.consumption_per_booking != null ? Number(r.consumption_per_booking) : null;
          const estDaily = cpb != null && turnoverRate > 0 ? cpb * turnoverRate : null;
          const coverageDays = estDaily && estDaily > 0 ? Math.round((Number(r.qty_on_hand) / estDaily) * 10) / 10 : null;
          return { name: r.name, qty: Number(r.qty_on_hand), unit: r.unit, coverage_days: coverageDays, estimated: coverageDays != null };
        }),
      };
    }
    case 'guest_history': {
      const name = String(args.name ?? '').trim();
      if (!name) return { error: 'name is required' };
      const g = await guestContext(db, { name });
      return g.found ? { ...g, summary_lines: guestContextLines(g) } : { found: false, name, note: 'no guest with that name on file' };
    }
    default: return { error: `unknown tool ${name}` };
  }
}
