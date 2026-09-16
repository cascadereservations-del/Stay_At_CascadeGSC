// submit-cleaning v29
// v28 (2026-09-16): Lloyd reported turnover-report emails silently stopped
//   (~Sept 7) while Telegram kept working fine. Root cause: the GAS forward
//   (email + Drive + Calendar) was fire-and-forget — .catch(console.warn)
//   only, never awaited, response never inspected. Apps Script web apps
//   always return HTTP 200 even on a caught internal error, so checking
//   response.ok alone would not have caught it either; the JSON body's
//   `result` field has to be read. Now awaited and checked, alerting
//   Finance on failure. Same fix applied symmetrically to the OPS Telegram
//   dispatch, which had the identical silent-failure shape (tgPost caught
//   its own errors and only console.warn'd) — a dead bot token or a
//   kicked-from-group chat would have failed exactly as invisibly.
// Changes from v25:
// - MID-STAY (v7.8): cleaningType 'mid_stay' is a light refresh while the guest is
//   still in the unit. Completeness branch requires only MIDSTAY photo floor; no
//   turnover meter/electric/water requirement. Type label + finance label added.
//   v27: mid-stay photo floor raised 2->4 pre + 4 after (cover major areas).
// - RATE FIX: cleaner_rate_schedule lookup was querying non-existent columns
//   (cleaner_name/cleaning_type/rate_amount) and silently always falling back to
//   P500. Now reads the real schema: latest effective_from row, general_rate for
//   deep_clean, regular_rate for everything else (turnover/regular/mid_stay).
// - ADDITIONAL EXPENSES (v7.8): payload.extraExpenses[] -> one expense transaction
//   per line (category 'cleaning', source 'manual', logged_by cleaner). Admin-only.
//   A single Finance-group card summarises them. Non-blocking.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { requireStaffAccess, staffAuthResponse } from '../_shared/staff-auth.ts';
import { withObservability } from '../_shared/observability.ts';
import { evaluateGasResponse } from './gas-response.ts';
// v29 (session 26, 2026-09-16, Telegram plan §5/§6): OPS report and Finance cards open with the
//   shared header line; every [URGENT] note raises a work order (raise_work_order_v1, idempotent
//   per session + note index) and posts an OPS card with a lite-tier suggested action. The
//   cleaning session is recorded first; work-order failures only warn.
import { withHeader } from '../_shared/cascade-core/format.ts';
import { raiseWorkOrder, suggestFix, workOrderCard } from '../_shared/cascade-core/workorders.ts';

// This recovered function predates generated database types. Keep its helper
// boundary structurally untyped until a generated Database contract replaces it.
type LegacyDatabaseClient = { from: (relation: string) => any };

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

interface PhotoEntry {
  name?:   string;
  url?:    string;
  fileUrl?: string;
  fileId?: string;
  data?:   string;
}

interface ExtraExpense {
  amount?:      number | string;
  description?: string;
}

interface UtilityHistoryRow {
  kwh_per_night: number | string | null;
  m3_per_night: number | string | null;
}

interface Payload {
  propertyId?:               string;
  submissionId?:            string;
  cleaningDate?:            string;
  cleaningType?:            string;
  formData?:                Record<string, unknown>;
  electricReading?:         string | number;
  waterReading?:            string | number;
  previousElectricReading?: number | null;
  previousWaterReading?:    number | null;
  deltaKwh?:                number | null;
  deltaM3?:                 number | null;
  lastGuestName?:           string;
  numberOfNights?:          number;
  checkInDate?:             string;
  checkOutDate?:            string;
  completionRate?:          number;
  meta?:                    { rate?: number; doneItems?: number; totalItems?: number };
  checklistDetails?:        unknown;
  allNotes?:                unknown[];
  urgentItems?:             string;
  photos?:                  Record<string, PhotoEntry[]>;
  sessionFolderId?:         string;
  sessionFolderUrl?:        string;
  diagnostics?:             Record<string, unknown>;
  extraExpenses?:           ExtraExpense[];
  [key: string]: unknown;
}

// v28: returns whether the send actually landed, instead of only console.warn
// on failure — a Telegram failure was exactly as silent as the GAS/email one
// used to be (see the GAS-forward comment below), just never yet observed.
async function tgPost(token: string, method: string, body: Record<string, unknown>): Promise<{ ok: boolean; reason?: string }> {
  try {
    const resp = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
      signal:  AbortSignal.timeout(20_000),
    });
    if (!resp.ok) {
      const t = await resp.text().catch(() => '');
      console.warn(`tgPost ${method} failed ${resp.status}:`, t);
      return { ok: false, reason: `HTTP ${resp.status}: ${t.slice(0, 200)}` };
    }
    return { ok: true };
  } catch (err) {
    console.warn(`tgPost ${method} threw:`, err);
    return { ok: false, reason: String(err) };
  }
}

