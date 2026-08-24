export type GuestIdentityResult = {
  guestId: string | null;
  matchBasis: 'phone' | 'email' | 'new' | 'conflict';
  previousCompletedStays: number;
  totalCompletedNights: number;
  isReturning: boolean;
};

export function normalizePhilippinePhone(value: string | null | undefined): string | null {
  const digits = String(value ?? '').replace(/\D/g, '');
  if (/^09\d{9}$/.test(digits)) return `+63${digits.slice(1)}`;
  if (/^9\d{9}$/.test(digits)) return `+63${digits}`;
  if (/^639\d{9}$/.test(digits)) return `+${digits}`;
  return null;
}

export function normalizeEmail(value: string | null | undefined): string | null {
  const normalized = String(value ?? '').trim().toLowerCase();
  return normalized && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized) ? normalized : null;
}
