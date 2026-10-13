// R_transcribe (s82 lane R): the screenshot reader for guest-reply-draft. Same providers, order and timeouts as
// telegram-cassy transcribeChat (visionExtractText: OpenRouter then Gemini, usage logged); what is new is the SECOND-PASS prompt
// and the `malformed` flag, so the caller can tell "the model returned broken JSON" from "there is no message in the picture".
import { hasVisionKey, parseModelJson, visionExtractText } from '../_shared/cascade-core/vision.ts';
import type { Line, Transcript } from '../telegram-cassy/draft.ts';

export type ReadResult = Transcript & { malformed?: boolean };

const SHAPE = `Return ONLY JSON: {"guest_name": string|null, "platform": "messenger"|"airbnb"|"other", "messages": [{"from": "guest"|"host", "text": string}]}.`;
/** Pass 1: identical in meaning to telegram-cassy's TRANSCRIBE_PROMPT. */
export const PASS1_PROMPT = `This is a screenshot of a chat between a guest and Cascade Hideaway (a small Airbnb in General Santos City). ${SHAPE} messages = every visible message, oldest first, verbatim (Tagalog/Bisaya/English as written); "host" is the Cascade side (right-hand or blue bubbles, the Page, the host or the concierge). platform "airbnb" when the Airbnb app or site is shown. If it is not a chat, return {"guest_name": null, "platform": "other", "messages": []}.`;
/** Pass 2, only when pass 1 found no guest message. */
export const PASS2_PROMPT = `This is a screenshot of a chat between a guest and Cascade Hideaway (a small Airbnb in General Santos City). The first read found no guest message, so read it again, more carefully. ${SHAPE}
How to read the bubbles: the GUEST's bubbles are usually on the LEFT and grey or white (with the guest's small profile picture or name beside them); the HOST's bubbles (Cascade, the Page, the concierge) are usually on the RIGHT and coloured (blue, purple or green). A chat header or a name at the top is the guest's name.
List EVERY message you can see, oldest first, verbatim (Tagalog/Bisaya/English as written), even a message that is partly cut off at the top or bottom edge, a very short one ("Hi", "po?", an emoji) or one inside a quoted reply. Text that belongs to the app (dates, "Seen", "Delivered", typing dots, buttons, ads) is not a message. A single guest bubble is enough: if you can see even one message from the guest, return it. Only when the picture is clearly not a chat at all, return {"guest_name": null, "platform": "other", "messages": []}.`;

const GUEST_SIDE = new Set(['guest', 'other', 'them', 'left', 'customer']);
const HOST_SIDE = new Set(['host', 'me', 'you', 'right', 'page', 'cascade', 'concierge', 'bot', 'assistant']);

export async function readChat(bytes: Uint8Array, mime: string, pass: 1 | 2 = 1): Promise<ReadResult> {
  if (!hasVisionKey()) throw new Error('no vision key');
  const raw = await visionExtractText(pass === 2 ? PASS2_PROMPT : PASS1_PROMPT, bytes, mime, pass === 2 ? 'Cascade Guest Reader 2' : 'Cascade Guest Reader');
  const t = parseModelJson<Partial<Transcript> | null>(raw, null);
  if (!t || typeof t !== 'object' || Array.isArray(t)) return { guest_name: null, platform: 'other', messages: [], malformed: true };
  const messages: Line[] = [];
  for (const m of Array.isArray(t.messages) ? t.messages : []) {
    const side = String((m as { from?: unknown })?.from ?? '').toLowerCase().trim();
    const text = String((m as { text?: unknown })?.text ?? '').trim();
    if (!text) continue;
    if (GUEST_SIDE.has(side)) messages.push({ from: 'guest', text });
    else if (HOST_SIDE.has(side)) messages.push({ from: 'host', text });
  }
  return { guest_name: typeof t.guest_name === 'string' && t.guest_name.trim() ? t.guest_name.trim() : null, platform: t.platform === 'airbnb' || t.platform === 'messenger' ? t.platform : 'other', messages };
}
