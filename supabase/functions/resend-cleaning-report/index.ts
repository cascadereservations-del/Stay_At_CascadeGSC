// resend-cleaning-report v1 (2026-09-16, session 22 item 4 follow-up)
//
// One-off admin tool: replay a historical cleaning_sessions row through the
// same GAS forward submit-cleaning uses, for turnover reports whose email
// silently never arrived (the v28 fix in submit-cleaning stops this
// happening again going forward; this repairs the backlog it left behind).
//
// Reconstructs the payload from stored data (cleaning_sessions,
// meter_readings, Storage) rather than replaying an original client
// request, since the original in-browser payload was never persisted.
// Fields the DB doesn't retain (startTime/endTime/elapsedTime) are sent as
// null -- Code.gs already treats missing values as "—" in the email, so
// this degrades gracefully rather than guessing.
//
// Deliberately NOT re-sent: the OPS Telegram report. Telegram already has
// these reports (confirmed live, D-142) -- only the email leg was missing.
//
// Auth: reuses CASCADE_CRON_SHARED_SECRET (same secret turnover-verifier
// already gates on) as a simple shared-secret check, since this is an
// admin-only replay tool, not a public endpoint. Lloyd runs the resend
// command himself with the real header value -- the agent never holds it.

import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { cronSecretMatches } from '../_shared/cron-auth.ts';
import { evaluateGasResponse } from '../submit-cleaning/gas-response.ts';

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, x-cascade-cron-secret' };
function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

const SECTION_ORDER: [string, string][] = [
  ['preclean', 'section_preclean'], ['afterclean', 'section_afterclean'],
  ['bedroom', 'section_bedroom'], ['kitchen', 'section_kitchen'],
  ['electric_meter', 'section_meter'], ['water_meter', 'section_meter'],
  ['issue_', 'section_issue'], ['condition', 'section_condition'],
];
function sectionFor(filename: string): string {
  for (const [needle, key] of SECTION_ORDER) if (filename.includes(needle)) return key;
  return 'section_other';
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);

  const cronSecret = Deno.env.get('CASCADE_CRON_SHARED_SECRET');
  if (cronSecret && !cronSecretMatches(cronSecret, req.headers.get('x-cascade-cron-secret'))) {
    return json({ ok: false, error: 'unauthorized' }, 401);
  }

  const body = await req.json().catch(() => ({}));
  const sessionId = String(body.session_id ?? '');
  if (!sessionId) return json({ ok: false, error: 'session_id required' }, 400);

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const GAS_URL = Deno.env.get('GAS_SCRIPT_URL');
  if (!GAS_URL) return json({ ok: false, error: 'GAS_SCRIPT_URL not configured' }, 500);

  const db = createClient(SUPABASE_URL, SERVICE_ROLE);

  const { data: session, error: sErr } = await db.from('cleaning_sessions').select('*').eq('id', sessionId).maybeSingle();
  if (sErr) return json({ ok: false, error: `cleaning_sessions: ${sErr.message}` }, 500);
  if (!session) return json({ ok: false, error: 'session not found' }, 404);

  const { data: meter } = await db.from('meter_readings').select('*').eq('session_id', sessionId).maybeSingle();

  const prefix = `${session.property_id}/${session.submitted_by_user_id}/${session.submission_id}`;
  const { data: files, error: listErr } = await db.storage.from('cleaning-photos').list(prefix, { limit: 200 });
  if (listErr) return json({ ok: false, error: `storage list: ${listErr.message}` }, 500);

  const photos: Record<string, { name: string; url: string; fileId: string }[]> = {};
  for (const f of files ?? []) {
    if (!f.name || f.name.endsWith('/')) continue;
    const path = `${prefix}/${f.name}`;
    const { data: signed, error: signErr } = await db.storage.from('cleaning-photos').createSignedUrl(path, 60 * 60 * 24 * 30);
    if (signErr || !signed?.signedUrl) { console.warn('sign_failed', f.name, signErr?.message); continue; }
    const key = sectionFor(f.name);
    (photos[key] ??= []).push({ name: f.name, url: signed.signedUrl, fileId: f.id ?? '' });
  }
  const photoCount = Object.values(photos).reduce((s, a) => s + a.length, 0);
  if (photoCount === 0) return json({ ok: false, error: 'no photos found for this session; refusing to send an email with no photos' }, 422);

  const payload = {
    cleaningDate: session.checkout_date,
    cleanerName: session.cleaner_name,
    formData: {
      cleanerName: session.cleaner_name,
      unitName: 'Cascade Bria',
      cleaningDate: session.checkout_date,
      startTime: null, endTime: null, elapsedTime: null,
      lastGuestName: session.last_guest_name,
      numberOfNights: session.nights_stayed,
    },
    lastGuestName: session.last_guest_name,
    numberOfNights: session.nights_stayed,
    electricReading: meter?.electric_curr ?? null,
    waterReading: meter?.water_curr ?? null,
    deltaKwh: meter?.electric_delta ?? null,
    deltaM3: meter?.water_delta ?? null,
    completionRate: session.completion_pct,
    meta: { rate: session.completion_pct, doneItems: null, totalItems: null },
    photos,
    checklistDetails: session.checklist_details ?? [],
    sectionNames: {
      section_preclean: 'Pre-Clean', section_afterclean: 'After-Clean',
      section_bedroom: 'Bedroom & Living Room', section_kitchen: 'Kitchen & Bathroom',
      section_meter: 'Meter Readings', section_issue: 'Flagged Issues',
      section_condition: 'Unit Condition', section_other: 'Other',
    },
    notesArr: session.notes ? [{ section: 'Notes', text: session.notes, isUrgent: (session.issue_count ?? 0) > 0 }] : [],
    urgentText: session.incomplete_reasons?.length ? session.incomplete_reasons.join('\n') : '',
    emailSubject: `🧹 Cleaning Report — Cascade Bria — ${session.checkout_date} — ${session.cleaner_name} (resent)`,
  };

  const res = await fetch(GAS_URL, {
    method: 'POST', headers: { 'Content-Type': 'text/plain;charset=utf-8' },
    body: JSON.stringify(payload), signal: AbortSignal.timeout(25_000),
  });
  const bodyText = await res.text().catch(() => '');
  const { failed, reason } = evaluateGasResponse(res.ok, res.status, bodyText);

  return json({
    ok: !failed, session_id: sessionId, gas_reason: failed ? reason : undefined,
    checkout_date: session.checkout_date, guest: session.last_guest_name,
    photo_sections: Object.keys(photos), photo_count: photoCount,
  }, failed ? 502 : 200);
});
