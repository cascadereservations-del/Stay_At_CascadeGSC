// SPEC-47 notable-topics writer, split out of index.ts so spec47.test.ts can import it without starting Deno.serve (needs --allow-net).
import { recordTopics, topicsForTurn } from '../_shared/cascade-core/topics.ts';
import { bookingIdOf } from './id-capture.ts';
import type { JevRoute } from './jev.ts';

/** SPEC-47: booking_flow.booking_id -> booking_inquiries.guest_id, then record_guest_topic_v1 per topic. Fire-and-forget: returns nothing, never throws. */
// deno-lint-ignore no-explicit-any
export function noteTopics(db: any, psid: string, flow: { booking_id?: string } | null | undefined, text: string, jev: JevRoute | null): void {
  try {
    const id = bookingIdOf(flow);
    if (!id || id === 'probe' || psid.startsWith('probe:')) return;
    const topics = topicsForTurn(text, jev);
    if (!topics.length) return;
    const work = (async () => {
      const { data } = await db.from('booking_inquiries').select('guest_id').eq('id', id).maybeSingle();
      await recordTopics(db, data?.guest_id, id, topics, 'messenger');
    })().catch((e) => console.warn('topic_write_failed', 'messenger', String(e).slice(0, 80)));
    const edge = (globalThis as unknown as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
    if (edge?.waitUntil) edge.waitUntil(work);
  } catch (e) { console.warn('topic_write_failed', 'messenger', String(e).slice(0, 80)); }
}