function typeLabelOf(cleaningType: string): string {
  return cleaningType === 'deep_clean' ? '\uD83E\uDDF9 DEEP CLEAN'
       : cleaningType === 'emergency'  ? '\uD83D\uDEA8 EMERGENCY'
       : cleaningType === 'mid_stay'   ? '\uD83D\uDECE\uFE0F MID-STAY'
       : '\uD83D\uDD04 TURNOVER';
}

function photoUrl(p: PhotoEntry): string | null {
  const u = p.fileUrl ?? p.url ?? null;
  return u && u.startsWith('http') ? u : null;
}

function countUploaded(photos: Record<string, PhotoEntry[]> | undefined, key: string): number {
  if (!photos || !Array.isArray(photos[key])) return 0;
  return photos[key].map(photoUrl).filter((u): u is string => u !== null).length;
}

async function refreshSignedPhotoUrls(
  supabase: any,
  photos: Record<string, PhotoEntry[]>,
): Promise<void> {
  const entries = Object.values(photos).flat();
  await Promise.all(entries.map(async (photo) => {
    const { data, error } = await supabase.storage
      .from('cleaning-photos')
      .createSignedUrl(String(photo.fileId), 3600);
    if (error || !data?.signedUrl) throw new Error('photo_access_refresh_failed');
    photo.fileUrl = data.signedUrl;
    delete photo.url;
    delete photo.data;
  }));
}

