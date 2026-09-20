-- SPEC-10 (fraud design control 3): has this receipt already been used on ANOTHER booking?
--
-- record_payment_evidence_candidate's duplicate check, read from the live function body on
-- 2026-09-20, is scoped to `booking_id = p_booking_id and content_hash = lower(p_content_hash)`
-- and never looks at normalized_reference. The same screenshot resent under a new booking is
-- therefore invisible today, and so is the same reference number on a different image. This adds
-- the across-booking read, advisory only, plus the two indexes it needs.
--
-- Additive: one new function and two new indexes. No column, row, policy, grant or existing
-- function is changed. Nothing calls it until upload-booking-receipt is redeployed.
begin;

-- The existing content-hash index is (booking_id, content_hash), which cannot serve a lookup that
-- deliberately crosses bookings. Both new indexes are property-scoped, the same scope the RPC uses.
create index if not exists payment_evidence_property_hash_idx
  on public.payment_evidence_candidates (property_id, content_hash);

create index if not exists payment_evidence_property_reference_idx
  on public.payment_evidence_candidates (property_id, normalized_reference)
  where normalized_reference is not null;

-- `s` is the candidate just recorded; `c` is every other candidate at the same property on a
-- DIFFERENT booking that carries the same image or the same reference number. normalized_reference
-- is already uppercased and stripped to [A-Z0-9] by record_payment_evidence_candidate, so equality
-- is the right comparison. A null reference never matches a null reference: the
-- `s.normalized_reference is not null` guard says so outright rather than leaning on SQL's null
-- semantics, which a later rewrite could lose.
create or replace function public.prior_receipt_use_v1(p_candidate_id uuid)
returns table (booking_id uuid, guest_name text, seen_at timestamptz, match text)
language sql
security definer
stable
set search_path to ''
as $function$
  select c.booking_id,
         b.guest_name,
         c.created_at as seen_at,
         case when c.content_hash = s.content_hash then 'image' else 'reference' end as match
  from public.payment_evidence_candidates s
  join public.payment_evidence_candidates c
    on  c.property_id = s.property_id
    and c.booking_id <> s.booking_id
    and (c.content_hash = s.content_hash
         or (s.normalized_reference is not null
             and c.normalized_reference = s.normalized_reference))
  join public.booking_inquiries b on b.id = c.booking_id
  where s.id = p_candidate_id
  order by c.created_at desc
  limit 3;
$function$;

-- Restated in full: a rehearsal restores --no-acl, where the original revoke is missing.
revoke all on function public.prior_receipt_use_v1(uuid) from public, anon, authenticated;
grant execute on function public.prior_receipt_use_v1(uuid) to service_role;

comment on function public.prior_receipt_use_v1(uuid) is
  'SPEC-10: other bookings at the same property that already carried this receipt image or reference number. Newest first, at most 3. Advisory only - it never blocks a Confirm tap.';

commit;
