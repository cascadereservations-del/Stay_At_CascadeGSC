// deno test --no-check --allow-env notify-cleaner-payment/subs.test.ts
// s84 XS F2: the paid read filters on the paid topic, and falls back to the old read when the topics column is absent. No clock, no network.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { readPaidSubs } from './subs.ts';

const rows = [{ id: 's1', endpoint: 'e', p256dh: 'p', auth: 'a' }];
function mock(failFiltered: { code?: string; message?: string } | null) {
  const log: string[] = [];
  const db = { from: (t: string) => { log.push(`from:${t}`); const q: any = {
    select: (c: string) => { log.push(`select:${c}`); return q; },
    eq: (c: string, v: string) => { log.push(`eq:${c}=${v}`); return q; },
    contains: (c: string, v: string[]) => { log.push(`contains:${c}=${v}`); return Promise.resolve(failFiltered ? { data: null, error: failFiltered } : { data: rows, error: null }); },
    then: (res: (x: unknown) => void) => res({ data: rows, error: null }),
  }; return q; } };
  return { db, log };
}

Deno.test('with the topics column: filtered on paid, one read', async () => {
  const { db, log } = mock(null);
  assertEquals(await readPaidSubs(db, 'u1'), rows);
  assertEquals(log, ['from:staff_push_subscriptions', 'select:id,endpoint,p256dh,auth', 'eq:user_id=u1', 'contains:topics=paid']);
});

Deno.test('column absent (42703 or PGRST naming topics): read again without the filter', async () => {
  for (const e of [{ code: '42703', message: 'column staff_push_subscriptions.topics does not exist' }, { code: 'PGRST204', message: 'topics' }]) {
    const { db, log } = mock(e);
    assertEquals(await readPaidSubs(db, 'u1'), rows);
    assertEquals(log.filter((l) => l.startsWith('contains')).length, 1);
    assertEquals(log.filter((l) => l.startsWith('from')).length, 2);
  }
});

Deno.test('any other error sends nothing and does not retry', async () => {
  const { db, log } = mock({ code: '57014', message: 'timeout' });
  assertEquals(await readPaidSubs(db, 'u1'), []);
  assertEquals(log.filter((l) => l.startsWith('from')).length, 1);
});
