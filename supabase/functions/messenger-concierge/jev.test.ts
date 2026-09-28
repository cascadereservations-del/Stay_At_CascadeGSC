// deno test --no-check messenger-concierge/jev.test.ts
// D-271: the Jev safety net can only raise a routine turn, only when Jev is sure a human must act, and contact details
// never leave Cascade.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { redact, unionRisk, type JevRoute } from './jev.ts';

const j = (intent: string, confidence = 1, needsHost = 1): JevRoute => ({ intent, confidence, needsHost, lang: 'en', ms: 300 });

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
