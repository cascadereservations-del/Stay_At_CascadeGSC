// power-watch, the read loop (audit L5a): which posters of SOCOTECO's current posts still need a read this run. Split out of index.ts so scan.test.ts can run it.
// A poster counts as decided only when it is in state.images (actually read, or filed as another feeder). A DONE post is not skipped: SOCOTECO can edit it
// and add a poster, or re-upload one under a new URL, and that poster has never been read. A read that fails or is capped leaves it out of state.images,
// so scheduleFrom (plan.ts) answers null for the run and nothing is released.
import { classifyFile, posterUrls, type Notice } from './poster.ts';
import type { Found } from './watch.ts';

export type ScanState = { done: number[]; images: string[]; ours: Record<string, string> };
/** Reads one poster ('hit' or 'read' class): the notice it carries (null = not ours) and a log line. Throws when it cannot be read. */
export type ReadOne = (url: string, cls: 'hit' | 'read') => Promise<{ notice: Notice | null; log: string }>;

export async function scanPosts(
  posts: Array<{ id: number; content?: { rendered?: string } }>, state: ScanState, today: string, readOne: ReadOne,
  limits: { maxReads: number; budgetMs: number }, warn: (url: string, e: unknown) => void = () => {},
): Promise<{ found: Found[]; log: string[]; reads: number }> {
  const found: Found[] = [], log: string[] = [];
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
        if (n) state.ours[url] = n.date; // hit posters too: a moved poster's filename carries the moved-FROM date (D-295)
        if (n && (n.date >= today || (n.originalDate ?? '') >= today)) found.push({ ...n, postId: p.id });
        state.images.push(url);
      } catch (e) {
        complete = false; // read again next run
        warn(url, e);
      }
    }
    if (complete && !state.done.includes(p.id)) state.done.push(p.id);
  }
  return { found, log, reads };
}
