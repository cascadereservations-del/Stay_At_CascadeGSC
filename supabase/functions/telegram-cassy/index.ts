// telegram-cassy v1 (2026-09-13, D-104). Cascade's internal operations assistant.
// Receives a raw Telegram update (forwarded by telegram-expense, or posted directly for tests),
// gates by chat membership / DM allowlist, answers questions that start with "cassy" by calling
// read-only tools from cascade-core, and replies in the ADHD/ELI5 shape. Read-only: no tool writes.
//
// Secrets (Edge Function secrets, project-wide): TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET,
//   TELEGRAM_FINANCE_CHAT_ID, TELEGRAM_CHAT_ID (ops), CASSY_DM_USER_IDS (optional, "id,id"),
//   CASCADE_GEMINI_BOT_KEY, CASCADE_OPENROUTER_BOT_KEY. Deploy with verify_jwt=false.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { chatTools, geminiBreaker, type ChatTurn } from '../_shared/cascade-core/providers.ts';
import { TOOL_DECLS, WRITE_TOOL_DECLS, runTool, writeTool, isWriteTool, manilaToday, type Card } from '../_shared/cascade-core/tools.ts';
import { parseReport, renderReport } from '../_shared/cascade-core/format.ts';
import { HOUSE_READ_DECL, HOUSE_TEACH_DECL, houseInfo, teachCard } from '../_shared/cascade-core/house.ts'; // D-282
import { toneRules } from '../messenger-concierge/voice.ts';
import { gate, addressed, unmention, stripMoney, wantsExpense, honestAboutCard, onlyAskedFor, memoOf, deepRequest, deepAllowed, recentTurns, opsToolsOnly, maskReport, postDraft, maskFacts, maskNoticeCard, type Surface } from './policy.ts';
// v23 (session 27, Telegram plan §3): "cassy reply: <guest text>" or a chat screenshot captioned "cassy draft"
// returns a reply for the host to copy. Never sends to the guest.
import { draftRequest, draftGuestReply, draftInquiry, inquiryDraftCard, routeDraft, transcribeChat, reviseHostMessage, splitThread, type Line, type Platform } from './draft.ts';
import { maskMoney } from '../_shared/ops-money.ts'; // D-306
import { OPS_MONEY_REFUSED, staleReason, type InquiryView } from '../_shared/cascade-core/inquiry.ts'; // SPEC-38: Cassy reply and the Other decline for an unpaid request

const env = (k: string) => Deno.env.get(k) ?? '';
const GATE_ENV = () => ({ financeChat: env('TELEGRAM_FINANCE_CHAT_ID'), opsChat: env('TELEGRAM_CHAT_ID'), dmUserIds: env('CASSY_DM_USER_IDS').split(',').map((s) => s.trim()).filter(Boolean) });

// ponytail: voice lives here until the digest needs it too, then it moves to cascade-core.
const VOICE = (surface: Surface, today: string) => `You are Cassy, the operations assistant for Cascade Hideaway, a one-unit boutique Airbnb in General Santos City, Philippines. Internal staff only; you are NOT the guest concierge.
Today (Manila): ${today}. Currency PHP. Dates as "Sat 20 Sep", never YYYY-MM-DD in the answer.
A stay is always stated with its dates (Sat 27 Sep to Sun 28 Sep); a count alone is not an answer (SPEC-32 s6, F13).
Asked when the unit is next free or available: call stays with to = today + 30 days and state its first_open_night as the answer ("Free from Fri 2 Oct"; null = nothing free in that window), then the stays that decide it. Never count the nights yourself. Live 2026-09-26: the stays were listed and the question was not answered.
Answer only from tool results. If a tool has no data, say so plainly; never estimate or invent.
If a tool returns an error, say "I could not read <what>" and stop; never ask anyone for permission or access.
Call only the tools the question needs.
Earlier turns are context only. Answer the CURRENT question from THIS turn's tool results; never repeat an earlier answer.
House how-tos (aircon, Wi-Fi, door, EcoFlow, turnover steps, suppliers): call house_info and answer from it; never invent a step.
Write tools (log_expense, create_notice, teach_house_fact) only send a confirmation card; after one, your decision line says what the card holds and the action is "Tap ✅ on the card". Nothing is saved until the tap.
${surface === 'ops' ? 'SURFACE OPS: staff and cleaners read this. Money fields are removed from your tools; never mention amounts, and give no occupancy, revenue or booking figures.' : 'SURFACE FINANCE: admins read this; figures are allowed.'}
Reply in the language of the question (English, Tagalog, Bisaya or Taglish), warm and direct.
FINAL ANSWER FORMAT: return only JSON {"decision": "<one line: what needs a decision, or that nothing does>", "lines": ["<at most 5 short lines, each with its number and why it matters>"], "action": "<one action doable in under two minutes, or empty>"}.`;

