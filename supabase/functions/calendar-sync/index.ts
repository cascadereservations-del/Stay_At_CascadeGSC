import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { heartbeat } from '../_shared/heartbeat.ts';
import { classifyMissingAirbnbRows } from './horizon.ts';
import { confirmationCodeFrom, parseIcal, type ICalEvent } from './ical.ts';
import { BLOCK_ANSWERS, blockCardText, blocksOverdue, blocksToAsk, type CalRow } from './blocks.ts';
import { ackHash } from '../_shared/ack-hash.ts';

// calendar-sync v15 - Cascade Hideaway
//
// v15 (2026-09-25, SPEC-24, D-225/D-235/D-236): the feed is unfolded before parsing (ical.ts), so every
//   Airbnb row keeps its confirmation code; each row is linked to airbnb_reservations by that code
//   (recon_status 'matched') and takes its guest name from the link. An Airbnb block with no booking
//   behind it gets ONE Finance question (blocks.ts); the answer is a telegram-expense tap.
//
// SOURCE-CONTROL NOTE (2026-08-25): this function was deployed (v10, function
// version 21) but had no source in this repository. It was recovered from the
// Supabase Management API and committed to
// supabase/functions/calendar-sync/index.ts so the reaper defect below is
// reviewable.
//
// v14 (2026-09-16): Lloyd flagged the reconciliation note as redundant — a
//   single reap is always already explained by airbnb-email-sync's own
//   cancellation card (real bookings) or is one low-stakes transient block
//   (nothing else announces those, but they're not worth a ping either).
//   Only send when reaped > 1, matching the note's own "worth a look only if
//   unusually large" text, which was previously just a footnote nobody acted on.
// v13 (2026-09-09): Horizon guard. Airbnb's iCal is a rolling ~365-day window; the
// clipped tail of a block at the horizon gets a fresh uid daily, so v12 reaped and
// announced one phantom row every midnight. Rows within two days of the feed
// horizon are now skipped and uncounted; failed reap updates are uncounted too.
// v12 (2026-08-25): Reconciliation visibility. v11 auto-heals drift every run,
//   so there is no longer a persistent gap to alert on — but nothing told
//   anyone a gap had existed at all, which is exactly how the v10 defect went
//   unnoticed for months. Post a one-line note to the ops Telegram chat
//   (TELEGRAM_CHAT_ID, same var daily-digest already uses) whenever this run
//   actually reaps something. Silent in the common case (reaped === 0).
//   NOTE: this does NOT detect a dead cron job — a job that stops firing
//   can't alert about its own silence. That needs an external watchdog
//   (e.g. a separate healthcheck ping), which is a bigger decision left for
//   Lloyd rather than built here.
// v11 (2026-08-25): FIX - the reaper only ever considered status='confirmed'
//   rows, so an Airbnb event with status='blocked' that disappeared from the
//   iCal feed was never cancelled. Airbnb emits transient "Airbnb (Not
//   available)" blocks constantly, including a rolling one-night marker at the
//   far edge of the bookable window (~365 days out) with a fresh UID each day.
//   Those accumulated forever: by 2026-08-25 the table held 131 non-cancelled
//   airbnb rows against a live feed of 6, of which 94 were future-dated. The
//   public calendar showed the property as fully booked through 2027-08-26 and
//   the site could not take a single direct booking. The reaper now covers
//   'confirmed' and 'blocked' alike, still scoped to source='airbnb'.
// v10 (2026-07-02): Scope the cancel-reaper to source='airbnb'. Direct bookings live in
//   calendar_events too (uid='direct:<id>', source='direct') and are never in the Airbnb
//   iCal feed; without this filter, confirming a direct booking would let the reaper cancel
//   it on the next sync. Only Airbnb-sourced confirmed events are reaped now.
// v9: After upsert, reap confirmed upcoming events that vanished from the iCal feed
//     (Airbnb cancellations). Past events are never touched.
// v8: Backfill guest_name from airbnb_reservations on null-name rows.
// v7: Finance alert for net-new confirmed bookings.

const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function manilaDatetime(): string {
  return new Date().toLocaleString('en-PH', { timeZone: 'Asia/Manila', hour12: false });
}

async function tgSend(token: string, chatId: string, text: string): Promise<void> {
  await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ chat_id: chatId, text, parse_mode: 'Markdown' }),
    signal:  AbortSignal.timeout(15_000),
  }).catch(() => {});
}

/** A question card with buttons, plain text (a quoted Airbnb note must not break Markdown). */
async function tgAsk(token: string, chatId: string, text: string, keyboard: Array<Array<{ text: string; callback_data: string }>>): Promise<boolean> {
  const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true, reply_markup: { inline_keyboard: keyboard } }),
    signal:  AbortSignal.timeout(15_000),
  }).catch((e) => { console.warn('calendar-sync v15: tgAsk', String(e)); return null; });
  if (r && !r.ok) console.warn('calendar-sync v15: tgAsk non-ok', r.status, (await r.text().catch(() => '')).slice(0, 200));
  return !!r?.ok;
}

