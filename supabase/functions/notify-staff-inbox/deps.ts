// Lane XS: the database side of notify-staff-inbox, behind a small interface so a test can assert the exact RPC names and argument keys.
import type { InboxDeps, Sub } from './inbox.ts';
import type { NoticeRow } from './notices.ts';

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
    noticeRecipients: async (propertyId) => {
      const { data, error } = await db.rpc('staff_push_notice_recipients_v1', { p_property_id: propertyId });
      if (error) { console.error('staff_push_notice_recipients_v1 failed:', error.code); return null; }
      return (data ?? []) as Sub[];
    },
    // s104: one staff member's phones that hold the notices topic (the default topics are paid + notices); before the topics column exists every phone of that user.
    userRecipients: async (userId) => {
      const base = () => db.from('staff_push_subscriptions').select('id,endpoint,p256dh,auth').eq('user_id', userId);
      const first = await base().contains('topics', ['notices']);
      if (!first.error) return (first.data ?? []) as Sub[];
      const absent = first.error.code === '42703' || (first.error.code === 'PGRST204' && /topics/i.test(first.error.message ?? ''));
      if (!absent) { console.error('staff_push_subscriptions read failed:', first.error.code); return null; }
      const again = await base();
      if (again.error) { console.error('staff_push_subscriptions read failed:', again.error.code); return null; }
      return (again.data ?? []) as Sub[];
    },
    notice: async (id) => {
      const { data, error } = await db.from('ops_notices').select('id,property_id,notice_type,effective_date,effective_time,duration_hours,is_active').eq('id', id).maybeSingle();
      if (error) { console.error('ops_notices read failed:', error.code); return null; }
      return (data ?? undefined) as NoticeRow | undefined;
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
