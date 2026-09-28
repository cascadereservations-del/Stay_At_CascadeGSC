// The on-ground contact guests are given (Lloyd 2026-09-28: "the number provided is the number of the on ground partner -
// Honey which should also be an editable option in the dashboard ... sync across all"). One source: app_settings keys
// `onground_name` / `onground_phone`, edited on the admin dashboard (Settings > Guest contact). FACTS, the door-ask line
// and the scheduled guest messages all read it here. The old CASCADE_ONGROUND_* Edge secrets are only a fallback.
// ponytail: 60 s per-instance cache like loadCard, so an edit reaches guests within a minute.
export type Contact = { name: string; phone: string };
export const DEFAULT_CONTACT: Contact = { name: 'Honey', phone: '0991 853 8269' };
type Db = { from: (t: string) => any };

let current: Contact = DEFAULT_CONTACT;
let cached: { c: Contact; at: number } | null = null;

/** The contact loaded last on this instance (the default until loadContact runs). */
export const currentContact = (): Contact => current;

/** Pure: the contact from app_settings rows, then the env fallback, then the default - each field on its own. */
export function contactFrom(rows: { key: string; value: unknown }[] | null, env: (k: string) => string | undefined = () => undefined): Contact {
  const get = (k: string) => { const v = (rows ?? []).find((r) => r.key === k)?.value; return typeof v === 'string' ? v.trim() : ''; };
  return {
    name: get('onground_name') || env('CASCADE_ONGROUND_NAME')?.trim() || DEFAULT_CONTACT.name,
    phone: get('onground_phone') || env('CASCADE_ONGROUND_PHONE')?.trim() || DEFAULT_CONTACT.phone,
  };
}

export async function loadContact(db: Db, nowMs = Date.now()): Promise<Contact> {
  if (cached && nowMs - cached.at < 60_000) return (current = cached.c);
  try {
    const { data } = await db.from('app_settings').select('key, value').in('key', ['onground_name', 'onground_phone']);
    cached = { c: contactFrom(data, (k) => Deno.env.get(k)), at: nowMs };
  } catch (e) {
    console.error('contact_load_failed', String(e).slice(0, 200));
    cached = { c: contactFrom(null, (k) => Deno.env.get(k)), at: nowMs };
  }
  return (current = cached.c);
}
