// power-watch, the read loop (audit L5a): which posters of SOCOTECO's current posts still need a read this run. Split out of index.ts so scan.test.ts can run it.
// A poster counts as decided only when it is in state.images (actually read, or filed as another feeder). A DONE post is not skipped: SOCOTECO can edit it
// and add a poster, or re-upload one under a new URL, and that poster has never been read. A read that fails or is capped leaves it out of state.images,
// so scheduleFrom (plan.ts) answers null for the run and nothing is released.
import { classifyFile, posterUrls, type Notice } from './poster.ts';
import type { Found } from './watch.ts';

/** `fails` = consecutive runs a poster could not be read, per URL (power_watch_state.fails; absent = 0). */
export type ScanState = { done: number[]; images: string[]; ours: Record<string, string>; fails?: Record<string, number> };
export const STUCK_AFTER = 8; // consecutive failed runs before a poster that never reads becomes a Follow-ups task
/** Reads one poster ('hit' or 'read' class): the notice it carries (null = not ours) and a log line. Throws when it cannot be read. */
export type ReadOne = (url: string, cls: 'hit' | 'read') => Promise<{ notice: Notice | null; log: string }>;

export async function scanPosts(
  posts: Array<{ id: number; content?: { rendered?: string } }>, state: ScanState, today: string, readOne: ReadOne,
  limits: { maxReads: number; budgetMs: number }, warn: (url: string, e: unknown) => void = () => {},
): Promise<{ found: Found[]; log: string[]; reads: number; stuck: string[] }> {
  forgetReads(posts, state);
  const found: Found[] = [], log: string[] = [], stuck: string[] = [];
  const fails = (state.fails ??= {});
  let reads = 0;
  const started = Date.now();
  for (const p of posts) {
    let complete = true;
    for (const url of posterUrls(p.content?.rendered ?? '')) {
      if (state.images.includes(url)) continue;
      const c = classifyFile(url);
      if (c === 'miss') { state.images.push(url); continue; }
      if (reads >= limits.maxReads || Date.now() - started > limits.budgetMs) { complete = false; break; }
      reads++;
      try {
        const { notice: n, log: line } = await readOne(url, c);
        log.push(line);
        state.ours[url] = n?.date ?? ''; // what the read said, hit posters too (a moved poster's filename carries the moved-FROM date, D-295); '' = read, not ours
        if (n && (n.date >= today || (n.originalDate ?? '') >= today)) found.push({ ...n, postId: p.id });
        state.images.push(url);
        delete fails[url];
      } catch (e) {
        complete = false; // read again next run
        fails[url] = (fails[url] ?? 0) + 1;
        if (fails[url] >= STUCK_AFTER) stuck.push(url);
        warn(url, e);
      }
    }
    if (complete && !state.done.includes(p.id)) state.done.push(p.id);
  }
  return { found, log, reads, stuck };
}

/**
 * A hit- or read-class poster of the current posts that is in state.images but has no `ours` entry was decided without its read being recorded
 * (the code before SPEC-41 did not keep it, so a moved poster would list only its moved-FROM date). It is not decided: forget it so it is read again
 * (the read cap still applies; scheduleFrom answers null until every one is back). A poster read and found not ours is recorded as ours[url] = '',
 * so it is not read again every run. Miss-class posters (another substation or feeder) need no read.
 */
export function forgetReads(posts: Array<{ content?: { rendered?: string } }>, state: ScanState): void {
  const again = new Set(posts.flatMap((p) => posterUrls(p.content?.rendered ?? '')).filter((u) => classifyFile(u) !== 'miss' && !(u in state.ours)));
  state.images = state.images.filter((u) => !again.has(u));
}

/** A poster that never reads keeps the schedule null (nothing is ever freed) - safe, but it silently pauses brownout auto-release. ONE task says so. */
export type OpenTask = (t: { kind: string; ref: string; title: string; detail: string }) => Promise<unknown>;
export async function reportStuck(stuck: string[], open: OpenTask): Promise<void> {
  for (const url of stuck) {
    const file = decodeURIComponent(url.split('/').pop() ?? url).slice(0, 100);
    await open({
      kind: 'power_poster_unread', ref: file,
      title: 'One SOCOTECO poster cannot be read, so brownout auto-release is paused',
      detail: `Power watch has failed to read this SOCOTECO poster on ${STUCK_AFTER} runs in a row: ${url}. Until it reads, no brownout block is freed automatically (blocks are still added). Open the poster and check it, or tell Lloyd.`,
    });
  }
}
