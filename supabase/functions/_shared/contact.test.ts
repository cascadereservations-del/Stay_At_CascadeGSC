// deno test --no-check _shared/contact.test.ts
// Lloyd 2026-09-28: the on-ground contact is edited on the dashboard and reaches every guest-facing surface from one row.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { contactFrom, DEFAULT_CONTACT } from './cascade-core/contact.ts';
import { factsFor } from './cascade-core/facts.ts';
import { SEED_CARD } from './cascade-core/pricing.ts';
import { accessVerify } from '../messenger-concierge/persona.ts';

Deno.test('app_settings wins, then the env fallback, then the default - field by field', () => {
  assertEquals(contactFrom([{ key: 'onground_name', value: 'Mia' }, { key: 'onground_phone', value: '0917 111 2222' }]), { name: 'Mia', phone: '0917 111 2222' });
  assertEquals(contactFrom([{ key: 'onground_phone', value: ' 0917 111 2222 ' }], (k) => (k === 'CASCADE_ONGROUND_NAME' ? 'Env Name' : undefined)), { name: 'Env Name', phone: '0917 111 2222' });
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