async function tgSend(chatId: unknown, text: string, replyTo?: number, card?: Card): Promise<boolean> {
  const token = env('TELEGRAM_BOT_TOKEN'); if (!token) return false;
  const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true, ...(replyTo ? { reply_parameters: { message_id: replyTo } } : {}), ...(card ? { reply_markup: { inline_keyboard: card.keyboard } } : {}) }),
    signal: AbortSignal.timeout(10_000),
  }).catch((e) => { console.error('tg_send_failed', String(e).slice(0, 200)); return null; });
  if (r && !r.ok) console.error('tg_send_refused', JSON.stringify({ status: r.status }));
  return !!r?.ok;
}

async function history(db: any, chatId: string): Promise<ChatTurn[]> {
  const { data } = await db.from('telegram_chat_history').select('role,parts,created_at').eq('chat_id', chatId).order('created_at', { ascending: false }).limit(6);
  return recentTurns((data ?? []) as any[], Date.now()).reverse()
    .map((r) => ({ role: r.role === 'model' ? 'assistant' : 'user', text: (r.parts ?? []).map((p: any) => p.text ?? '').join('').trim() } as ChatTurn))
    .filter((t) => t.text);
}

async function remember(db: any, chatId: string, q: string, a: string): Promise<void> {
  const now = Date.now(); // distinct stamps: one insert used to give both rows the same created_at and the order read back at random
  await db.from('telegram_chat_history').insert([{ chat_id: chatId, role: 'user', parts: [{ text: q }], created_at: new Date(now).toISOString() }, { chat_id: chatId, role: 'model', parts: [{ text: a }], created_at: new Date(now + 1).toISOString() }]);
  const { data: old } = await db.from('telegram_chat_history').select('id').eq('chat_id', chatId).order('created_at', { ascending: true });
  const rows = (old ?? []) as any[];
  if (rows.length > 12) await db.from('telegram_chat_history').delete().in('id', rows.slice(0, rows.length - 12).map((r) => r.id));
}

// Deep tier bookkeeping: one app_settings row per Manila day holds the count. Cap from CASSY_DEEP_DAILY_CAP (default 10).
async function claimDeep(db: any, today: string): Promise<{ ok: boolean; used: number; cap: number }> {
  const cap = Number(env('CASSY_DEEP_DAILY_CAP') || 10);
  const key = `cassy_deep_${today}`;
  const { data } = await db.from('app_settings').select('value').eq('key', key).maybeSingle();
  const used = Number(data?.value ?? 0) || 0;
  if (!deepAllowed(used, cap)) return { ok: false, used, cap };
  await db.from('app_settings').upsert({ key, value: String(used + 1) });
  return { ok: true, used: used + 1, cap };
}

