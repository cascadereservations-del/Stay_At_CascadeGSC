// D-285 (DESIGN-weekly-quality-line-2026-09-29): one concierge_turn_stats row per guest turn, for the Monday Finance card's
// two Cassy lines. No psid, no guest name, no full text. Only messenger-concierge imports this file (house.ts is bundled by
// telegram-cassy and telegram-expense too), so the deploy set stays small.
import { AMENITY_RE } from './voice.ts';
import { redact, type JevRoute } from './jev.ts';

// The calibration knob: extend it when the Monday teach list shows filler words (en / tl / bis).
const STOP = new Set(('the and how what where when can you your use there have this that with for are any does did about please need '
  + 'want know get got its his her they them our ours from into just also still thanks thank hello good morning evening sir maam mam '
  + 'work works turn turned open find located location number email '
  + 'po ba ang sa ng mga mo ko ako may naa unsa asa paano saan pano gamitin gamiton unsaon ano nasaan pwede puwede naman lang yung ung '
  + 'nga unta kay man din rin kayo niyo nyo inyo ninyo kami namo diin').split(' '));

/** Up to three content words of a redacted question, lower case, for the teach list. */
export function missWords(text: string): string {
  return redact(text).replace(/\[(email|number)\]/g, ' ').toLowerCase().split(/[^\p{L}]+/u)
    .filter((w) => w.length >= 3 && !STOP.has(w)).slice(0, 3).join(' ');
}

export type TurnStats = { probe: boolean; lint: string[]; house: 'hit' | 'miss' | 'locked' | null; miss: string | null; re: string; jev: string | null; up: boolean };

/** The row for one guest turn. `house` is read only for a how-to question (Jev amenity >= 0.8 or AMENITY_RE) the bot answered. */
export function turnStats(t: { psid: string; text: string; replied: boolean; lint: string[]; jev: JevRoute | null; house: { rows: unknown[]; locked: unknown } | null; houseLocked: boolean; re: string; up: boolean }): TurnStats {
  const howTo = t.replied && !!t.text && ((t.jev?.intent === 'amenity' && t.jev.confidence >= 0.8) || AMENITY_RE.test(t.text));
  const house = !howTo ? null : t.houseLocked ? 'locked' : t.house?.rows.length ? 'hit' : 'miss';
  return { probe: t.psid.startsWith('probe:'), lint: t.lint, house, miss: house === 'miss' ? missWords(t.text) : null, re: t.re, jev: t.jev?.intent ?? null, up: t.up };
}
