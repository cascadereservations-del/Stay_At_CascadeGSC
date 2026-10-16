// ocr-receipt — receipt OCR for the Cascade Smart Finance Layer.
// v10 (s89): STAFF ONLY. verify_jwt is true but the public anon key passes it, so every request now needs a signed-in owner/admin/finance
//   (requireStaffAccess approve_payment); the anon key gets 401/403. New body mode:"extract" {image_base64, mime_type} stores the photo at
//   expense-receipts/<property>/<user>/<uuid>.<ext>, reads it and returns {receipt_path, amount, date, vendor, category, line_items,
//   confidence} WITHOUT creating a transaction (the Manage hub saves via admin_save_transaction_v1 receipt_image_path). The category is
//   mapped to the live expense_categories list, which is also what the model is told. The old create path (image_path / image_base64
//   without mode) is unchanged behind the same staff check. The vision call is the shared cascade-core/vision.ts, which logs llm_usage.
// v8 (2026-09-16): structured line_items ({description, qty, unit_cost}) for
//   the purchase-report Telegram shortcut (PLAN-telegram-ops-shortcuts-and-rag-chatbot.md).
//   Image-only per the plan's explicit scope cut; add PDF only if it turns out
//   to matter in practice.
// v7 (2026-09-13): provider-agnostic + rotated key names + current model.
//   Receipt OCR had been failing since the 2026-09-12 key rotation and nobody
//   noticed, because a failure returns 502 and inserts nothing — a broken OCR
//   looks exactly like nobody sending receipts. Three faults stacked:
//     - GEMINI_BOT_KEY / GEMINI_API_KEY were rotated into
//       CASCADE_GEMINI_BOT_KEY; the old secrets still exist and return
//       API_KEY_INVALID.
//     - gemini-2.5-flash is refused for new callers in favour of
//       gemini-3.6-flash.
//     - the Gemini account's prepayment credits are depleted anyway.
//   So this now takes the same shape as verify-meter-photo: VISION_PROVIDER
//   chooses gemini or openrouter, and the estate already holds both keys.
// v6: gemini-2.5-flash + GEMINI_BOT_KEY + retry-with-backoff
//
// Input (POST JSON):
//   { image_path?: string,        // object path inside the expense-receipts bucket
//     image_base64?: string,      // OR raw base64 (no data: prefix)
//     mime_type?: string,         // required if image_base64 is used (default image/jpeg)
//     source?: 'ocr'|'manual',    // default 'ocr'
//     logged_by?: string,
//     telegram_chat_id?: number|string,  // if set AND skip_telegram_notify is false, posts a review notice
//     skip_telegram_notify?: boolean,    // true = caller handles Telegram reply (e.g. with confirm buttons)
//     notes?: string }
//
// extracted.line_items is now { description: string, qty: number|null, unit_cost: number|null }[]
// instead of flat description strings — the shape a purchase confirm-card needs to
// match against inventory_items per-line. This function still only writes a single
// expense row to `transactions`; matching line items to inventory_items and writing
// inventory_purchases is the caller's job (telegram-cassy's purchase-report tool, not built yet).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { requireStaffAccess, staffAuthResponse, type StaffIdentity } from '../_shared/staff-auth.ts';
import { buildPrompt, decodeImage, formatLineItemsForNotes, clamp01, mapCategory, normalizeLineItems, receiptPath, shapeExtraction, validDate } from './logic.ts';
// v9 (session 27): the vision call lives in cascade-core/vision.ts, shared with telegram-expense and
// upload-booking-receipt (booking PRD task 2). Same env contract; this file only parses.
import { VISION_PROVIDER as PROVIDER, hasVisionKey, bytesToBase64, visionExtractText } from '../_shared/cascade-core/vision.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TG_TOKEN     = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';

const PROPERTY_ID     = '6ae230f4-c189-4547-84b1-cb6e0b2cc9bd';
const RECEIPTS_BUCKET = 'expense-receipts';

const JSON_HEADERS = { 'Content-Type': 'application/json' };
const CORS = {
  'Access-Control-Allow-Origin': '*',
  // s90: supabase-js functions.invoke adds x-client-info (and newer builds the x-supabase-client-* headers); without them the browser drops the POST after the preflight
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version, x-supabase-api-version',
  ...JSON_HEADERS,
};
function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: CORS });
}

async function tgSend(chatId: number | string, text: string): Promise<void> {
  if (!TG_TOKEN) return;
  await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
    method: 'POST', headers: JSON_HEADERS,
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'Markdown' }),
    signal: AbortSignal.timeout(15_000),
  }).catch(() => {});
}

