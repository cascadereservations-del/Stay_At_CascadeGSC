// s84 XS (review F2): the paid notice goes only to phones that still hold the `paid` topic. Before the topics column exists (the SQL release not applied
// yet) the filter errors; then the read is repeated without it, so the paid notice never stops.
import type { Sub } from './paid.ts';

// deno-lint-ignore no-explicit-any
export async function readPaidSubs(db: any, userId: string): Promise<Sub[]> {
  const base = () => db.from('staff_push_subscriptions').select('id,endpoint,p256dh,auth').eq('user_id', userId);
  const first = await base().contains('topics', ['paid']);
  if (!first.error) return (first.data ?? []) as Sub[];
  const absent = first.error.code === '42703' || (first.error.code === 'PGRST204' && /topics/i.test(first.error.message ?? ''));
  if (!absent) return [];
  const again = await base();
  return (again.error ? [] : (again.data ?? [])) as Sub[];
}