async function answer(db: any, msg: any, surface: Surface, rawQuestion: string): Promise<void> {
  const chatId = String(msg.chat.id);
  const today = manilaToday();
  const dq = deepRequest(rawQuestion);
  const question = dq.text || 'status';
  let tier: 'full' | 'deep' = 'full';
  if (dq.deep) {
    const c = await claimDeep(db, today);
    if (c.ok) tier = 'deep';
    else await tgSend(chatId, `Deep answers are capped at ${c.cap} per day and today's are used. Answering on the standard model.`, msg.message_id);
  }
  const { data: cd } = await db.from('app_settings').select('value').eq('key', 'gemini_cooldown_until').maybeSingle();
  geminiBreaker.until = typeof cd?.value === 'string' ? (Date.parse(cd.value) || 0) : 0;
  geminiBreaker.trip = async (until) => { await db.from('app_settings').upsert({ key: 'gemini_cooldown_until', value: new Date(until).toISOString() }); };
  const t0 = Date.now();
  try {
    // Ops chat may schedule notices but never log money; finance chat gets both write tools.
    // D-282: house_info on both surfaces; teaching only where log_expense lives (the Finance chat: Lloyd and Marifel).
    // Live read 2026-09-29: "cassy house wifi" called guest_stays too and answered with a guest's stays from the chat
    // history. "cassy house ..." now offers the house tool alone, forced.
    const houseAsk = /^\s*house\b/i.test(question);
    const tools = houseAsk ? [HOUSE_READ_DECL] : [...opsToolsOnly(TOOL_DECLS, surface), HOUSE_READ_DECL, ...WRITE_TOOL_DECLS.filter((t) => surface === 'finance' || t.name === 'create_notice'), ...(surface === 'finance' ? [HOUSE_TEACH_DECL] : [])];
    const ctx = { chatId, from: msg.from ?? {}, surface };
    let cardSent = false;
    const res = await chatTools({
      system: VOICE(surface, today), history: await history(db, chatId), question, tools, title: 'Cascade Cassy', tier, maxRounds: tier === 'deep' ? 5 : 3, maxTokens: tier === 'deep' ? 1200 : 700,
      forceTool: houseAsk ? 'house_info' : wantsExpense(question, surface) ? 'log_expense' : surface === 'finance' && /^\s*(teach|edit|retire)\b/i.test(question) ? 'teach_house_fact' : undefined,
      run: async (name, args) => {
        if (name === 'house_info') { const h = await houseInfo(db, String(args.query ?? '')).catch((e) => { console.error('tool_failed', JSON.stringify({ name, error: String(e).slice(0, 300) })); return { error: 'house_info unavailable' }; }); return surface === 'ops' ? stripMoney(maskFacts(h)) : h; } // D-306: OPS sees house facts masked
        if (name === 'teach_house_fact') {
          if (surface !== 'finance') return { error: 'house facts are taught in the finance chat' };
          const w = await teachCard(db, chatId, args, [msg.from?.first_name, msg.from?.id].filter(Boolean).join(' ')).catch((e) => { console.error('tool_failed', JSON.stringify({ name, error: String(e).slice(0, 300) })); return { card: null, result: { error: 'teach_house_fact unavailable' } }; });
          if (w.card) {
            const lint = args.retire ? [] : toneRules(String(args.body ?? '')); // voice.ts rules: a warning on the card, never a block
            await tgSend(chatId, lint.length ? `${w.card.text}\n⚠️ Voice check: ${lint.join(', ')} - edit or tap anyway.` : w.card.text, msg.message_id, w.card); cardSent = true;
          }
          return w.result;
        }
        if (isWriteTool(name)) {
          const w = await writeTool(db, ctx, name, args).catch((e) => { console.error('tool_failed', JSON.stringify({ name, error: String(e).slice(0, 300) })); return { card: null, result: { error: `${name} unavailable` } }; });
          if (w.card) { await tgSend(chatId, surface === 'ops' ? maskNoticeCard(w.card.text, args.title) : w.card.text, msg.message_id, w.card); cardSent = true; } // D-306: the OPS notice card masks the title like the saved notice does
          return w.result;
        }
        const r = await runTool(db, name, args).catch((e) => { console.error('tool_failed', JSON.stringify({ name, error: String(e).slice(0, 300) })); return { error: `${name} unavailable` }; });
        return surface === 'ops' ? stripMoney(r) : r;
      },
    });
    const report = parseReport(res.text);
    if (!report.decision && !report.lines.length) console.warn('report_unparsed', JSON.stringify({ tier, raw: res.text.slice(0, 400) }));
    const shaped = maskReport(onlyAskedFor(honestAboutCard(report, cardSent), res.toolCalls ?? []), surface); // D-306: OPS answers are masked, history included
    const text = surface === 'ops' ? maskMoney(renderReport(shaped, res.model)) : renderReport(shaped, res.model);
    await tgSend(chatId, text, msg.message_id);
    await remember(db, chatId, question, memoOf(shaped)).catch((e) => console.warn('history_failed', String(e).slice(0, 200)));
    console.log('cassy_turn', JSON.stringify({ chat: chatId, from: msg.from?.id, surface, tier, tools: res.toolCalls, provider: res.provider, model: res.model, ms: Date.now() - t0 }));
  } catch (e) {
    console.error('cassy_failed', String(e).slice(0, 300));
    await tgSend(chatId, 'I could not reach the model. Try again in a minute.', msg.message_id);
  }
}

