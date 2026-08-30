import { assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { bearerToken, StaffAuthError } from './staff-auth.ts';

Deno.test('bearerToken accepts a single bearer token', () => {
  const request = new Request('https://example.test', {
    headers: { authorization: 'Bearer staff.jwt.token' },
  });
  assertEquals(bearerToken(request), 'staff.jwt.token');
});

Deno.test('bearerToken fails closed for missing or malformed authorization', () => {
  for (const authorization of ['', 'Basic abc', 'Bearer', 'Bearer one two']) {
    const request = new Request('https://example.test', { headers: { authorization } });
    const error = assertThrows(() => bearerToken(request));
    assertEquals(error instanceof StaffAuthError, true);
    assertEquals((error as StaffAuthError).status, 401);
  }
});
