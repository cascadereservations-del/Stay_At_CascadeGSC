// deno test --no-check --allow-env telegram-expense/guest.test.ts
// Synthetic names and numbers only (public repo).
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { type Candidate, cleanName, confirmBody, normalizePhone, parseGuestRead, parseGuestTap, pickLabel, planFor, sameName, sniffImage, toIdType } from './guest.ts';

const G: Candidate = { guest_id: 'e2000000-0000-4000-8000-0000000000b1', name: 'Jonas Example', checkin: '2026-10-01', checkout: '2026-10-05', last_stay: null, id_on_file: false, has_contact: false, companions: ['Mara Synthetic'] };

Deno.test('names: surname-first and ALL CAPS become Given Surname in Title Case; digit runs reject the name', () => {
  assertEquals(cleanName('SAMPLE, NORA MAE D.'), 'Nora Mae D. Sample');
  assertEquals(cleanName('NORA MAE D. SAMPLE'), 'Nora Mae D. Sample');
  assertEquals(cleanName("  Dela   Cruz-O'Brien Ana "), "Dela Cruz-O'Brien Ana");
  assertEquals(cleanName('Maria Santos 12345678'), null, 'an ID number in the name field rejects it');
  assertEquals(cleanName('P1234567'), null);
  assertEquals(cleanName('X'), null);
  assertEquals(cleanName(null), null);
  assertEquals(cleanName('Ana 7 Cruz'), 'Ana Cruz', 'stray single digits are dropped, not kept in a name');
});

Deno.test('phone: only a Philippine mobile number, written 09XXXXXXXXX', () => {
  assertEquals(normalizePhone('0917 000 1234'), '09170001234');
  assertEquals(normalizePhone('+63 917-000-1234'), '09170001234');
  assertEquals(normalizePhone('639170001234'), '09170001234');
  assertEquals(normalizePhone('9170001234'), '09170001234');
  assertEquals(normalizePhone('(02) 8123 4567'), null, 'a landline is not a mobile');
  assertEquals(normalizePhone('12345'), null);
  assertEquals(normalizePhone(undefined), null);
});

Deno.test('id type: free text maps to the four values the database accepts', () => {
  assertEquals(toIdType('passport'), 'passport');
  assertEquals(toIdType("Driver's License"), 'drivers_license');
  assertEquals(toIdType('LTO driving licence'), 'drivers_license');
  assertEquals(toIdType('PhilSys National ID'), 'national_id');
  assertEquals(toIdType('PRC professional ID'), 'other');
  assertEquals(toIdType(null), 'other');
});

Deno.test('reader output: an ID keeps a name and a type, never a number, even when the model sends one', () => {
  const r = parseGuestRead('```json\n{"kind":"id","name":"SAMPLE, NORA MAE D.","id_type":"passport","number":"P1234567A","birthday":"1990-01-01","names":["X Y"],"phone":"09170001234"}\n```');
  assertEquals(r, { kind: 'id', name: 'Nora Mae D. Sample', idType: 'passport' });
  assert(!JSON.stringify(r).includes('1234567') && !JSON.stringify(r).includes('1990'));
  assertEquals(parseGuestRead('{"kind":"id","name":"Ana Cruz 98765432","id_type":"passport"}'), { kind: 'other' }, 'a number in the name field voids the read');
});

Deno.test('reader output: a chat gives names and a mobile number, deduped and capped; junk is "other"', () => {
  assertEquals(parseGuestRead('{"kind":"chat","names":["Mara Synthetic","mara synthetic","Ben Test"],"phone":"+63 917 000 1234"}'),
    { kind: 'chat', names: ['Mara Synthetic', 'Ben Test'], phone: '09170001234' });
  assertEquals(parseGuestRead('{"kind":"chat","names":[],"phone":"123"}'), { kind: 'other' });
  assertEquals(parseGuestRead('{"kind":"chat","names":[],"phone":"0917 000 1234"}'), { kind: 'chat', names: [], phone: '09170001234' });
  assertEquals(parseGuestRead('not json'), { kind: 'other' });
  assertEquals(parseGuestRead('{"kind":"selfie"}'), { kind: 'other' });
  assertEquals(parseGuestRead(''), { kind: 'other' });
  assertEquals((parseGuestRead(JSON.stringify({ kind: 'chat', names: Array.from({ length: 9 }, (_, i) => `Guest ${String.fromCharCode(65 + i)}b`) })) as any).names.length, 6);
});

Deno.test('same person: whole words, at least two, initials ignored', () => {
  assert(sameName('Nora Mae D. Sample', 'Nora Sample'));
  assert(sameName('Jonas Example', 'example, jonas'));
  assert(!sameName('Nora Sample', 'Nola Sample'));
  assert(!sameName('Ana', 'Ana Cruz'), 'one word is not enough to call two names the same');
  assert(!sameName('Jonas Example', 'Mara Synthetic'));
});