async function photoBytes(msg: any): Promise<{ bytes: Uint8Array; mime: string } | null> {
  const token = env('TELEGRAM_BOT_TOKEN'); const p = Array.isArray(msg?.photo) ? msg.photo : [];
  const fileId = p.length ? p[p.length - 1].file_id : null; if (!token || !fileId) return null;
  const f = await fetch(`https://api.telegram.org/bot${token}/getFile?file_id=${fileId}`, { signal: AbortSignal.timeout(10_000) }).then((r) => r.json()).catch(() => null);
  const path = f?.result?.file_path; if (!path) return null;
  const r = await fetch(`https://api.telegram.org/file/bot${token}/${path}`, { signal: AbortSignal.timeout(20_000) }).catch(() => null);
  if (!r || !r.ok) return null;
  return { bytes: new Uint8Array(await r.arrayBuffer()), mime: /\.png$/i.test(path) ? 'image/png' : 'image/jpeg' };
}

const askerOf = (msg: any): string => String(msg?.from?.first_name ?? '').trim().split(/\s+/)[0];

async function draft(db: any, msg: any, pasted: string, surface: Surface): Promise<void> {
  const chatId = String(msg.chat.id);
  const t0 = Date.now();
  try {
    let guestText = pasted, guestName: string | null = null, thread: { before?: Line[]; platform?: Platform } = {};
    // "cassy draft" as a reply to someone's pasted message drafts for that message (never to Cassy's own prompt).
    if (!guestText && typeof msg.reply_to_message?.text === 'string' && !msg.reply_to_message.from?.is_bot) guestText = msg.reply_to_message.text;
    if (Array.isArray(msg.photo) && msg.photo.length) {
      const ph = await photoBytes(msg);
      if (!ph) { await tgSend(chatId, 'I could not fetch that screenshot. Paste the guest text instead: "cassy reply: …"', msg.message_id); return; }
      // D-269: the whole visible thread, so the draft answers the newest guest messages with the conversation behind them.
      const t = await transcribeChat(ph.bytes, ph.mime);
      const s = splitThread(t.messages);
      if (s.latest) { guestText = [guestText, s.latest].filter(Boolean).join('\n'); guestName = t.guest_name; thread = { before: s.before, platform: t.platform }; }
    }
    const nm = /\b(?:guest|from|for)\s*[:=]\s*([A-Z][\p{L}'-]+(?:\s+[A-Z][\p{L}'-]+){0,3})/u.exec(pasted);
    if (nm) { guestName = nm[1]; guestText = guestText.replace(nm[0], '').trim(); }
    if (!guestText.trim()) { await tgSend(chatId, 'I could not find a guest message there. Tap ✍️ Guest reply and paste what they wrote, or send a screenshot of the chat.', msg.message_id); return; }
    const out = await draftGuestReply(db, guestText, guestName, thread);
    // header, then each option alone: a long-press copies only the reply. D-306: a draft with an amount is posted in Finance, not OPS.
    await postDraft(tgSend, { surface, chatId, financeChat: env('TELEGRAM_FINANCE_CHAT_ID'), refused: OPS_MONEY_REFUSED, parts: out, replyTo: msg.message_id, asker: askerOf(msg) });
    console.log('cassy_draft', JSON.stringify({ chat: chatId, from: msg.from?.id, photo: !!msg.photo, chars: guestText.length, ms: Date.now() - t0 }));
  } catch (e) {
    console.error('cassy_draft_failed', String(e).slice(0, 300));
    await tgSend(chatId, 'I could not draft that right now. Try again in a minute.', msg.message_id);
  }
}

