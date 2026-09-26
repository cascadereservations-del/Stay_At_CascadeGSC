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
import { gate, addressed, unmention, stripMoney, wantsExpense, honestAboutCard, onlyAskedFor, memoOf, deepRequest, deepAllowed, type Surface } from './policy.ts';
// v23 (session 27, Telegram plan §3): "cassy reply: <guest text>" or a chat screenshot captioned "cassy draft"
// returns a reply for the host to copy. Never sends to the guest.
import { draftRequest, draftGuestReply, transcribeChat, reviseHostMessage } from './draft.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const GATE_ENV = () => ({ financeChat: env('TELEGRAM_FINANCE_CHAT_ID'), opsChat: env('TELEGRAM_CHAT_ID'), dmUserIds: env('CASSY_DM_USER_IDS').split(',').map((s) => s.trim()).filter(Boolean) });

// ponytail: voice lives here until the digest needs it too, then it moves to cascade-core.
const VOICE = (surface: Surface, today: string) => `You are Cassy, the operations assistant for Cascade Hideaway, a one-unit boutique Airbnb in General Santos City, Philippines. Internal staff only; you are NOT the guest concierge.
Today (Manila): ${today}. Currency PHP. Dates as "Sat 20 Sep", never YYYY-MM-DD in the answer.
A stay is always stated with its dates (Sat 27 Sep to Sun 28 Sep); a count alone is not an answer (SPEC-32 s6, F13).
Asked when the unit is next free or available: call stays for the next 30 days and answer with the first check-in date no stay covers, as a date ("Free from Fri 2 Oct"), then the stays that decide it. Live 2026-09-26: the stays were listed and the question was not answered.
Answer only from tool results. If a tool has no data, say so plainly; never estimate or invent.
If a tool returns an error, say "I could not read <what>" and stop; never ask anyone for permission or access.
Call only the tools the question needs.
Write tools (log_expense, create_notice) only send a confirmation card; after one, your decision line says what the card holds and the action is "Tap ✅ on the card". Nothing is saved until the tap.
${surface === 'ops' ? 'SURFACE OPS: staff and cleaners read this. Money fields are removed from your tools; never mention amounts.' : 'SURFACE FINANCE: admins read this; figures are allowed.'}
Reply in the language of the question (English, Tagalog, Bisaya or Taglish), warm and direct.
FINAL ANSWER FORMAT: return only JSON {"decision": "<one line: what needs a decision, or that nothing does>", "lines": ["<at most 5 short lines, each with its number and why it matters>"], "action": "<one action doable in under two minutes, or empty>"}.`;

async function tgSend(chatId: unknown, text: string, replyTo?: number, card?: Card): Promise<void> {
  const token = env('TELEGRAM_BOT_TOKEN'); if (!token) return;
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true, ...(replyTo ? { reply_parameters: { message_id: replyTo } } : {}), ...(card ? { reply_markup: { inline_keyboard: card.keyboard } } : {}) }),
    signal: AbortSignal.timeout(10_000),
  }).catch((e) => console.error('tg_send_failed', String(e).slice(0, 200)));
}

async function history(db: any, chatId: string): Promise<ChatTurn[]> {
  const { data } = await db.from('telegram_chat_history').select('role,parts').eq('chat_id', chatId).order('created_at', { ascending: false }).limit(6);
  return ((data ?? []) as any[]).reverse()
    .map((r) => ({ role: r.role === 'model' ? 'assistant' : 'user', text: (r.parts ?? []).map((p: any) => p.text ?? '').join('').trim() } as ChatTurn))
    .filter((t) => t.text);
}