Deno.test('plan: an ID of someone else is a new companion; the booker\'s own is "own"; a known companion is reused', () => {
  const other = planFor({ kind: 'id', name: 'Nora Mae D. Sample', idType: 'passport' }, G)!;
  assertEquals([other.kind, (other as any).own, (other as any).existing, (other as any).companionName], ['id', false, false, 'Nora Mae D. Sample']);
  const own = planFor({ kind: 'id', name: 'Jonas T. Example', idType: 'drivers_license' }, G)!;
  assertEquals((own as any).own, true);
  const known = planFor({ kind: 'id', name: 'Mara A. Synthetic', idType: 'national_id' }, G)!;
  assertEquals([(known as any).existing, (known as any).companionName], [true, 'Mara Synthetic'], 'the existing row is reused so no duplicate is made');
});

Deno.test('plan: a chat screenshot only offers what is new; nothing new is no plan', () => {
  const p = planFor({ kind: 'chat', names: ['Jonas Example', 'Mara Synthetic', 'Ben Test'], phone: '09170001234' }, { ...G, has_contact: true })! as any;
  assertEquals([p.phone, p.replacesPhone, p.newNames, p.knownNames], ['09170001234', true, ['Ben Test'], ['Jonas Example', 'Mara Synthetic']]);
  assertEquals(planFor({ kind: 'chat', names: ['Mara Synthetic'], phone: null }, G), null);
  assertEquals(planFor({ kind: 'other' }, G), null);
});

Deno.test('confirm card: says what will be saved, leads with "nothing is saved yet", ends with the one action', () => {
  const other = confirmBody(planFor({ kind: 'id', name: 'Nora Mae D. Sample', idType: 'passport' }, G)!);
  assertEquals(other[0], "Nothing is saved yet. Save Nora Mae D. Sample's passport photo as a companion of Jonas Example and mark ID on file?");
  assert(other.includes('• No ID number is read or saved.'));
  assertEquals(other[other.length - 1], 'Do: tap Save if this is right.');
  const own = confirmBody(planFor({ kind: 'id', name: 'Jonas Example', idType: 'passport' }, G)!);
  assertEquals(own[0], "Nothing is saved yet. Save Jonas Example's own passport photo to their guest record and mark ID on file?");
  const chat = confirmBody(planFor({ kind: 'chat', names: ['Ben Test'], phone: '09170001234' }, { ...G, has_contact: true })!);
  assertEquals(chat.slice(2, 4), ['• Phone 09170001234 (replaces the number on file)', '• Add as companions: Ben Test']);
  assert([...other, ...own, ...chat].every((l) => l.length < 200), 'short lines for a phone');
});

Deno.test('picker label: in house, dated, or last stay; ID mark', () => {
  assertEquals(pickLabel(G, '2026-10-02'), 'Jonas Example · in house');
  assertEquals(pickLabel(G, '2026-09-28'), 'Jonas Example · Oct 1-Oct 5');
  assertEquals(pickLabel({ ...G, checkin: null, checkout: null, last_stay: '2026-09-14', id_on_file: true }, '2026-10-02'), 'Jonas Example · last stay Sep 14 ✓ID');
});

Deno.test('image sniffing: jpeg, png, webp only; anything else or too big is refused', () => {
  const jpg = new Uint8Array(20); jpg.set([0xff, 0xd8, 0xff, 0xe0]);
  const png = new Uint8Array(20); png.set([0x89, 0x50, 0x4e, 0x47]);
  const webp = new Uint8Array(20); webp.set([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);
  assertEquals(sniffImage(jpg)?.ext, 'jpg');
  assertEquals(sniffImage(png)?.mime, 'image/png');
  assertEquals(sniffImage(webp)?.ext, 'webp');
  assertEquals(sniffImage(new Uint8Array(20)), null);
  assertEquals(sniffImage(new Uint8Array(11 * 1024 * 1024)), null);
});

Deno.test('callback data: valid taps parse, malformed ones do not, and every one fits in 64 bytes', () => {
  const pid = '0b9f2c1e-7a4d-4e1b-9c3a-5d6e7f8a9b0c';
  assertEquals(parseGuestTap(`gst:pick:${pid}:3`), { act: 'pick', pid, i: 3 });
  assertEquals(parseGuestTap(`gst:save:${pid}`), { act: 'save', pid, i: -1 });
  assertEquals(parseGuestTap(`gst:pick:${pid}`), null, 'pick needs an index');
  assertEquals(parseGuestTap(`gst:save:${pid}:1`), null, 'save takes none');
  assertEquals(parseGuestTap('gst:save:not-a-uuid'), null);
  assertEquals(parseGuestTap(`crm:done:2026-10-02:${pid}`), null);
  assert(new TextEncoder().encode(`gst:pick:${pid}:11`).length <= 64);
});

Deno.test('session 72: confirmBody names the Airbnb message when the plan came from the e-mail, the screenshot otherwise', () => {
  const p = { kind: 'chat' as const, guestId: 'g', guestName: 'Jonas Example', phone: '09171230000', replacesPhone: false, newNames: [], knownNames: [] };
  assertEquals(confirmBody(p)[0].includes('from the chat screenshot'), true);
  assertEquals(confirmBody({ ...p, via: 'airbnb' })[0], 'Nothing is saved yet. Save these for Jonas Example from the Airbnb message?');
});