// Resolve cleaner fee from the real cleaner_rate_schedule schema.
// Latest effective_from <= today; general_rate for deep clean, regular_rate otherwise.
async function resolveFee(
  supabase:     LegacyDatabaseClient,
  propertyId:   string | null,
  cleaningType: string,
): Promise<number> {
  const FALLBACK = 500;
  try {
    let q = supabase
      .from('cleaner_rate_schedule')
      .select('regular_rate, general_rate, effective_from')
      .lte('effective_from', new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' }))
      .order('effective_from', { ascending: false })
      .limit(1);
    if (propertyId) q = q.eq('property_id', propertyId);
    const { data: row } = await q.maybeSingle();
    if (!row) return FALLBACK;
    const amt = cleaningType === 'deep_clean'
      ? Number(row.general_rate ?? row.regular_rate)
      : Number(row.regular_rate);
    return Number.isFinite(amt) && amt > 0 ? amt : FALLBACK;
  } catch (_) {
    return FALLBACK;
  }
}

async function dispatchTelegram(
  token:        string,
  chatId:       string,
  cleanerName:  string,
  unitName:     string,
  cleaningDate: string,
  cleaningType: string,
  startTime:    string,
  lastGuestName: string,
  nights:       number,
  checkInDate:  string | null,
  checkOutDate: string | null,
  completionPct: number,
  elecNum:      number,
  waterNum:     number,
  deltaKwh:     number | null,
  deltaM3:      number | null,
  urgentItems:  string,
  photos:       Record<string, PhotoEntry[]> | undefined,
): Promise<{ ok: boolean; reason?: string }> {

  const elecStr   = !isNaN(elecNum)  ? `${elecNum} kWh`  : '\u2014';
  const waterStr  = !isNaN(waterNum) ? `${waterNum} m\u00b3` : '\u2014';
  const dElec     = deltaKwh !== null ? ` (\u0394${deltaKwh >= 0 ? '+' : ''}${deltaKwh.toFixed(1)} kWh)` : '';
  const dWat      = deltaM3  !== null ? ` (\u0394${deltaM3  >= 0 ? '+' : ''}${deltaM3.toFixed(2)} m\u00b3)` : '';
  const typeLabel = typeLabelOf(cleaningType);
  const isMidStay = cleaningType === 'mid_stay';
  const hasUrgent = (urgentItems ?? '').trim().length > 0;
  const completion = completionPct >= 100 ? `\u2705 ${completionPct}%` : `\u26A0\uFE0F ${completionPct}%`;
  const guestLabel = isMidStay ? '\uD83D\uDC65 Current Guest' : '\uD83D\uDC65 Last Guest';

  const lines: string[] = [
    `\uD83E\uDDF9 *Cleaning Report Submitted*`,
    `\uD83D\uDCCD ${unitName}  \u2022  ${typeLabel}`,
    ``,
    `\uD83D\uDC64 Cleaner: ${cleanerName}`,
    `\uD83D\uDCC5 Date: ${cleaningDate}${startTime ? '  \u2022  ' + startTime : ''}`,
    `${guestLabel}: ${lastGuestName}`,
    ...(nights > 0 && !isMidStay ? [`\uD83C\uDF19 Nights: ${nights}`]         : []),
    ...(checkOutDate && !isMidStay ? [`\uD83D\uDCE4 Check-out: ${checkOutDate}`]: []),
    ...(isMidStay ? [`\uD83D\uDECE\uFE0F Mid-stay refresh (guest still in unit)`] : []),
    ``,
    ...(!isMidStay ? [
      `\u26A1 Electric: ${elecStr}${dElec}`,
      `\uD83D\uDCA7 Water: ${waterStr}${dWat}`,
      ``,
    ] : []),
    `${completion} Completion: ${completionPct}%`,
    ...(hasUrgent ? [``, `\u26A0\uFE0F *Issues flagged:*`, urgentItems] : []),
    ``,
    `\uD83D\uDCF8 Full photo set emailed + archived to Drive.`,
  ];

  const sent = await tgPost(token, 'sendMessage', { chat_id: chatId, text: withHeader('cleaning', `${isMidStay ? 'mid-stay' : 'report'} ${cleaningDate}`, lines.join('\n')), parse_mode: 'Markdown' });
  if (!sent.ok) return sent;

  if (!photos || typeof photos !== 'object') return sent;
  const meterUrls = (photos['section_meter'] ?? []).map(photoUrl).filter((u): u is string => u !== null);
  if (meterUrls.length === 0) return sent;

  const meterCap = `\uD83D\uDCF7 Meter Readings \u2014 ${cleaningDate} (${cleanerName})`;
  if (meterUrls.length === 1) {
    await tgPost(token, 'sendPhoto', { chat_id: chatId, photo: meterUrls[0], caption: meterCap });
  } else {
    const media = meterUrls.slice(0, 10).map((url, i) => ({
      type:  'photo',
      media: url,
      ...(i === 0 ? { caption: meterCap } : {}),
    }));
    await tgPost(token, 'sendMediaGroup', { chat_id: chatId, media });
  }
  return sent;
}

async function dispatchFinanceCard(
  supabase:       LegacyDatabaseClient,
  tgToken:        string,
  tgFinanceId:    string,
  propertyId:     string | null,
  cleanerName:    string,
  unitName:       string,
  cleaningDate:   string,
  cleaningType:   string,
  isComplete:     boolean,
  reasons:        string[],
  precleanCount:  number,
  aftercleanCount: number,
  meterCount:     number,
  totalPhotoCount: number,
): Promise<void> {
  if (!tgToken || !tgFinanceId) return;

  const typeLabel = typeLabelOf(cleaningType);

  if (isComplete) {
    const feeAmount = await resolveFee(supabase, propertyId, cleaningType);

    const lines = [
      `\uD83E\uDDF9 *Cleaning Complete \u2014 ${unitName}*`,
      `\uD83D\uDCC5 ${cleaningDate}  \u00b7  ${typeLabel}`,
      `\uD83D\uDC64 Cleaner: ${cleanerName}`,
      ``,
      `\uD83D\uDCF7 Photos: ${totalPhotoCount} total  (pre:${precleanCount} | after:${aftercleanCount} | meter:${meterCount})`,
      `\u2705 Completion: 100%`,
      ``,
      `\uD83D\uDCB0 *Fee due: \u20B1${feeAmount}*`,
      `\u2139\uFE0F Send /payclean to issue payment card.`,
    ];
    await tgPost(tgToken, 'sendMessage', {
      chat_id:    tgFinanceId,
      text:       withHeader('finance', `cleaning fee ${cleaningDate}`, lines.join('\n')),
      parse_mode: 'Markdown',
    });
  } else {
    const reasonList = reasons.map(r => `\u2022 ${r}`).join('\n');
    const lines = [
      `\uD83E\uDDF9 *Cleaning Incomplete \u2014 ${unitName}*`,
      `\uD83D\uDCC5 ${cleaningDate}  \u00b7  ${typeLabel}`,
      `\uD83D\uDC64 Cleaner: ${cleanerName}`,
      ``,
      `\u26A0\uFE0F *Missing items:*`,
      reasonList,
      ``,
      `\uD83D\uDCF7 Photos: ${totalPhotoCount} total  (pre:${precleanCount} | after:${aftercleanCount} | meter:${meterCount})`,
      `\u274C No fee card sent \u2014 resolve incomplete items first.`,
    ];
    await tgPost(tgToken, 'sendMessage', {
      chat_id:    tgFinanceId,
      text:       withHeader('attention', `cleaning incomplete ${cleaningDate}`, lines.join('\n')),
      parse_mode: 'Markdown',
    });
  }
}

// v7.8: insert cleaner-incurred expenses and send a single Finance summary card.
async function processExtraExpenses(
  supabase:     LegacyDatabaseClient,
  propertyId:   string | null,
  cleanerName:  string,
  cleaningDate: string,
  unitName:     string,
  raw:          ExtraExpense[] | undefined,
  tgToken:      string | undefined,
  tgFinanceId:  string | undefined,
  sessionId:    string,
  submitterId:  string,
): Promise<void> {
  if (!Array.isArray(raw) || raw.length === 0) return;

  const clean = raw
    .map(x => ({ amount: Number(x.amount), description: String(x.description ?? '').trim() }))
    .filter(x => Number.isFinite(x.amount) && x.amount > 0 && x.description.length > 0);
  if (clean.length === 0) return;

  const txnDate = cleaningDate && /^\d{4}-\d{2}-\d{2}$/.test(cleaningDate)
    ? cleaningDate
    : new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' });

  if (!propertyId) return;
  const rows = clean.map(x => ({
    property_id:             propertyId,
    cleaning_session_id:     sessionId,
    submitted_by_user_id:    submitterId,
    expense_date:            txnDate,
    amount:                  x.amount,
    currency:                'PHP',
    description:             x.description,
    status:                  'pending_review',
  }));

  const { error } = await supabase.from('cleaning_expense_claims').insert(rows);
  if (error) {
    console.warn('[extra-expenses] insert non-fatal:', error.message);
    return;
  }

  if (tgToken && tgFinanceId) {
    const total = clean.reduce((s, x) => s + x.amount, 0);
    const list  = clean.map(x => `\u2022 \u20B1${x.amount.toFixed(2)} \u2014 ${x.description}`).join('\n');
    const lines = [
      `\uD83E\uDDFE *Cleaning Expense Claims \u2014 ${unitName}*`,
      `\uD83D\uDCC5 ${cleaningDate}  \u00b7  \uD83D\uDC64 ${cleanerName}`,
      ``,
      list,
      ``,
      `\uD83D\uDCB0 *Total to reimburse: \u20B1${total.toFixed(2)}*`,
      `\u2139\uFE0F Pending Finance review. No ledger transaction was created.`,
    ];
    await tgPost(tgToken, 'sendMessage', {
      chat_id:    tgFinanceId,
      text:       lines.join('\n'),
      parse_mode: 'Markdown',
    }).catch(err => console.warn('[extra-expenses] card non-fatal:', err));
  }
}

async function checkUtilityAnomaly(
  supabase:       LegacyDatabaseClient,
  propertyId:     string,
  sessionId:      string,
  kwhPerNight:    number | null,
  m3PerNight:     number | null,
  cleaningDate:   string,
  cleanerName:    string,
  nights:         number,
  deltaKwh:       number | null,
  deltaM3:        number | null,
  tgToken:        string,
  tgFinanceId:    string,
): Promise<void> {
  if (!tgToken || !tgFinanceId) return;
  if (kwhPerNight === null && m3PerNight === null) return;

  try {
    const { data: rows, error } = await supabase
      .from('meter_readings')
      .select('kwh_per_night, m3_per_night')
      .eq('property_id', propertyId)
      .neq('session_id', sessionId)
      .gte('recorded_at', new Date(Date.now() - 90 * 24 * 3600 * 1000).toISOString())
      .gt('kwh_per_night', 0)
      .not('kwh_per_night', 'is', null);

    if (error || !rows || rows.length < 3) {
      console.log(`[anomaly] skipped: ${rows?.length ?? 0} samples (need \u22653)`);
      return;
    }

    const samples = rows as UtilityHistoryRow[];
    const meanKwh = samples.reduce((s, r) => s + Number(r.kwh_per_night), 0) / samples.length;
    const meanM3  = samples.filter(r => r.m3_per_night !== null)
                        .reduce((s, r) => s + Number(r.m3_per_night), 0)
                  / (samples.filter(r => r.m3_per_night !== null).length || 1);

    const THRESHOLD = 2.0;
    const elecFlag  = kwhPerNight !== null && kwhPerNight > meanKwh  * THRESHOLD;
    const waterFlag = m3PerNight  !== null && m3PerNight  > meanM3   * THRESHOLD;

    if (!elecFlag && !waterFlag) return;

    const lines: string[] = [
      `\u26A1\uD83D\uDCA7 *Utility Anomaly Detected*`,
      `\uD83D\uDCCD Cascade Hideaway`,
      `\uD83D\uDCC5 ${cleaningDate}  \u00b7  \uD83E\uDDF9 ${cleanerName}  \u00b7  \uD83C\uDF19 ${nights}n`,
      ``,
    ];

    if (elecFlag) lines.push(
      `\u26A1 *Electricity HIGH*`,
      `   This stay:  ${kwhPerNight!.toFixed(1)} kWh/night (\u0394${(deltaKwh ?? 0).toFixed(1)} kWh total)`,
      `   90-day avg: ${meanKwh.toFixed(1)} kWh/night`,
      `   Ratio:      ${(kwhPerNight! / meanKwh).toFixed(1)}\u00d7 \u2014 exceeds 2\u00d7 threshold`,
      ``,
    );

    if (waterFlag) lines.push(
      `\uD83D\uDCA7 *Water HIGH*`,
      `   This stay:  ${m3PerNight!.toFixed(2)} m\u00b3/night (\u0394${(deltaM3 ?? 0).toFixed(2)} m\u00b3 total)`,
      `   90-day avg: ${meanM3.toFixed(2)} m\u00b3/night`,
      `   Ratio:      ${(m3PerNight! / meanM3).toFixed(1)}\u00d7 \u2014 exceeds 2\u00d7 threshold`,
      ``,
    );

    lines.push(`_Check meter photos and guest behaviour. May indicate leak, forgotten AC, or metering error._`);

    await tgPost(tgToken, 'sendMessage', {
      chat_id:    tgFinanceId,
      text:       lines.join('\n'),
      parse_mode: 'Markdown',
    });

  } catch (e) {
    console.warn('[anomaly] check non-fatal:', e);
  }
}

Deno.serve(withObservability({ functionName: 'submit-cleaning', route: 'ops' }, async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  try {
    const payload: Payload = await req.json();

    const propertyId = String(payload.propertyId ?? '');
    if (!payload.submissionId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload.submissionId)) {
      return json({ ok: false, error: 'valid_submission_id_required' }, 400);
    }
    const identity = await requireStaffAccess(req, 'submit_cleaning', propertyId);

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false } }
    );

    if (payload.submissionId) {
      const { count } = await supabase
        .from('cleaning_sessions')
        .select('id', { count: 'exact', head: true })
        .eq('submission_id', payload.submissionId);
      if ((count ?? 0) > 0) {
        return json({ ok: true, status: 'duplicate_ignored', message: 'Already recorded.' });
      }
    }

    const fd            = (payload.formData ?? {}) as Record<string, unknown>;
    const cleanerName   = String(fd.cleanerName   ?? payload.cleanerName   ?? '\u2014');
    const unitName      = String(fd.unitName      ?? 'Cascade Bria');
    const cleaningType  = String(payload.cleaningType ?? fd.cleaningType ?? 'turnover');
    const isMidStay     = cleaningType === 'mid_stay';
    const cleaningDate  = String(payload.cleaningDate ?? fd.cleaningDate ?? new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Manila' }));
    const startTime     = String(fd.startTime ?? payload.startTime ?? '') || '';
    const checkInDate   = String(fd.checkInDate   ?? payload.checkInDate  ?? '') || null;
    const checkOutDate  = String(fd.checkOutDate  ?? payload.checkOutDate ?? '') || null;
    const lastGuestName = String(fd.lastGuestName ?? payload.lastGuestName ?? '\u2014');
    const nights        = Number(fd.numberOfNights ?? payload.numberOfNights ?? 0);
    const completionPct = Number(payload.completionRate ?? payload.meta?.rate ?? 0);
    const notes         = Array.isArray(payload.allNotes)
      ? payload.allNotes.map((n: unknown) => {
          const note = n as Record<string, unknown>;
          return `[${note.section ?? ''}]: ${note.isUrgent ? '[URGENT] ' : ''}${note.text ?? ''}`;
        }).join('\n')
      : '';

    const elecNum  = parseFloat(String(payload.electricReading ?? ''));
    const waterNum = parseFloat(String(payload.waterReading    ?? ''));
    const deltaKwh = typeof payload.deltaKwh === 'number' ? payload.deltaKwh : null;
    const deltaM3  = typeof payload.deltaM3  === 'number' ? payload.deltaM3  : null;
    const kwhPerNight = (deltaKwh !== null && nights > 0) ? Number((deltaKwh / nights).toFixed(2)) : null;
    const m3PerNight  = (deltaM3  !== null && nights > 0) ? Number((deltaM3  / nights).toFixed(3)) : null;
    const urgentItems = String(payload.urgentItems ?? '');

    const ph = (payload.photos ?? {}) as Record<string, PhotoEntry[]>;
    const expectedPhotoPrefix = `${propertyId}/${identity.userId}/${payload.submissionId}/`;
    const invalidPhoto = Object.values(ph).flat().some((photo) =>
      !photo.fileId || !String(photo.fileId).startsWith(expectedPhotoPrefix)
    );
    if (invalidPhoto) return json({ ok: false, error: 'invalid_photo_scope' }, 400);
    await refreshSignedPhotoUrls(supabase, ph);
    const precleanCount   = countUploaded(ph, 'section_preclean');
    const aftercleanCount = countUploaded(ph, 'section_afterclean');
    const meterCount      = countUploaded(ph, 'section_meter');
    const otherCount      = Object.keys(ph)
      .filter(k => !['section_preclean', 'section_afterclean', 'section_meter'].includes(k))
      .reduce((s, k) => s + countUploaded(ph, k), 0);
    const totalPhotoCount = precleanCount + aftercleanCount + meterCount + otherCount;
    const issueCount      = Array.isArray(payload.allNotes)
      ? payload.allNotes.filter((n) => (n as Record<string, unknown>).isUrgent === true).length
      : 0;

    const reasons: string[] = [];
    if (cleaningType === 'emergency') {
      if (totalPhotoCount < 2) reasons.push(`emergency_photos_short_${totalPhotoCount}_of_2`);
      if (!urgentItems.trim() && issueCount === 0) reasons.push('emergency_no_issue_note');
    } else if (isMidStay) {
      // Mid-stay: guest in unit, no checkout. Cover the major areas (bed/living, CR,
      // kitchen, floors): 4 pre + 4 after. No meter/electric/water requirement.
      if (precleanCount   < 4) reasons.push(`midstay_preclean_short_${precleanCount}_of_4`);
      if (aftercleanCount < 4) reasons.push(`midstay_afterclean_short_${aftercleanCount}_of_4`);
    } else {
      if (precleanCount   < 5) reasons.push(`preclean_short_${precleanCount}_of_5`);
      if (aftercleanCount < 5) reasons.push(`afterclean_short_${aftercleanCount}_of_5`);
      if (meterCount      < 2) reasons.push(`meter_photos_${meterCount}_of_2`);
      if (isNaN(elecNum))  reasons.push('electric_reading_missing');
      if (isNaN(waterNum)) reasons.push('water_reading_missing');
    }
    const isComplete = reasons.length === 0;

    const { data: session, error: sessionErr } = await supabase
      .from('cleaning_sessions')
      .insert({
        submission_id:          payload.submissionId ?? null,
        cleaner_name:           cleanerName,
        cleaning_type:          cleaningType,
        cleaned_at:             new Date().toISOString(),
        last_guest_name:        lastGuestName,
        nights_stayed:          nights || null,
        checkin_date:           checkInDate,
        checkout_date:          checkOutDate,
        completion_pct:         completionPct,
        checklist_details:      payload.checklistDetails ?? null,
        notes:                  notes || null,
        session_folder_id:      payload.sessionFolderId ?? null,
        property_id:            propertyId,
        submitted_by_user_id:   identity.userId,
        preclean_photo_count:   precleanCount,
        afterclean_photo_count: aftercleanCount,
        meter_photo_count:      meterCount,
        other_photo_count:      otherCount,
        total_photo_count:      totalPhotoCount,
        issue_count:            issueCount,
        is_complete:            isComplete,
        incomplete_reasons:     reasons.length ? reasons : null,
      })
      .select('id')
      .single();

    if (sessionErr) throw sessionErr;
    const sessionId: string = session.id;

    // Insert diagnostics row (D) - admin-only, non-blocking
    if (payload.diagnostics && propertyId) {
      const diag = payload.diagnostics as Record<string, unknown>;
      supabase.from('cleaning_diagnostics').insert({
        session_id:          sessionId,
        property_id:         propertyId,
        submission_id:       payload.submissionId ?? null,
        user_agent:          diag.userAgent    ?? null,
        app_version:         diag.app_version  ?? null,
        session_duration_s:  typeof diag.session_duration_s === 'number' ? diag.session_duration_s : null,
        photos_failed:       typeof diag.photos_failed === 'number' ? diag.photos_failed : 0,
        upload_retry_count:  typeof diag.upload_retry_count === 'number' ? diag.upload_retry_count : 0,
      }).then(({ error }) => {
        if (error) console.warn('[diagnostics] insert non-fatal:', error.message);
      });
    }

    // v7.8: cleaner-incurred expenses -> transactions + finance card (non-blocking)
    const TG_TOKEN      = Deno.env.get('TELEGRAM_BOT_TOKEN');
    const TG_CHAT_ID    = Deno.env.get('TELEGRAM_CHAT_ID');
    const TG_FINANCE_ID = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');

    await processExtraExpenses(
      supabase, propertyId, cleanerName, cleaningDate, unitName,
      payload.extraExpenses, TG_TOKEN, TG_FINANCE_ID, sessionId, identity.userId,
    ).catch(err => console.warn('[extra-expenses] non-fatal:', err));

    let meterWritten = false;
    if (!isNaN(elecNum) || !isNaN(waterNum)) {
      const { error: meterErr } = await supabase.from('meter_readings').insert({
        session_id:     sessionId,
        electric_prev:  payload.previousElectricReading ?? null,
        electric_curr:  isNaN(elecNum)  ? null : elecNum,
        electric_delta: deltaKwh,
        water_prev:     payload.previousWaterReading ?? null,
        water_curr:     isNaN(waterNum) ? null : waterNum,
        water_delta:    deltaM3,
        kwh_per_night:  kwhPerNight,
        m3_per_night:   m3PerNight,
        recorded_at:    new Date().toISOString(),
        property_id:    propertyId,
        submitted_by_user_id: identity.userId,
      });
      if (meterErr) {
        console.error('meter_readings insert (non-fatal):', meterErr);
      } else {
        meterWritten = true;
      }
    }

    // Mid-stay does not establish a turnover baseline; skip anomaly check.
    if (!isMidStay && meterWritten && propertyId && TG_TOKEN && TG_FINANCE_ID && (kwhPerNight !== null || m3PerNight !== null)) {
      checkUtilityAnomaly(
        supabase, propertyId, sessionId,
        kwhPerNight, m3PerNight,
        cleaningDate, cleanerName, nights,
        deltaKwh, deltaM3,
        TG_TOKEN, TG_FINANCE_ID,
      ).catch(err => console.warn('[anomaly] non-fatal:', err));
    }

    if (TG_TOKEN && TG_FINANCE_ID) {
      dispatchFinanceCard(
        supabase, TG_TOKEN, TG_FINANCE_ID, propertyId,
        cleanerName, unitName, cleaningDate, cleaningType,
        isComplete, reasons,
        precleanCount, aftercleanCount, meterCount, totalPhotoCount,
      ).catch(err => console.warn('[finance-card] non-fatal:', err));
    }

    // v29: each [URGENT] note becomes a work order + OPS card (Telegram plan §6). Non-blocking.
    if (propertyId && Array.isArray(payload.allNotes)) {
      const urgent = payload.allNotes
        .map((n) => n as Record<string, unknown>)
        .filter((n) => n.isUrgent === true && String(n.text ?? '').trim());
      urgent.forEach((n, i) => {
        const issue = String(n.text).trim();
        const args = {
          sourceKind: 'cleaning_issue' as const, sourceRef: `cleaning_session:${sessionId}:${i + 1}`,
          title: issue, detail: `Cleaner note (${String(n.section ?? 'checklist')}) by ${cleanerName} on ${cleaningDate}${lastGuestName !== '—' ? ` after ${lastGuestName}` : ''}: ${issue}`,
          priority: 'high' as const, reporter: cleanerName, guestName: lastGuestName !== '—' ? lastGuestName : undefined,
        };
        raiseWorkOrder(supabase, args).then(async (wo) => {
          if (!wo?.created || !TG_TOKEN || !TG_CHAT_ID) return;
          const s = await suggestFix(issue, `reported by the cleaner on ${cleaningDate}${wo.next_checkin ? `, next guest arrives ${wo.next_checkin}` : ''}`);
          await tgPost(TG_TOKEN, 'sendMessage', { chat_id: TG_CHAT_ID, text: workOrderCard('cleaning', args, wo, s) });
        }).catch((err) => console.warn('[work-order] non-fatal:', err));
      });
    }

    if (TG_TOKEN && TG_CHAT_ID) {
      // v28: dispatchTelegram now reports whether the OPS message actually
      // landed. tgPost already caught its own errors and just console.warn'd
      // them before, so a dead bot token or a kicked-from-group chat failed
      // exactly as silently as the GAS/email path did — nobody would know
      // OPS never saw a report. On failure, alert Finance (a different chat,
      // same bot) instead of a console.warn nobody reads.
      dispatchTelegram(
        TG_TOKEN, TG_CHAT_ID,
        cleanerName, unitName, cleaningDate, cleaningType, startTime,
        lastGuestName, nights, checkInDate, checkOutDate,
        completionPct, elecNum, waterNum, deltaKwh, deltaM3,
        urgentItems,
        payload.photos as Record<string, PhotoEntry[]> | undefined,
      ).then(async (result) => {
        if (result.ok || !TG_FINANCE_ID) return;
        console.warn('Telegram OPS dispatch failed:', result.reason);
        await tgPost(TG_TOKEN, 'sendMessage', {
          chat_id: TG_FINANCE_ID,
          text: `⚠️ OPS Telegram report FAILED — ${unitName} · ${cleaningDate} · ${cleanerName}\nReason: ${result.reason ?? 'unknown'}\nThe cleaning session was recorded; the OPS group likely never saw this report.`,
        });
      }).catch(err => console.warn('Telegram dispatch non-fatal:', err));
    } else {
      console.warn('TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set');
    }

    const GAS_URL = Deno.env.get('GAS_SCRIPT_URL');
    if (GAS_URL) {
      const operationalPayload = { ...payload, extraExpenses: undefined };
      // v28: the GAS forward (email + Drive + Calendar) used to be fully
      // fire-and-forget — a rejected fetch just logged a console.warn nobody
      // reads, so the turnover-report email could silently stop for weeks
      // while Telegram (dispatched separately above) kept working fine,
      // exactly the failure Lloyd reported 2026-09-16. Apps Script web apps
      // always return HTTP 200, even for a caught internal error (doPost's
      // own try/catch returns {result:'error', message}), so response.ok
      // alone can't detect a failure — the JSON body's `result` field must
      // be checked too. Any failure now posts to Finance so it's visible the
      // same day, not discovered weeks later from a missing inbox email.
      fetch(GAS_URL, {
        method:  'POST',
        headers: { 'Content-Type': 'text/plain;charset=utf-8' },
        body:    JSON.stringify(operationalPayload),
        signal:  AbortSignal.timeout(25_000),
      }).then(async (res) => {
        const bodyText = await res.text().catch(() => '');
        const { failed, reason } = evaluateGasResponse(res.ok, res.status, bodyText);
        if (!failed) return;
        console.warn('GAS forward failed:', reason);
        if (TG_TOKEN && TG_FINANCE_ID) {
          await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              chat_id: TG_FINANCE_ID,
              text: `⚠️ Cleaning report email (GAS) FAILED — ${unitName} · ${cleaningDate} · ${cleanerName}\nReason: ${reason}\nThe Telegram report above still sent; the turnover-report email to cascadereservations@gmail.com likely did not.`,
            }),
            signal: AbortSignal.timeout(10_000),
          }).catch(() => {});
        }
      }).catch(async (err) => {
        console.warn('GAS forward non-fatal:', err);
        if (TG_TOKEN && TG_FINANCE_ID) {
          await fetch(`https://api.telegram.org/bot${TG_TOKEN}/sendMessage`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              chat_id: TG_FINANCE_ID,
              text: `⚠️ Cleaning report email (GAS) FAILED — ${unitName} · ${cleaningDate} · ${cleanerName}\nReason: ${String(err)}\nThe Telegram report above still sent; the turnover-report email to cascadereservations@gmail.com likely did not.`,
            }),
            signal: AbortSignal.timeout(10_000),
          }).catch(() => {});
        }
      });
    }

    return json({ ok: true, status: 'success', sessionId, is_complete: isComplete, message: 'Report recorded.' });

  } catch (err) {
    const authResponse = staffAuthResponse(err, CORS);
    if (authResponse) return authResponse;
    console.error('submit-cleaning fatal:', err);
    return json({ ok: false, error: String(err) }, 500);
  }
}));