async function remember(db: any, chatId: string, q: string, a: string): Promise<void> {
  await db.from('telegram_chat_history').insert([{ chat_id: chatId, role: 'user', parts: [{ text: q }] }, { chat_id: chatId, role: 'model', parts: [{ text: a }] }]);
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
    const tools = [...TOOL_DECLS, ...WRITE_TOOL_DECLS.filter((t) => surface === 'finance' || t.name === 'create_notice')];
    const ctx = { chatId, from: msg.from ?? {}, surface };
    let cardSent = false;
    const res = await chatTools({
      system: VOICE(surface, today), history: await history(db, chatId), question, tools, title: 'Cascade Cassy', tier, maxRounds: tier === 'deep' ? 5 : 3, maxTokens: tier === 'deep' ? 1200 : 700,
      forceTool: wantsExpense(question, surface) ? 'log_expense' : undefined,
      run: async (name, args) => {
        if (isWriteTool(name)) {
          const w = await writeTool(db, ctx, name, args).catch((e) => { console.error('tool_failed', JSON.stringify({ name, error: String(e).slice(0, 300) })); return { card: null, result: { error: `${name} unavailable` } }; });
          if (w.card) { await tgSend(chatId, w.card.text, msg.message_id, w.card); cardSent = true; }
          return w.result;
        }
        const r = await runTool(db, name, args).catch((e) => { console.error('tool_failed', JSON.stringify({ name, error: String(e).slice(0, 300) })); return { error: `${name} unavailable` }; });
        return surface === 'ops' ? stripMoney(r) : r;
      },
    });
    const report = parseReport(res.text);
    if (!report.decision && !report.lines.length) console.warn('report_unparsed', JSON.stringify({ tier, raw: res.text.slice(0, 400) }));
    const shaped = onlyAskedFor(honestAboutCard(report, cardSent), res.toolCalls ?? []);
    const text = renderReport(shaped, res.model);
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

async function draft(db: any, msg: any, pasted: string): Promise<void> {
  const chatId = String(msg.chat.id);
  const t0 = Date.now();
  try {
    let guestText = pasted, guestName: string | null = null;
    // "cassy draft" as a reply to someone's pasted message drafts for that message.
    if (!guestText && typeof msg.reply_to_message?.text === 'string') guestText = msg.reply_to_message.text;
    if (Array.isArray(msg.photo) && msg.photo.length) {
      const ph = await photoBytes(msg);
      if (!ph) { await tgSend(chatId, 'I could not fetch that screenshot. Paste the guest text instead: "cassy reply: …"', msg.message_id); return; }
      const t = await transcribeChat(ph.bytes, ph.mime);
      if (t.guest_messages) { guestText = [guestText, t.guest_messages].filter(Boolean).join('\n'); guestName = t.guest_name; }
    }
    const nm = /\b(?:guest|from|for)\s*[:=]\s*([A-Z][\p{L}'-]+(?:\s+[A-Z][\p{L}'-]+){0,3})/u.exec(pasted);
    if (nm) { guestName = nm[1]; guestText = guestText.replace(nm[0], '').trim(); }
    if (!guestText.trim()) { await tgSend(chatId, 'Give me the guest\'s message: "cassy reply: <what they wrote>", or send the chat screenshot with the caption "cassy draft".', msg.message_id); return; }
    const out = await draftGuestReply(db, guestText, guestName);
    await tgSend(chatId, out, msg.message_id);
    console.log('cassy_draft', JSON.stringify({ chat: chatId, from: msg.from?.id, photo: !!msg.photo, chars: guestText.length, ms: Date.now() - t0 }));
  } catch (e) {
    console.error('cassy_draft_failed', String(e).slice(0, 300));
    await tgSend(chatId, 'I could not draft that right now. Try again in a minute.', msg.message_id);
  }
}

async function revise(db: any, msg: any, raw: string): Promise<void> {
  const chatId = String(msg.chat.id);
  const [template, context = ''] = raw.split('|||').map((x) => x.trim());
  if (!template) { await tgSend(chatId, 'Nothing to revise on that card.', msg.message_id); return; }
  try { await tgSend(chatId, await reviseHostMessage(db, template, context), msg.message_id); }
  catch (e) { console.error('cassy_revise_failed', String(e).slice(0, 300)); await tgSend(chatId, 'I could not revise that right now. Try again in a minute.', msg.message_id); }
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
  const dr = draftRequest(question);
  const work = rv ? revise(db, msg, rv[1]) : dr.draft ? draft(db, msg, dr.text) : answer(db, msg, g.surface, question);
  // @ts-ignore EdgeRuntime is provided by Supabase
  if (typeof EdgeRuntime !== 'undefined' && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(work); else await work;
  return Response.json({ ok: true, surface: g.surface });
}));