async function revise(db: any, msg: any, raw: string, surface: Surface): Promise<void> {
  const chatId = String(msg.chat.id);
  const [template, context = ''] = raw.split('|||').map((x) => x.trim());
  if (!template) { await tgSend(chatId, 'Nothing to revise on that card.', msg.message_id); return; }
  try { await postDraft(tgSend, { surface, chatId, financeChat: env('TELEGRAM_FINANCE_CHAT_ID'), refused: OPS_MONEY_REFUSED, parts: [await reviseHostMessage(db, template, context)], replyTo: msg.message_id, asker: askerOf(msg) }); } // D-306
  catch (e) { console.error('cassy_revise_failed', String(e).slice(0, 300)); await tgSend(chatId, 'I could not revise that right now. Try again in a minute.', msg.message_id); }
}

// SPEC-38 s8: "inquiry: reply|decline <booking uuid> [||| private reason]" arrives from telegram-expense (the Cassy reply tap, or the
// reason a Finance member typed for an "Other" decline). Cassy drafts, gates, stores an inquiry_reply row and posts the draft card.
// The send itself is a tap handled in telegram-expense. A draft that mentions amounts, asked for in OPS, is posted in Finance instead.
const INQUIRY_RE = /^\s*inquiry\s*:\s*(reply|decline)\s+([0-9a-f-]{36})(?:\s*\|\|\|\s*([\s\S]*))?$/i;

