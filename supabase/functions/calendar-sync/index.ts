import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';

// calendar-sync v11 - Cascade Hideaway
//
// SOURCE-CONTROL NOTE (2026-08-25): this function was deployed (v10, function
// version 21) but had no source in this repository. It was recovered from the
// Supabase Management API and committed to
// supabase/functions/calendar-sync/index.ts so the reaper defect below is
// reviewable.
//
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
    const uidsInFeed = new Set<string>(events.map(e => e.uid));
    const today = new Date().toISOString().slice(0, 10);
    let reaped = 0;
    try {
      const { data: upcoming } = await supabase
        .from('calendar_events').select('id,uid,status')
        .eq('property_id', propertyId).eq('source', 'airbnb')
        .in('status', ['confirmed', 'blocked'])
        .gte('checkout_date', today);
      for (const row of upcoming ?? []) {
        if (!uidsInFeed.has(row.uid)) {
          await supabase.from('calendar_events')
            .update({ status: 'cancelled', synced_at: new Date().toISOString() })
            .eq('id', row.id);
          reaped++;
        }
      }
      if (reaped > 0) console.log(`calendar-sync v11: reaped ${reaped} stale event(s)`);
    } catch (reapErr) {
      console.warn('calendar-sync v11: reap step failed (non-fatal):', String(reapErr));
    }

    // -- v8: Backfill guest_name from airbnb_reservations -----------
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
      console.warn('calendar-sync v11: guest_name backfill failed:', String(backfillErr));
    }

    await supabase.from('calendar_sync_log').insert({
      property_id: propertyId, source: 'airbnb', event_count: upserted, status: 'ok',
    });

    const tgToken     = Deno.env.get('TELEGRAM_BOT_TOKEN');
    const tgFinanceId = Deno.env.get('TELEGRAM_FINANCE_CHAT_ID');
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

    return new Response(
      JSON.stringify({
        ok: true, events_parsed: events.length, events_upserted: upserted,
        new_confirmed: newlyConfirmed.length,
        cancelled_reaped: reaped,
        guest_names_backfilled: guestNamesBackfilled,
      }),
      { headers: { ...CORS, 'Content-Type': 'application/json' } },
    );

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    try {
      const sErr = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
      const { data: p } = await sErr.from('properties').select('id').limit(1).single();
      if (p) await sErr.from('calendar_sync_log').insert({ property_id: p.id, source: 'airbnb', status: 'error', error_msg: msg });
    } catch { /* best-effort */ }
    return new Response(JSON.stringify({ ok: false, error: msg }), { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
});

interface ICalEvent { uid: string; checkin: string; checkout: string; summary?: string; description?: string; status: 'confirmed' | 'blocked'; }

function parseIcal(text: string): ICalEvent[] {
  const events: ICalEvent[] = [];
  const blocks = text.split('BEGIN:VEVENT');
  for (let i = 1; i < blocks.length; i++) {
    const block = blocks[i].split('END:VEVENT')[0];
    const uid = extractProp(block, 'UID');
    const dtstart = extractProp(block, 'DTSTART');
    const dtend = extractProp(block, 'DTEND');
    const summary = extractProp(block, 'SUMMARY');
    const description = extractProp(block, 'DESCRIPTION');
    if (!uid || !dtstart || !dtend) continue;
    const checkin = normalizeDate(dtstart);
    const checkout = normalizeDate(dtend);
    if (!checkin || !checkout) continue;
    const lsum = (summary ?? '').toLowerCase();
    const status: 'confirmed' | 'blocked' = lsum.includes('not available') || lsum.includes('blocked') || lsum === '' ? 'blocked' : 'confirmed';
    events.push({ uid, checkin, checkout, summary, description, status });
  }
  return events;
}

function extractProp(block: string, key: string): string | undefined {
  const re = new RegExp(`^${key}(?:;[^:]+)?:(.+)$`, 'm');
  const m = block.match(re); return m ? m[1].trim() : undefined;
}

function normalizeDate(val: string): string | null {
  const clean = val.replace(/T.+$/, '').replace(/-/g, '');
  if (clean.length !== 8) return null;
  return `${clean.slice(0,4)}-${clean.slice(4,6)}-${clean.slice(6,8)}`;
}
