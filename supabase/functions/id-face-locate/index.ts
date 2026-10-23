// id-face-locate v1 (SPEC-47b, s97). Every 10 min via pg_cron (x-cascade-cron-secret): finds the guest face box ONCE per ID photo,
// stored as four numbers (guest_companions.id_face_box) so every phone can zoom on the face. The vision call returns coordinates only.
// Photos are read from the private bucket into memory and never stored, logged or forwarded. Deploy with --no-verify-jwt.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { withObservability } from '../_shared/observability.ts';
import { heartbeat } from '../_shared/heartbeat.ts';
import { cronAuthFailure } from '../_shared/cron-auth.ts';
import { visionExtractText, hasVisionKey } from '../_shared/cascade-core/vision.ts';
import { FACE_PROMPT, run } from './logic.ts';

const JSON_H = { 'Content-Type': 'application/json' };

Deno.serve(withObservability({ functionName: 'id-face-locate', route: 'ops' }, async (req: Request) => {
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'method_not_allowed' }), { status: 405, headers: JSON_H });
  const denied = cronAuthFailure(req, Deno.env.get('CASCADE_CRON_SHARED_SECRET'));
  if (denied) return denied;
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const hb = heartbeat(db, 'id-face-locate');
  await hb('started');
  try {
    if (!hasVisionKey()) throw new Error('no_vision_key');
    const s = await run({
      todo: async () => {
        const { data, error } = await db.rpc('id_face_todo_v1', { p_limit: 20 });
        if (error) throw new Error('id_face_todo_v1: ' + error.message);
        return Array.isArray(data) ? data : [];
      },
      download: async (path) => {
        const { data, error } = await db.storage.from('guest-id-photos').download(path);
        return error || !data ? null : new Uint8Array(await data.arrayBuffer());
      },
      vision: (bytes, mime) => visionExtractText(FACE_PROMPT, bytes, mime, 'Cascade ID face box'),
      save: async (id, path, box) => {
        const { data, error } = await db.rpc('set_id_face_box_v1', { p_companion_id: id, p_path: path, p_box: box });
        if (error) throw new Error('set_id_face_box_v1: ' + error.message);
        return data === true;
      },
      log: (m) => console.warn(m),
    });
    console.log(JSON.stringify({ event: 'id_face_locate', ...s }));
    // A stopped run (3 failures in a row) is a failed beat; the next cron run retries the same photos.
    await hb(s.stopped ? 'failed' : 'succeeded', s.stopped ? 'vision_failures' : null);
    return new Response(JSON.stringify({ ok: !s.stopped, ...s }), { status: 200, headers: JSON_H });
  } catch (e) {
    console.error('id-face-locate failed:', String(e).slice(0, 120));
    await hb('failed', 'exception');
    return new Response(JSON.stringify({ ok: false, error: 'failed' }), { status: 500, headers: JSON_H });
  }
}));
