// Lane S (s82): the one link a notice keeps, ops_notices.source_url. Pure, no network, no clock.
// Only http/https; no credentials, no whitespace; the query string and fragment are dropped (tracking ids such as fbclid or mibextid, and anything that
// could name a person) except the few parameters a Facebook story/permalink link cannot work without. At most 500 characters (the column check).

const KEEP_QUERY: Record<string, string[]> = {
  'story.php': ['story_fbid', 'id'],
  'permalink.php': ['story_fbid', 'id'],
  'photo.php': ['fbid'],
  'watch': ['v'],
};

/** The cleaned URL, or null when the text holds no usable http(s) link. Takes the first link in the text. */
export function S_noticeUrl(raw: unknown): string | null {
  const text = typeof raw === 'string' ? raw : '';
  const m = /https?:\/\/[^\s<>"'()]+/i.exec(text) ?? /(?<![\w.@:/-])(?:(?:www|m|web)\.)?(?:facebook\.com|fb\.watch|socoteco2\.com)\/[^\s<>"'()]+/i.exec(text);
  if (!m) return null;
  let u: URL;
  try { u = new URL(/^https?:\/\//i.test(m[0]) ? m[0] : 'https://' + m[0]); } catch { return null; }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
  if (u.username || u.password || !u.hostname.includes('.')) return null;
  const last = u.pathname.split('/').filter(Boolean).pop() ?? '';
  const keep = KEEP_QUERY[last] ?? [];
  const q = new URLSearchParams();
  for (const k of keep) { const v = u.searchParams.get(k); if (v && /^[\w.-]{1,64}$/.test(v)) q.set(k, v); }
  const out = u.origin + u.pathname + (q.size ? '?' + q.toString() : '');
  return out.length <= 500 && out.length >= 8 && !/[\s@]/.test(out) ? out : null;
}
