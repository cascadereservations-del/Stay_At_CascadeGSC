// expire-cleaning-photos v1 (session 72, SPEC-42 section 3 / SPEC-15 phase 2).
// Weekly, Monday 06:00 Manila (Sunday 22:00 UTC), from pg_cron through pg_net with x-cascade-cron-secret read from Vault.
// Moves nothing to Drive (Code.gs already did): it only removes the Supabase Storage copy of cleaning photos that are older than
// 90 days AND confirmed archived in Drive (expire.ts has the full rule). Deletes go through the Storage API, never SQL
// (a delete from storage.objects removes the row and leaves the bytes). At most 10 sessions per run.
//   POST                 dry run: reports what WOULD go, deletes and tells nobody.
//   POST ?delete=1       the real run. This is what the cron calls.
// Silent in OPS when nothing moved.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { BUCKET, parseRunMode, runExpiry, type SessionRow, type StoredObject } from './expire.ts';

const env = (k: string) => Deno.env.get(k) ?? '';
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

async function tgOps(text: string): Promise<void> {
  const token = env('TELEGRAM_BOT_TOKEN'), chat = env('TELEGRAM_CHAT_ID');
  if (!token || !chat) { console.warn('expire-cleaning-photos: no Telegram OPS target configured'); return; }
  const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }), signal: AbortSignal.timeout(10_000),
  }).catch(() => null);
  if (!r?.ok) console.warn('expire-cleaning-photos: OPS line not delivered', r?.status ?? 'no response');
}

Deno.serve(withObservability({ functionName: 'expire-cleaning-photos', route: 'ops' }, async (req: Request) => {
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405);
  const mode = parseRunMode(req.url, req.headers.get('x-cascade-cron-secret'), env('CASCADE_CRON_SHARED_SECRET'));
  if (!mode.ok) return json({ ok: false, error: 'unauthorized' }, mode.status);
  const dry = mode.dry;
  const db = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });
  const hb = heartbeat(db, 'expire-cleaning-photos-weekly');
  if (!dry) await hb('started');
  try {
    const result = await runExpiry({
      now: new Date(),
      async fetchCandidates(cutoff, limit) {
        const { data, error } = await db.from('cleaning_sessions')
          .select('id,created_at,submission_id,property_id,submitted_by_user_id,session_folder_id,total_photo_count,drive_files,meter_readings(vision_verdict)')
          .lt('created_at', cutoff).not('session_folder_id', 'is', null).not('drive_files', 'is', null).gt('total_photo_count', 0)
          .order('created_at', { ascending: false }).limit(limit);
        if (error) throw new Error('cleaning_sessions: ' + error.message);
        return (data ?? []) as SessionRow[];
      },
      async listObjects(prefix): Promise<StoredObject[]> {
        const { data, error } = await db.storage.from(BUCKET).list(prefix, { limit: 1000 });
        if (error) throw new Error(error.message);
        return (data ?? []).map((o: { name: string; id: string | null; metadata?: { size?: number } | null }) =>
          ({ name: o.name, size: typeof o.metadata?.size === 'number' ? o.metadata.size : null, isFolder: o.id === null }));
      },
      async removeObjects(paths) {
        const { data, error } = await db.storage.from(BUCKET).remove(paths);
        if (error) throw new Error(error.message);
        const names = (data ?? []).map((o: { name: string }) => o.name);
        return paths.filter((p) => names.some((n: string) => n === p || p.endsWith('/' + n)));
      },
      notify: tgOps,
    }, { dry });
    console.log('expire_cleaning_photos_run', JSON.stringify({ dry, considered: result.considered, expired: result.expired.length, kept: result.kept.length, keptReasons: result.keptReasons, failed: result.failed.length, freedBytes: result.freedBytes }));
    if (!dry) await (result.failed.length > 0 ? hb('failed', 'REMOVE_FAILED') : hb('succeeded'));
    return json({ ok: result.failed.length === 0, ...result });
  } catch (e) {
    console.error('expire_cleaning_photos_failed', String(e).slice(0, 300));
    if (!dry) await hb('failed', 'RUN_FAILED');
    return json({ ok: false, error: String(e).slice(0, 200) }, 500);
  }
}));
