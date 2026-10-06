export function cronSecretMatches(
  configured: string | undefined,
  supplied: string | null,
): boolean {
  if (!configured || !supplied || configured.length !== supplied.length) return false;
  let difference = 0;
  for (let index = 0; index < configured.length; index += 1) {
    difference |= configured.charCodeAt(index) ^ supplied.charCodeAt(index);
  }
  return difference === 0;
}

/** The cron gate for a handler: null when the x-cascade-cron-secret header matches, else the 401 to return. Fails closed when the secret is unset. */
export function cronAuthFailure(req: Request, configured: string | undefined): Response | null {
  if (cronSecretMatches(configured, req.headers.get('x-cascade-cron-secret'))) return null;
  return new Response(JSON.stringify({ ok: false, error: 'unauthorized' }), { status: 401, headers: { 'Content-Type': 'application/json' } });
}
