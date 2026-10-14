// Lane XS (s82): tell the owner/admin phones that a guest needs them (notify-staff-inbox sends the Web Push). Fire and forget: the guest path
// never waits for this, never sees an error from it, and a failure here is one log line. The function de-duplicates (claim keys), so calling it for
// every host-hold message or handover is safe. The lock-screen text is written there and carries no guest name, contact, message text or amount;
// only the kind, the Messenger id (for the claim key) and the handoff id are sent.
export type InboxKind = 'handover' | 'guest_wrote';

export type InboxPushDeps = {
  base: string;                              // SUPABASE_URL
  key: string;                               // SUPABASE_SERVICE_ROLE_KEY: the function accepts it as the caller's proof
  fetch: typeof fetch;
  waitUntil?: (p: Promise<unknown>) => void; // EdgeRuntime.waitUntil, so the call finishes after the webhook has answered
  log: (msg: string) => void;
};

/** Returns at once. Never throws. */
export function fireInboxPush(kind: InboxKind, psid: string, handoffId: string | null, d: InboxPushDeps): void {
  try {
    if (!d.base || !d.key || !psid) return;
    const body = JSON.stringify(kind === 'handover' ? { kind, psid, handoff_id: handoffId } : { kind, psid });
    const work = Promise.resolve()
      .then(() => d.fetch(`${d.base}/functions/v1/notify-staff-inbox`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${d.key}` }, body, signal: AbortSignal.timeout(10_000),
      }))
      .then(async (r) => { await r.body?.cancel().catch(() => {}); if (!r.ok) d.log(`inbox_push_${r.status}`); })
      .catch((e) => d.log(`inbox_push_failed ${String(e).slice(0, 120)}`));
    if (d.waitUntil) d.waitUntil(work);
  } catch (e) {
    try { d.log(`inbox_push_failed ${String(e).slice(0, 120)}`); } catch { /* nothing may reach the guest path from here */ }
  }
}