async function inquiry(db: any, msg: any, surface: Surface, purpose: 'reply' | 'decline', bookingId: string, reason?: string): Promise<void> {
  const chatId = String(msg.chat.id);
  const t0 = Date.now();
  try {
    if (purpose === 'decline' && surface !== 'finance') { await tgSend(chatId, 'A decline is written from the Finance group. Nothing was drafted.', msg.message_id); return; }
    const { data: rows, error } = await db.rpc('telegram_inquiry_view_v1', { p_booking_id: bookingId });
    if (error) throw new Error(error.message);
    const view = ((rows ?? [])[0] ?? null) as InquiryView | null;
    const stale = staleReason(view);
    if (stale || !view) { await tgSend(chatId, stale ?? 'That request no longer exists.', msg.message_id); return; }
    const d = await draftInquiry(db, view, purpose, reason);
    const route = routeDraft(surface, d.text);
    let target = chatId;
    if (route.toFinance) {
      const fin = env('TELEGRAM_FINANCE_CHAT_ID');
      await tgSend(chatId, OPS_MONEY_REFUSED, msg.message_id);
      if (!fin) return;
      target = fin;
    }
    let pid = '';
    if (d.gate.length === 0) {
      const payload = {
        purpose, booking_id: view.id, channel_hint: d.channel, lang: d.lang, text: d.text, gate: d.gate, ops_ok: route.ops_ok,
        drafted_by_tg: msg.from?.id ?? null, drafted_in_chat: chatId, card_mid: msg.message_id ?? null,
        ...(purpose === 'decline' ? { reason_code: 'other', reason_private: String(reason ?? '').slice(0, 300) } : {}),
      };
      const { data: row, error: pe } = await db.from('telegram_pending').insert({ chat_id: Number(target), kind: 'inquiry_reply', payload, expires_at: new Date(Date.now() + 1440 * 60_000).toISOString() }).select('id').single();
      if (pe || !row) { console.error('pending_insert_failed', JSON.stringify({ kind: 'inquiry_reply', error: String(pe?.message ?? pe ?? 'no row').slice(0, 200) })); await tgSend(chatId, 'I could not open that draft, so nothing was drafted. Try again in a minute.', msg.message_id); return; }
      pid = row.id;
    }
    const card = inquiryDraftCard({ view, purpose, pid, d, forOps: surface === 'ops' && !route.toFinance });
    await tgSend(target, card.text, target === chatId ? msg.message_id : undefined, { text: card.text, keyboard: card.keyboard as Card['keyboard'] });
    console.log('cassy_inquiry', JSON.stringify({ chat: chatId, from: msg.from?.id, purpose, source: d.source, gate: d.gate, to_finance: route.toFinance, ms: Date.now() - t0 }));
  } catch (e) {
    console.error('cassy_inquiry_failed', String(e).slice(0, 300));
    await tgSend(chatId, 'I could not draft that right now. Nothing was drafted. Try again in a minute.', msg.message_id);
  }
}

Deno.serve(withObservability({ functionName: 'telegram-cassy', route: 'ops' }, async (req) => {
  if (req.method !== 'POST') return new Response('method_not_allowed', { status: 405 });
  const secret = env('TELEGRAM_WEBHOOK_SECRET');
  if (!secret || req.headers.get('X-Telegram-Bot-Api-Secret-Token') !== secret) return new Response('unauthorized', { status: 401 });
  let update: any; try { update = await req.json(); } catch { return Response.json({ ok: true, skipped: 'bad_json' }); }
  const msg = update?.message;
  const text = typeof msg?.text === 'string' ? msg.text : typeof msg?.caption === 'string' ? msg.caption : '';
  if (!msg || !text || msg.from?.is_bot) return Response.json({ ok: true, skipped: 'no_text' });
  const g = gate(msg.chat?.id, msg.chat?.type, msg.from?.id, GATE_ENV());
  if (!g.allowed) { console.warn('cassy_refused', JSON.stringify({ chat: msg.chat?.id, from: msg.from?.id, reason: g.reason })); return Response.json({ ok: true, skipped: g.reason }); }
  // `?any=1` (deploy 3): telegram-expense already checked the bot was addressed; take the whole text.
  const question = new URL(req.url).searchParams.get('any') === '1' || /^\s*\/deep\b/i.test(text) ? unmention(text) : addressed(text);
  if (!question) return Response.json({ ok: true, skipped: 'not_addressed' });
  const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'));
  // Session 28: "revise: <text> ||| <card context>" comes from the ✏️ Revise tap in telegram-expense.
  const rv = /^\s*revise\s*:\s*([\s\S]*)$/i.exec(question);
  const iq = INQUIRY_RE.exec(question);
  const dr = draftRequest(question);
  const work = rv ? revise(db, msg, rv[1], g.surface) : iq ? inquiry(db, msg, g.surface, iq[1].toLowerCase() as 'reply' | 'decline', iq[2], iq[3]) : dr.draft ? draft(db, msg, dr.text, g.surface) : answer(db, msg, g.surface, question);
  // @ts-ignore EdgeRuntime is provided by Supabase
  if (typeof EdgeRuntime !== 'undefined' && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(work); else await work;
  return Response.json({ ok: true, surface: g.surface });
}));
