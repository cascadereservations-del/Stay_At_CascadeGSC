// Guest tier badge for the booking card (SPEC-46). Tier values: returning | regular | vip | null.
export function tierBadge(tier: string|null, stays: number): string {
  if (tier === 'vip')       return `⭐ VIP Guest (${stays} stays)`;
  if (tier === 'regular')   return `🌟 Regular Guest (${stays} stays)`;
  if (tier === 'returning') return `🔄 Returning Guest (${stays} stays)`;
  // tier = completed stays only; total_stays already counts the upcoming booking, so a null tier with 2+ stays is returning.
  if (tier === null && stays >= 2) return `🔄 Returning Guest (${stays} stays)`;
  return '🆕 New Guest';
}
