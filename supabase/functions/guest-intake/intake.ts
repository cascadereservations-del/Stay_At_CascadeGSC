// SPEC-42 s4b: what guest-intake does with a parsed form, with every outside call injected so it is unit-tested without a network.
// Per person: find-or-create by name, then (if a photo came) store the object, then link it, then mark ID on file. A failed link removes
// the object it just stored, so no photo sits in the private bucket that no row points at (SPEC-40 keeps the purge queue for the rest).
import { groups, withHeader } from '../_shared/cascade-core/format.ts';
import { DAILY_PHOTOS, sniffImage, type Person } from './validate.ts';

export type RpcResult = { data: any; error: { message: string; code?: string } | null };
export type Deps = {
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<RpcResult>;
  upload: (path: string, bytes: Uint8Array, mime: string) => Promise<string | null>; // an error message, or null
  remove: (path: string) => Promise<void>;
  uuid: () => string;
};
export type Context = { ref: string; guest_name: string | null; checkin_date: string; checkout_date: string; can_save: boolean; uploads_today: number; max_uploads_per_day: number };
export type Result = { name: string; ok: boolean; photo: boolean; reason?: 'photo_type' | 'rate_limited' | 'save_failed' };

export async function savePeople(d: Deps, tokenHash: string, ctx: Context, people: Person[]): Promise<Result[]> {
  const limit = ctx.max_uploads_per_day || DAILY_PHOTOS;
  let used = ctx.uploads_today;
  const out: Result[] = [];
  for (const p of people) {
    const fail = (reason: Result['reason']): Result => ({ name: p.name, ok: false, photo: false, reason });
    const kind = p.photo ? sniffImage(p.photo) : null;
    if (p.photo && !kind) { out.push(fail('photo_type')); continue; }
    if (p.photo && used >= limit) { out.push(fail('rate_limited')); continue; }

    const made = await d.rpc('intake_save_guest_companion_v1', { p_token_hash: tokenHash, p_name: p.name, p_id_type: p.idType, p_id_photo_path: null, p_contact: p.contact });
    if (made.error || !made.data?.ok || !made.data.id) { out.push(fail('save_failed')); continue; }

    let photo = false;
    if (p.photo && kind) {
      const path = `${made.data.id}/${d.uuid()}.${kind.ext}`;
      if (await d.upload(path, p.photo, kind.mime)) { out.push(fail('save_failed')); continue; }
      const linked = await d.rpc('intake_save_guest_companion_v1', { p_token_hash: tokenHash, p_name: p.name, p_id_type: null, p_id_photo_path: path, p_contact: null });
      if (linked.error || !linked.data?.ok) {
        await d.remove(path).catch(() => null);
        out.push(fail(linked.data?.reason === 'rate_limited' ? 'rate_limited' : 'save_failed'));
        continue;
      }
      photo = true; used++;
    }

    const patch: Record<string, unknown> = {};
    if (photo) patch.id_on_file = true;
    if (p.self && p.contact) patch.contact_number = p.contact;
    if (p.self && p.idType) patch.id_type = p.idType;
    if (Object.keys(patch).length) {
      const det = await d.rpc('intake_save_guest_details_v1', { p_token_hash: tokenHash, p_patch: patch });
      if (det.error || !det.data?.ok) { out.push({ name: p.name, ok: false, photo, reason: 'save_failed' }); continue; }
    }
    out.push({ name: p.name, ok: true, photo });
  }
  return out;
}

const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;

/** The OPS line for one completed submission. Who and what first, then the stay; no phone, no money, no ID detail, no link. */
export function opsCard(ctx: Pick<Context, 'ref' | 'guest_name' | 'checkin_date' | 'checkout_date'>, results: Result[]): string | null {
  const saved = results.filter((r) => r.ok);
  if (!saved.length) return null;
  const photos = saved.filter((r) => r.photo).length;
  const what = photos ? plural(photos, 'ID') : `${plural(saved.length, 'guest name')} (no ID photos yet)`;
  return withHeader('guest', `booking ${ctx.ref}`, groups(
    [`${ctx.guest_name || 'A guest'} sent ${what} before arrival.`, `Stay ${ctx.checkin_date} to ${ctx.checkout_date}.`],
    ['They are in the dashboard under Companions. No action needed.'],
  ));
}