function nightsBetween(checkin: string, checkout: string): number {
  return Math.round(
    (new Date(checkout).getTime() - new Date(checkin).getTime()) / 86_400_000
  );
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const hb = heartbeat(supabase, 'calendar-sync-15m');
  await hb('started');
  try {
    const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {};
    const forceSync: boolean = body.force === true;

    const { data: props, error: propErr } = await supabase
      .from('properties').select('id').limit(1).single();
    if (propErr || !props) throw new Error('No property found');
    const propertyId: string = body.property_id ?? props.id;

    if (!forceSync) {
      const { data: lastSync } = await supabase
        .from('calendar_sync_log').select('synced_at')
        .eq('property_id', propertyId).eq('source', 'airbnb').eq('status', 'ok')
        .order('synced_at', { ascending: false }).limit(1).single();
      if (lastSync?.synced_at) {
        const age = Date.now() - new Date(lastSync.synced_at).getTime();
        if (age < 30 * 60 * 1000) {
          await hb('succeeded');
          return new Response(
            JSON.stringify({ skipped: true, reason: 'rate_limited', last_sync: lastSync.synced_at }),
            { headers: { ...CORS, 'Content-Type': 'application/json' } },
          );
        }
      }
    }

    const { data: existingConfirmed } = await supabase
      .from('calendar_events').select('uid')
      .eq('property_id', propertyId).eq('status', 'confirmed');
    const preConfirmedUids = new Set<string>((existingConfirmed ?? []).map(r => r.uid));

    const { data: setting, error: settingErr } = await supabase
      .from('app_settings').select('value').eq('key', 'airbnb_ical_url').single();
    if (settingErr || !setting?.value) throw new Error('airbnb_ical_url not found in app_settings');
    const icalUrl: string = setting.value;

    const icalResp = await fetch(icalUrl);
    if (!icalResp.ok) throw new Error(`iCal fetch failed: ${icalResp.status}`);
    const icalText = await icalResp.text();
    const events = parseIcal(icalText);

    // v11 guard: never reap against a feed we failed to parse. An empty parse with a
    // 200 response (Airbnb maintenance page, truncated body) would otherwise
    // cancel every upcoming event and open the whole calendar.
    if (events.length === 0) {
      await supabase.from('calendar_sync_log').insert({
        property_id: propertyId, source: 'airbnb', event_count: 0, status: 'error',
        error_msg: 'iCal parsed to zero events; skipped upsert and reap',
      });
      return new Response(
        JSON.stringify({ ok: false, error: 'ical_parsed_empty', events_parsed: 0 }),
        { status: 502, headers: { ...CORS, 'Content-Type': 'application/json' } },
      );
    }

    let upserted = 0;
    const newlyConfirmed: ICalEvent[] = [];

    for (const ev of events) {
      if (!ev.uid || !ev.checkin || !ev.checkout) continue;
      const { error: upsertErr } = await supabase
        .from('calendar_events')
        .upsert({
          property_id: propertyId, uid: ev.uid, source: 'airbnb',
          checkin_date: ev.checkin, checkout_date: ev.checkout,
          status: ev.status, raw_summary: ev.summary ?? null,
          raw_description: ev.description ?? null,
          synced_at: new Date().toISOString(),
        }, { onConflict: 'uid,property_id', ignoreDuplicates: false });
      if (!upsertErr) {
        upserted++;
        if (ev.status === 'confirmed' && !preConfirmedUids.has(ev.uid)) {
          newlyConfirmed.push(ev);
        }
      }
    }

    // -- v9/v10/v11: Reap Airbnb events that vanished from the feed -----------
    // Any UPCOMING airbnb event absent from the current iCal feed was cancelled,
    // altered, or un-blocked on Airbnb.
    //
    // v11: 'blocked' is included alongside 'confirmed'. v10 reaped only
    // 'confirmed', which is why transient Airbnb blocks piled up indefinitely
    // and eventually made the whole public calendar look fully booked.
    //
    // Still scoped to source='airbnb' so direct holds (source='direct', never in
    // the feed) are untouched. Past events are left alone.
    //
    // v13: the feed is a rolling ~365-day window. A long block that crosses the
    // horizon is emitted as a clipped one-night tail with a fresh uid every day,
    // so yesterday's tail "vanishes" each midnight and v12 reaped and announced
    // it daily. Rows within two days of the feed's own horizon are left alone
    // and not counted. A reap whose update fails is no longer counted either.
    const today = new Date().toISOString().slice(0, 10);
    let reaped = 0;
    let horizonSkipped = 0;
    let horizonGuard: string | null = null;
    try {
      const { data: upcoming } = await supabase
        .from('calendar_events').select('id,uid,status,checkin_date')
        .eq('property_id', propertyId).eq('source', 'airbnb')
        .in('status', ['confirmed', 'blocked'])
        .gte('checkout_date', today);
      const classification = classifyMissingAirbnbRows(events, upcoming ?? []);
      horizonSkipped = classification.horizonSkipped;
      horizonGuard = classification.horizonGuard;
      for (const row of classification.rowsToReap) {
        const { error: reapUpdateErr } = await supabase.from('calendar_events')
          .update({ status: 'cancelled', synced_at: new Date().toISOString() })
          .eq('id', row.id);
        if (reapUpdateErr) { console.warn('calendar-sync v14: reap update failed for', row.uid, reapUpdateErr.message); continue; }
        reaped++;
      }
      if (reaped > 0) console.log(`calendar-sync v14: reaped ${reaped} stale event(s)`);
      if (horizonSkipped > 0) console.log(`calendar-sync v14: ${horizonSkipped} horizon-tail row(s) left alone (feed horizon ${classification.feedHorizon || 'unavailable'})`);
    } catch (reapErr) {
      console.warn('calendar-sync v14: reap step failed (non-fatal):', String(reapErr));
    }

    // -- v15: Link each Airbnb row to its reservation by confirmation code ----
    // The code is exact where the old date match was a guess, and it is what V7 (dates disagree) and
    // V7b (no booking e-mail) judge. A code with no reservation yet is left pending: the e-mail usually
    // lands within hours, and V7b speaks only after 24.
    let linked = 0;
    try {
      const codeByUid = new Map<string, string>();
      for (const ev of events) { const c = confirmationCodeFrom(ev.description); if (c) codeByUid.set(ev.uid, c); }
      if (codeByUid.size > 0) {
        const [{ data: resRows, error: resErr }, { data: calRows, error: calErr }] = await Promise.all([
          supabase.from('airbnb_reservations').select('id,confirmation_code,guest_name').in('confirmation_code', [...new Set(codeByUid.values())]),
          supabase.from('calendar_events').select('id,uid,guest_name,linked_reservation_id').eq('property_id', propertyId).in('uid', [...codeByUid.keys()]),
        ]);
        if (resErr || calErr) throw new Error((resErr ?? calErr)!.message);
        const resByCode = new Map((resRows ?? []).map((r) => [r.confirmation_code as string, r]));
        for (const ce of calRows ?? []) {
          const res = resByCode.get(codeByUid.get(ce.uid)!);
          if (!res) continue;
          const patch: Record<string, unknown> = {};
          if (ce.linked_reservation_id !== res.id) Object.assign(patch, { linked_reservation_id: res.id, recon_status: 'matched' });
          if (!ce.guest_name && res.guest_name) patch.guest_name = res.guest_name;
          if (Object.keys(patch).length === 0) continue;
          const { error: linkErr } = await supabase.from('calendar_events').update(patch).eq('id', ce.id);
          if (linkErr) { console.warn('calendar-sync v15: link failed for', ce.uid, linkErr.message); continue; }
          if (patch.linked_reservation_id) linked++;
        }
      }
    } catch (linkStepErr) {
      console.warn('calendar-sync v15: link step failed (non-fatal):', String(linkStepErr));
    }

    // -- v8: Backfill guest_name from airbnb_reservations (fallback for unlinked rows) ---
    let guestNamesBackfilled = 0;
    try {
      const { data: nullNameEvs } = await supabase
        .from('calendar_events').select('id,checkin_date,checkout_date')
        .eq('property_id', propertyId).is('guest_name', null);
      if (nullNameEvs && nullNameEvs.length > 0) {
        const { data: resNames } = await supabase
          .from('airbnb_reservations').select('guest_name,checkin_date,checkout_date')
          .not('guest_name', 'is', null);
        const resMap = new Map<string, string>();
        for (const r of resNames ?? []) {
          resMap.set(`${r.checkin_date}:${r.checkout_date}`, r.guest_name);
        }
        for (const ce of nullNameEvs) {
          const name = resMap.get(`${ce.checkin_date}:${ce.checkout_date}`);
          if (name) {
            await supabase.from('calendar_events')
              .update({ guest_name: name, updated_at: new Date().toISOString() }).eq('id', ce.id);
            guestNamesBackfilled++;
          }
        }
      }
    } catch (backfillErr) {
      console.warn('calendar-sync v14: guest_name backfill failed:', String(backfillErr));
    }

    await supabase.from('calendar_sync_log').insert({
      property_id: propertyId, source: 'airbnb', event_count: upserted, status: 'ok',
    });

    const tgToken     = Deno.env.get('TELEGRAM_BOT_TOKEN');
    const tgFinanceId = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
    const tgOpsId      = Deno.env.get('TELEGRAM_CHAT_ID');

    // v14 reconciliation note — see header. A single reap is always already
    // explained: either airbnb-email-sync just sent a full cancellation card
    // for the same booking, or it's one low-stakes Airbnb "not available"
    // block disappearing. Only escalate when more than one row goes at once,
    // which is the actually-unusual case this note exists to catch.
    if (tgToken && tgOpsId && reaped > 1) {
      const msg = [
        `🧹 *Calendar reconciliation*`,
        `📍 Cascade Hideaway`, ``,
        `${reaped} Airbnb calendar rows no longer in the live feed — marked cancelled.`,
        `This is automatic (calendar-sync v14). Worth a look since more than one went at once.`,
        `⏰ ${manilaDatetime()}`,
      ].join('\n');
      tgSend(tgToken, tgOpsId, msg).catch(() => {});
    }

    if (tgToken && tgFinanceId && newlyConfirmed.length > 0) {
      for (const ev of newlyConfirmed) {
        const nights = nightsBetween(ev.checkin, ev.checkout);
        const guestLabel = ev.summary?.trim() || 'Guest';
        const msg = [
          `📅 *New Airbnb Booking Confirmed*`,
          `📍 Cascade Hideaway`, ``,
          `👤 ${guestLabel}`,
          `📥 Check-in:  ${ev.checkin}`,
          `📤 Check-out: ${ev.checkout}`,
          `🌙 Nights:    ${nights}`, ``,
          `📃 Source: Airbnb iCal`,
          `💡 Payout reconciles via monthly CSV import.`,
          `🔖 UID: ${ev.uid.slice(-12)}`,
          `⏰ ${manilaDatetime()}`,
        ].join('\n');
        tgSend(tgToken, tgFinanceId, msg).catch(() => {});
      }
    }

    // -- v15: a block with no booking behind it is asked about once (D-236) ----
    let blocksAsked = 0;
    try {
      const { data: live, error: liveErr } = await supabase
        .from('calendar_events')
        .select('uid,source,status,checkin_date,checkout_date,recon_status,recon_alerted_at,raw_description')
        .eq('property_id', propertyId).neq('status', 'cancelled').gt('checkout_date', today);
      if (liveErr) throw new Error(liveErr.message);
      const rows = (live ?? []) as CalRow[];
      if (tgToken && tgFinanceId) {
        for (const b of blocksToAsk(rows, today, horizonGuard)) {
          const h = await ackHash(b.uid);
          const keyboard = BLOCK_ANSWERS.map((a) => [{ text: a.label, callback_data: `cb:block:${h}:${a.code}` }]);
          if (!(await tgAsk(tgToken, tgFinanceId, blockCardText(b), keyboard))) continue; // not stamped: asked again next run
          await supabase.from('calendar_events').update({ recon_alerted_at: new Date().toISOString() }).eq('property_id', propertyId).eq('uid', b.uid);
          blocksAsked++;
        }
      }
      // Unanswered for a week: one Follow-ups task each (D-218). An answer, or the block leaving the
      // calendar, closes it on the next run.
      const overdue = blocksOverdue(rows, today, new Date());
      for (const b of overdue) {
        await supabase.rpc('system_task_open_v1', {
          p_property_id: propertyId, p_source_kind: 'calendar_block', p_source_ref: b.uid,
          p_title: `Say what the Airbnb block ${b.checkin_date} to ${b.checkout_date} is`,
          p_detail: 'It is blocked on Airbnb and Cascade has no booking for it. Answer the card in Finance: maintenance or owner use, a direct booking, or unblock it.',
          p_priority: 'normal',
        });
      }
      await supabase.rpc('system_task_close_missing_v1', {
        p_source_kind: 'calendar_block', p_still_open: overdue.map((b) => b.uid), p_since: null,
        p_note: 'Closed automatically: the block was answered, booked or removed.',
      });
    } catch (blockErr) {
      console.warn('calendar-sync v15: block question step failed (non-fatal):', String(blockErr));
    }

    await hb('succeeded');
    return new Response(
      JSON.stringify({
        ok: true, events_parsed: events.length, events_upserted: upserted,
        new_confirmed: newlyConfirmed.length,
        cancelled_reaped: reaped,
        guest_names_backfilled: guestNamesBackfilled,
        linked, blocks_asked: blocksAsked,
      }),
      { headers: { ...CORS, 'Content-Type': 'application/json' } },
    );

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    await hb('failed', msg.slice(0, 80));
    try {
      const sErr = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
      const { data: p } = await sErr.from('properties').select('id').limit(1).single();
      if (p) await sErr.from('calendar_sync_log').insert({ property_id: p.id, source: 'airbnb', status: 'error', error_msg: msg });
    } catch { /* best-effort */ }
    return new Response(JSON.stringify({ ok: false, error: msg }), { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
});