const EXTRACTION_PROMPT = `You are a receipt data extractor for a Philippine boutique Airbnb's expense ledger.
Read this receipt image and return ONLY a JSON object (no markdown, no prose) with exactly these keys:
{
  "amount": number | null,        // the TOTAL amount paid, in pesos, as a plain number (no currency symbol)
  "currency": string,             // "PHP" unless clearly otherwise
  "date": string | null,          // purchase date as "YYYY-MM-DD", or null if unreadable
  "vendor": string | null,        // store/merchant name, or null
  "category_hint": string,        // ONE of: supplies, utilities, cleaning, maintenance, repairs, platform_fees, other
  "line_items": [                 // one entry per distinct item legible on the receipt, else []
    {
      "description": string,      // item name/description as printed
      "qty": number | null,       // quantity purchased, or null if not legible/not printed
      "unit_cost": number | null  // price per unit in pesos, or null if not legible/not printed
    }
  ],
  "confidence": number            // 0.0-1.0, your overall confidence the amount+vendor are correct
}
Rules: Filipino receipts are often thermal/faded/handwritten. If the total is unclear, set amount to your best single guess and lower confidence. If you cannot read the receipt at all, set amount null and confidence below 0.2. Never invent a vendor you cannot see. For line_items, never invent a description you cannot see; leave qty/unit_cost null rather than guessing when illegible.`;

function parseExtraction(textOut: string): any {
  try {
    return JSON.parse(String(textOut).replace(/^```json\s*|\s*```$/g, '').trim());
  } catch {
    return { amount: null, currency: 'PHP', date: null, vendor: null,
             category_hint: 'other', line_items: [], confidence: 0 };
  }
}

async function extractReceipt(b64: string, mime: string, prompt = EXTRACTION_PROMPT): Promise<{ parsed: any; raw: string }> {
  const raw = await visionExtractText(prompt, b64, mime, 'Cascade Finance OCR');
  return { parsed: parseExtraction(raw), raw };
}


// s89 mode "extract": keep the photo in expense-receipts and read it, but create NO transaction. The Manage hub pre-fills its form from this
// and saves through admin_save_transaction_v1 (receipt_image_path). A failed read still returns the stored path so the receipt can be attached by hand.
// deno-lint-ignore no-explicit-any
async function extractMode(body: any, who: StaffIdentity): Promise<Response> {
  const img = decodeImage(body.image_base64, body.mime_type);
  if (!img.ok) return json({ ok: false, error: img.error }, img.status);
  const db = createClient(SUPABASE_URL, SERVICE_ROLE);
  const path = receiptPath(PROPERTY_ID, who.userId, img.ext, crypto.randomUUID());
  const up = await db.storage.from(RECEIPTS_BUCKET).upload(path, img.bytes, { contentType: img.mime, upsert: false });
  if (up.error) { console.warn('ocr_extract_upload_failed', up.error.message); return json({ ok: false, error: 'upload_failed' }, 500); }
  const { data: cats } = await db.from('expense_categories').select('slug').eq('property_id', PROPERTY_ID).eq('is_active', true).order('sort_order');
  const slugs = (cats ?? []).map((c: { slug: string }) => c.slug);
  try {
    const r = await extractReceipt(bytesToBase64(img.bytes), img.mime, buildPrompt(EXTRACTION_PROMPT, slugs));
    const x = shapeExtraction(r.parsed, new Set(slugs));
    return json({ ok: true, receipt_path: path, amount: x.amount, date: x.date, vendor: x.vendor, category: x.category, line_items: x.line_items, confidence: x.confidence, raw: r.parsed });
  } catch (e) {
    console.warn('ocr_extract_failed', String(e).slice(0, 300));
    return json({ ok: false, error: 'ocr_failed', receipt_path: path }, 502);
  }
}

