// deno test --no-check _shared/contact.test.ts
// Lloyd 2026-09-28: the on-ground contact is edited on the dashboard and reaches every guest-facing surface from one row.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { contactFrom, DEFAULT_CONTACT, phDisplay } from './cascade-core/contact.ts';
import { factsFor } from './cascade-core/facts.ts';
import { SEED_CARD } from './cascade-core/pricing.ts';
import { accessVerify } from '../messenger-concierge/persona.ts';

Deno.test('app_settings wins, then the env fallback, then the default - field by field', () => {
  assertEquals(contactFrom([{ key: 'onground_name', value: 'Mia' }, { key: 'onground_phone', value: '0917 111 2222' }]), { name: 'Mia', phone: '+63 917 111 2222' }); // stored local form reads in the one tappable format
  assertEquals(contactFrom([{ key: 'onground_phone', value: ' 0917 111 2222 ' }], (k) => (k === 'CASCADE_ONGROUND_NAME' ? 'Env Name' : undefined)), { name: 'Env Name', phone: '+63 917 111 2222' });
  assertEquals(contactFrom(null), DEFAULT_CONTACT);
  assertEquals(contactFrom([{ key: 'onground_name', value: '' }]), DEFAULT_CONTACT); // a cleared field falls back, never blanks
});

Deno.test('one contact, every surface: FACTS and the door-ask line carry the same name and number', () => {
  const c = { name: 'Mia', phone: '0917 111 2222' };
  const facts = factsFor(SEED_CARD, new Date('2026-09-28T00:00:00Z'), c);
  assertEquals(facts.includes('our on-ground partner Mia, 0917 111 2222'), true);
  assertEquals(facts.includes('{{ONGROUND}}'), false);
  for (const l of ['en', 'tl', 'bis'] as const) assertEquals(accessVerify(l, c).includes('Mia') && accessVerify(l, c).includes('0917 111 2222'), true, l);
});

// SPEC-41 2c (D-296.3): one tappable contact format, "+63 9XX XXX XXXX"; payment numbers are not run through it.
Deno.test('phDisplay: every way the number is typed reads +63 9XX XXX XXXX; a landline or junk is left alone', () => {
  const want = '+63 917 111 2222';
  for (const raw of ['09171112222', '0917 111 2222', '0917-111-2222', ' 0917 111 2222 ', '+63 917 111 2222', '+639171112222', '639171112222', '63 917 111 2222']) assertEquals(phDisplay(raw), want, raw);
  assertEquals(phDisplay('(083) 552 0000'), '(083) 552 0000');
  assertEquals(phDisplay(' ask us '), 'ask us');
  assertEquals(phDisplay('0917 111 222'), '0917 111 222'); // one digit short is never "fixed"
  assertEquals(phDisplay(want), want); // idempotent
});

Deno.test('DEFAULT_CONTACT is already in the tappable format', () => {
  assertEquals(phDisplay(DEFAULT_CONTACT.phone), DEFAULT_CONTACT.phone);
  assertEquals(/^\+63 9\d{2} \d{3} \d{4}$/.test(DEFAULT_CONTACT.phone), true);
});
