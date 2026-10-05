const encoder = new TextEncoder();

function base64Url(bytes: Uint8Array): string {
  let value = '';
  for (const byte of bytes) value += String.fromCharCode(byte);
  return btoa(value).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

export function createGuestAccessToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64Url(bytes);
}

export async function hashGuestAccessToken(token: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(token)));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

const DAY_MS = 86_400_000;

// SPEC-42 s6: a status link lives until 7 days after check-out (Manila midnight of the check-out date, plus 7 days).
export function statusTokenExpiry(checkoutDate: string): Date {
  const checkout = new Date(`${checkoutDate}T00:00:00+08:00`);
  if (!Number.isFinite(checkout.getTime())) throw new Error('invalid_checkout_date');
  return new Date(checkout.getTime() + 7 * DAY_MS);
}

export type TokenStore = { insert(row: Record<string, unknown>): PromiseLike<{ error: { message: string } | null }> };

// Mints the capability token for one direct booking. Only the SHA-256 is stored; the raw token is returned once and never logged.
export async function mintStatusToken(
  store: TokenStore,
  booking: { propertyId: string; bookingId: string; checkoutDate: string },
): Promise<string | null> {
  const token = createGuestAccessToken();
  const { error } = await store.insert({
    property_id: booking.propertyId,
    booking_type: 'direct',
    booking_id: booking.bookingId,
    token_hash: await hashGuestAccessToken(token),
    expires_at: statusTokenExpiry(booking.checkoutDate).toISOString(),
  });
  return error ? null : token;
}
