// deno test supabase/functions/power-watch/scan.test.ts - the read loop (audit L5a): a done post is not trusted for posters it never read. Synthetic data only.
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import type { NoticeState } from '../_shared/cascade-core/brownout.ts';
import { posterUrls, type Notice } from './poster.ts';
import { scheduleFrom, staleNotices } from './plan.ts';
import { reportStuck, scanPosts, STUCK_AFTER, type ScanState } from './scan.ts';

const P = 'https://www.socoteco2.com/wp-content/uploads/2026/10/';
const post = (id: number, ...files: string[]) => ({ id, content: { rendered: files.map((f) => `<img src="${P}${f}">`).join('') } });
const notice = (date: string, url: string, o: Partial<Notice> = {}): Notice => ({ date, time: '06:00:00', hours: 11, title: 'SOCOTECO II scheduled interruption (ours is 14-3)', purpose: '', poster: url.split('/').pop()!, url, status: 'active', originalDate: null, ...o });
const LIMITS = { maxReads: 4, budgetMs: 90_000 };
const decided = (st: ScanState) => (u: string) => st.images.includes(u);
const sched = (posts: Array<{ id: number; content: { rendered: string } }>, st: ScanState) =>
  scheduleFrom(posts.map((p) => ({ id: p.id, posters: posterUrls(p.content.rendered) })), st.ours, decided(st));

Deno.test('audit L5a: a done post that gains a read-class poster is read for that poster; if the read fails the schedule is null and nothing is released', async () => {
  const old = 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg', added = 'SPI-10042026-BATULAKI-GLAN.jpg';
  const posts = [post(7, old, added)];
  const st: ScanState = { done: [7], images: [P + old], ours: { [P + old]: '2026-10-08' } };
  const tried: string[] = [];
  const r = await scanPosts(posts, st, '2026-10-02', (url) => { tried.push(url); throw new Error('poster_503'); }, LIMITS);
  assertEquals(tried, [P + added], 'the unread poster is read although its post is done; the read one is not read again');
  assertEquals([r.reads, st.images.includes(P + added), st.done], [1, false, [7]]);
  assertEquals(sched(posts, st), null, 'an unread poster makes the whole feed unknown');
  const held = { date: '2026-10-08', status: 'active', source: 'socoteco', blocked: ['2026-10-07', '2026-10-08'], missRuns: 1 } as unknown as NoticeState;
  const stale = staleNotices([held], sched(posts, st), [], '2026-10-02');
  assertEquals([stale.release, stale.miss, stale.ask], [[], [], []], 'nothing is released on a half-read feed');
  // next run the read works: the poster is read once, decided, and the schedule is known again
  const ok = await scanPosts(posts, st, '2026-10-02', (url) => Promise.resolve({ notice: null, log: url }), LIMITS);
  assertEquals([ok.reads, st.images.includes(P + added)], [1, true]);
  assert(sched(posts, st) !== null);
});

Deno.test('audit L5a: a moved hit poster re-uploaded under a new URL is read, and lists the date its read names', async () => {
  const old = 'SPI-PMS-10082026-LEON-LLIDO-SS.jpg', again = 'SPI-PMS-10082026-LEON-LLIDO-SS_20261005_101010_0000.jpg';
  const posts = [post(22013, again)];
  const st: ScanState = { done: [22013], images: [P + old], ours: { [P + old]: '2026-10-15' } };
  const read: string[] = [];
  const r = await scanPosts(posts, st, '2026-10-02', (url) => { read.push(url); return Promise.resolve({ notice: notice('2026-10-15', url, { originalDate: '2026-10-08' }), log: url }); }, LIMITS);
  assertEquals(read, [P + again]);
  assertEquals([r.found.map((n) => n.date), st.ours[P + again]], [['2026-10-15'], '2026-10-15']);
  const s = sched(posts, st)!;
  assert(s.listed.has('2026-10-15'), 'the moved-TO date is listed from the new read');
  assert(s.listed.has('2026-10-08'), 'and the filename date too');
});

Deno.test('audit L5a: a poster that fails 8 runs in a row is reported once per run from the 8th (one task by a stable key); a good read resets the count; absent state = 0', async () => {
  const f = 'SPI-10042026-BATULAKI-GLAN.jpg', posts = [post(7, f)];
  const st: ScanState = { done: [], images: [], ours: {} }; // no `fails` key: backward compatible
  const fail = () => Promise.reject(new Error('poster_503'));
  for (let i = 1; i < STUCK_AFTER; i++) assertEquals((await scanPosts(posts, st, '2026-10-02', fail, LIMITS)).stuck, [], `run ${i}`);
  assertEquals(st.fails![P + f], STUCK_AFTER - 1);
  const r = await scanPosts(posts, st, '2026-10-02', fail, LIMITS);
  assertEquals(r.stuck, [P + f]);
  const opened: Array<{ kind: string; ref: string; title: string; detail: string }> = [];
  await reportStuck(r.stuck, (t) => { opened.push(t); return Promise.resolve(); });
  assertEquals(opened.length, 1);
  assertEquals([opened[0].kind, opened[0].ref], ['power_poster_unread', f]);
  assert(opened[0].title.includes('cannot be read') && opened[0].title.includes('auto-release is paused'), opened[0].title);
  assert(opened[0].detail.includes(P + f), 'the task carries the poster link');
  await reportStuck([], (t) => { opened.push(t); return Promise.resolve(); });
  assertEquals(opened.length, 1, 'nothing stuck, nothing opened');
  // a good read resets
  await scanPosts(posts, st, '2026-10-02', (url) => Promise.resolve({ notice: null, log: url }), LIMITS);
  assertEquals(st.fails![P + f], undefined);
  assertEquals(st.images.includes(P + f), true);
  // a capped run does not count as a failure
  const st2: ScanState = { done: [], images: [], ours: {}, fails: { [P + f]: 3 } };
  await scanPosts(posts, st2, '2026-10-02', fail, { maxReads: 0, budgetMs: 90_000 });
  assertEquals(st2.fails![P + f], 3);
});
