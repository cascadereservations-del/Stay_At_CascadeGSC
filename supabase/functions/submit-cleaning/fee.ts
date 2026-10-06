// The Finance "cleaning complete" fee (D-301): the cleaner_rate_schedule row in force on the clean's PAY DAY, for this property.
// No property = no query (never another property's rate); a failed read is its own state; no usable rate is null, never a guessed 500.
// Only the Finance message shows it; fee_amount is written when Finance pays.
import { type FeeResult, feeResultOf } from '../_shared/cleaning-fee.ts';

// deno-lint-ignore no-explicit-any
export async function resolveFee(supabase: any, propertyId: string | null, cleaningType: string, payDay: string): Promise<FeeResult> {
  if (!propertyId) return { fee: null, error: true };
  try {
    return feeResultOf(
      await supabase
        .from('cleaner_rate_schedule')
        .select('regular_rate, general_rate, effective_from')
        .eq('property_id', propertyId)
        .lte('effective_from', payDay)
        .order('effective_from', { ascending: false })
        .limit(1)
        .maybeSingle(),
      cleaningType,
    );
  } catch (_) {
    return { fee: null, error: true };
  }
}
