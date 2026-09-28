// deno test --no-check messenger-concierge/jev.test.ts
// D-271: the Jev safety net can only raise a routine turn, only when Jev is sure a human must act, and contact details
// never leave Cascade.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { primaryLang, redact, routeRisk, unionRisk, type JevRoute } from './jev.ts';

const j = (intent: string, confidence = 1, needsHost = 1): JevRoute => ({ intent, confidence, needsHost, lang: 'en', langConfidence: 1, ms: 300 });

Deno.test('unionRisk raises routine to the matching handoff when Jev is sure and a human must act', () => {
  assertEquals(unionRisk('routine', j('safety')), 'safety');
  assertEquals(unionRisk('routine', j('complaint')), 'complaint');
  assertEquals(unionRisk('routine', j('cancel_or_change')), 'cancellation');
  assertEquals(unionRisk('routine', j('payment')), 'payment');
});

Deno.test('unionRisk never lowers the regex, and ignores unsure or info-only answers', () => {
  assertEquals(unionRisk('safety', j('amenity', 1, 0)), 'safety');           // the regex stays authoritative
  assertEquals(unionRisk('routine', j('safety', 0.6)), 'routine');           // unsure
  assertEquals(unionRisk('routine', j('payment', 1, 0.2)), 'routine');       // "How do I pay?" is information
  assertEquals(unionRisk('routine', j('price')), 'routine');                 // not an escalating intent
  assertEquals(unionRisk('routine', null), 'routine');                       // Jev down: today's behaviour
});

Deno.test('redact keeps the words and drops phones and e-mails', () => {
  assertEquals(redact('Ben 0917 123 4567 ben@example.com, is Oct 3 open?'), 'Ben [number] [email], is Oct 3 open?');
  assertEquals(redact('+63 917-123-4567 paid na po'), '[number] paid na po');
  assertEquals(redact('Oct 20 to 22 for 2 adults'), 'Oct 20 to 22 for 2 adults');
});

const jl = (intent: string, confidence: number, needsHost: number, lang: 'en' | 'tl' | 'bis' = 'en', langConfidence = 1): JevRoute => ({ intent, confidence, needsHost, lang, langConfidence, ms: 300 });

Deno.test('routeRisk: the hard floor (money, danger, door, data probes) is never lowered', () => {
  for (const r of ['safety', 'access', 'payment', 'refund', 'uncertain'] as const) assertEquals(routeRisk(r, jl('amenity', 1, 0.05)), r);
});

Deno.test('routeRisk: a soft regex false alarm is lowered only when Jev is sure no one must act', () => {
  assertEquals(routeRisk('complaint', jl('other', 0.49, 0.11)), 'routine');          // "Is it noisy at night?"
  assertEquals(routeRisk('policy_exception', jl('other', 0.96, 0.09)), 'routine');   // "Any events in GenSan?"
  assertEquals(routeRisk('complaint', jl('other', 0.5, 0.35)), 'complaint');         // not sure enough: the regex stays
  assertEquals(routeRisk('cancellation', jl('availability', 0.6, 0.5)), 'cancellation');
});

Deno.test('routeRisk: house rules and price asks route to answer-then-escalate; sure escalations are raised', () => {
  assertEquals(routeRisk('routine', jl('house_rule', 1, 0.5)), 'policy_exception');  // "pwede po ba magdala ng aso?"
  assertEquals(routeRisk('routine', jl('negotiation', 1, 0.57)), 'policy_exception'); // "discount for Seniors?"
  assertEquals(routeRisk('routine', jl('access', 1, 0.46)), 'access');                // "unsa ang code?" - a sure door needs no host score
  assertEquals(routeRisk('routine', jl('complaint', 1, 0.9)), 'complaint');
  assertEquals(routeRisk('routine', null), 'routine');
});

Deno.test('primaryLang: Jev overrides only an English reading, and only when sure', () => {
  assertEquals(primaryLang('english', jl('complaint', 1, 1, 'bis', 0.94)), 'bisaya');   // "naay ipis sa kusina"
  assertEquals(primaryLang('bisaya', jl('complaint', 1, 1, 'tl', 0.92)), 'bisaya');     // regex found Bisaya: it stays
  assertEquals(primaryLang('english_po', jl('payment', 1, 1, 'tl', 0.86)), 'english_po'); // not sure enough
  assertEquals(primaryLang('english_po', jl('directions', 1, 0, 'en', 1)), 'english_po');
  assertEquals(primaryLang('taglish', null), 'taglish');
});

Deno.test('routeRisk held-out fixes: a safety question is not an emergency; a confident price/amenity reading does not lower a caught ask', () => {
  assertEquals(routeRisk('routine', jl('safety', 0.85, 0.42)), 'routine');                // "is it safe to walk around at night?"
  assertEquals(routeRisk('routine', jl('safety', 0.96, 0.66)), 'safety');                 // "my wife fainted"
  assertEquals(routeRisk('policy_exception', jl('price', 0.98, 0.25)), 'policy_exception'); // "last price po?"
  assertEquals(routeRisk('policy_exception', jl('amenity', 0.95, 0.31)), 'policy_exception'); // "pwede ba mag-videoke?"
});