Deno.serve(withObservability({ functionName: 'ocr-receipt', route: 'finance' }, async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  // s89: staff only. verify_jwt lets the public anon key through, so check the signed-in user is owner/admin/finance for this property.
  let who: StaffIdentity;
  try { who = await requireStaffAccess(req, 'approve_payment', PROPERTY_ID); }
  catch (e) { const r = staffAuthResponse(e, CORS); if (r) return r; throw e; }
  if (!hasVisionKey()) {
    return json({ error: `no API key for VISION_PROVIDER=${PROVIDER}` }, 500);
  }

  let body: any;
  try { body = await req.json(); } catch { return json({ error: 'invalid_json' }, 400); }

  if (body.mode === 'extract') return await extractMode(body, who);

  const imagePath: string | null = body.image_path ? String(body.image_path) : null;
  const imageB64In: string | null = body.image_base64 ? String(body.image_base64) : null;
  const source = body.source === 'manual' ? 'manual' : 'ocr';
  const loggedBy = body.logged_by ? String(body.logged_by) : null;
  const tgChat = body.telegram_chat_id ?? null;
  const skipTgNotify = body.skip_telegram_notify === true;
  const extraNotes = body.notes ? String(body.notes).trim() : null;

  const db = createClient(SUPABASE_URL, SERVICE_ROLE);

  let b64: string;
  let mime = String(body.mime_type ?? 'image/jpeg');
  try {
    if (imageB64In) {
      b64 = imageB64In;
    } else if (imagePath) {
      const { data: blob, error } = await db.storage.from(RECEIPTS_BUCKET).download(imagePath);
      if (error || !blob) return json({ error: 'image_download_failed', detail: error?.message }, 404);
      mime = blob.type || mime;
      b64 = bytesToBase64(new Uint8Array(await blob.arrayBuffer()));
    } else {
      return json({ error: 'image_path_or_image_base64_required' }, 400);
    }
  } catch (e) {
    return json({ error: 'image_load_error', detail: String(e) }, 500);
  }

  if (mime === 'application/pdf') {
    return json({ error: 'pdf_not_supported_inline', hint: 'Send a photo of the receipt instead.' }, 415);
  }

  let extracted: any;
  try {
    const r = await extractReceipt(b64, mime);
    extracted = r.parsed;
  } catch (e) {
    if (tgChat && !skipTgNotify) await tgSend(tgChat, `⚠️ Receipt OCR failed: ${String(e).slice(0, 150)}`);
    return json({ error: 'ocr_failed', detail: String(e) }, 502);
  }

  const { data: cats } = await db.from('expense_categories')
    .select('slug').eq('property_id', PROPERTY_ID).eq('is_active', true);
  const validSlugs = new Set((cats ?? []).map((c: any) => c.slug));

  const amount = Number(extracted.amount);
  const grossAmount = isFinite(amount) && amount > 0 ? amount : 0;
  const category = mapCategory(extracted.category_hint, validSlugs);
  const confidence = clamp01(extracted.confidence);
  const txnDate = validDate(extracted.date);
  const vendor = extracted.vendor ? String(extracted.vendor).slice(0, 200) : null;
  const lineItems = normalizeLineItems(extracted.line_items);

  const notesParts = [extraNotes, formatLineItemsForNotes(lineItems)].filter(Boolean);

  const insertRow: Record<string, unknown> = {
    property_id: PROPERTY_ID,
    txn_type: 'expense',
    category,
    status: 'pending_review',
    source,
    gross_amount: grossAmount,
    payee_name: vendor,
    receipt_image_path: imagePath,
    ocr_confidence: confidence,
    ocr_raw: { ...extracted, line_items: lineItems },
    logged_by: loggedBy,
    notes: notesParts.length ? notesParts.join(' | ') : null,
  };
  if (txnDate) insertRow.transaction_date = txnDate;

  const { data: row, error: insErr } = await db.from('transactions')
    .insert(insertRow).select('id').single();
  if (insErr || !row) return json({ error: 'insert_failed', detail: insErr?.message }, 500);

  const refCode = row.id.slice(0, 8).toUpperCase();

  if (tgChat && !skipTgNotify) {
    const pct = Math.round(confidence * 100);
    const flag = confidence < 0.6 ? '⚠️ low confidence — please verify' : '';
    await tgSend(tgChat, [
      `🧾 *Receipt read — pending review*`,
      `₱${grossAmount.toLocaleString()} · ${category}`,
      ...(vendor ? [`🏷️ ${vendor}`] : []),
      ...(txnDate ? [`📅 ${txnDate}`] : []),
      `🎯 Confidence: ${pct}% ${flag}`.trim(),
      `🔖 Ref: ${refCode}`,
      ``,
      `_Confirm or correct it in the finance dashboard._`,
    ].join('\n'));
  }

  return json({
    ok: true,
    transaction_id: row.id,
    ref: refCode,
    status: 'pending_review',
    ocr_confidence: confidence,
    extracted: { amount: grossAmount, category, vendor, date: txnDate, line_items: lineItems },
  });
}));
