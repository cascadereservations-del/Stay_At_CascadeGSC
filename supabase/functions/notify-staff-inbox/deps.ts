// Lane XS: the database side of notify-staff-inbox, behind a small interface so a test can assert the exact RPC names and argument keys.
import type { InboxDeps, Sub } from './inbox.ts';

// deno-lint-ignore no-explicit-any
export type DbLike = { rpc: (fn: string, args?: Record<string, unknown>) => PromiseLike<{ data: any; error: { code?: string } | null }>; from: (t: string) => any };

export function makeDeps(db: DbLike, push: InboxDeps['push'], nowMs: () => number): InboxDeps {
  return {
    nowMs,
    recipients: async () => {
      const { data, error } = await db.rpc('staff_push_inbox_recipients_v1');
      if (error) { console.error('staff_push_inbox_recipients_v1 failed:', error.code); return null; }
      return (data ?? []) as Sub[];
    },
    claim: async (key) => {
      const { data, error } = await db.rpc('staff_push_claim_v1', { p_key: key });
      if (error) { console.error('staff_push_claim_v1 failed:', error.code); return null; }
      return data === true;
    },
    deleteSub: async (id) => { await db.from('staff_push_subscriptions').delete().eq('id', id); },
    touchSub: async (id) => { await db.from('staff_push_subscriptions').update({ last_ok_at: new Date(nowMs()).toISOString() }).eq('id', id); },
    push,
    log: (m) => console.warn(m),
  };
}
