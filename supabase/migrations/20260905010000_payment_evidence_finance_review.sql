-- Wave 1 / Module C (local release candidate only).
--
-- Evidence and deterministic matching are advisory. Only an authenticated,
-- named Finance/Admin reviewer at AAL2 can create the immutable review record
-- required by the canonical booking decision.

create table public.payment_evidence_candidates (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id),
  -- booking_inquiries.id is a logical reference until the legacy key repair.
  booking_id uuid not null,
  source_type text not null check (source_type in (
    'receipt_ocr', 'openrouter_advice', 'bank_email', 'manual_evidence'
  )),
  -- Opaque identifier only: never store a URL, object path, email address,
  -- subject, message body or provider payload here.
  source_artifact_id text not null
    check (source_artifact_id ~ '^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}$'),
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  idempotency_key text not null unique
    check (char_length(idempotency_key) between 16 and 160),
  parser_version text not null
    check (parser_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  observed_at timestamptz not null,
  parsed_at timestamptz not null default now(),
  normalized_amount numeric(12,2) check (normalized_amount > 0),
  normalized_currency text check (normalized_currency ~ '^[A-Z]{3}$'),
  normalized_reference text
    check (normalized_reference ~ '^[A-Z0-9]{4,64}$'),
  advisory_confidence numeric(5,4)
    check (advisory_confidence between 0 and 1),
  advisory_labels text[] not null default '{}'::text[]
    check (cardinality(advisory_labels) <= 12),
  source_admissibility text not null check (source_admissibility in (
    'allowlisted', 'rejected', 'missing', 'not_applicable'
  )),
  failure_code text check (failure_code in (
    'unreadable', 'schema_invalid', 'parser_error', 'sender_not_allowlisted',
    'subject_not_allowlisted', 'missing_message', 'malformed_message'
  )),
  candidate_status text not null check (candidate_status in (
    'candidate', 'incomplete', 'failed', 'duplicate'
  )),
  duplicate_of_candidate_id uuid references public.payment_evidence_candidates(id),
  created_at timestamptz not null default now(),
  check (
    (source_type = 'bank_email' and source_admissibility <> 'not_applicable')
    or (source_type <> 'bank_email' and source_admissibility = 'not_applicable')
  ),
  check (
    source_admissibility not in ('rejected', 'missing')
    or failure_code is not null
  ),
  check (
    candidate_status <> 'duplicate' or duplicate_of_candidate_id is not null
  )
);

create index payment_evidence_booking_created_idx
  on public.payment_evidence_candidates (booking_id, created_at desc);
create index payment_evidence_content_hash_idx
  on public.payment_evidence_candidates (booking_id, content_hash);

create table public.payment_evidence_comparisons (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id),
  booking_id uuid not null,
  evidence_candidate_ids uuid[] not null
    check (cardinality(evidence_candidate_ids) between 1 and 8),
  expected_amount numeric(12,2),
  expected_currency text not null default 'PHP'
    check (expected_currency ~ '^[A-Z]{3}$'),
  comparison_outcome text not null check (comparison_outcome in (
    'exact_match', 'mismatch', 'ambiguity', 'missing_fields', 'duplicate_evidence'
  )),
  amount_delta numeric(12,2),
  reference_match boolean,
  reason_codes text[] not null,
  algorithm_version text not null,
  comparison_key text not null unique check (comparison_key ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);

create index payment_evidence_comparison_booking_idx
  on public.payment_evidence_comparisons (booking_id, created_at desc);

create table public.payment_finance_reviews (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id),
  booking_id uuid not null,
  comparison_id uuid not null references public.payment_evidence_comparisons(id),
  reviewer_user_id uuid not null references auth.users(id),
  outcome text not null check (outcome in ('approved', 'rejected', 'needs_follow_up')),
  reason text not null check (char_length(btrim(reason)) between 3 and 500),
  reviewed_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index payment_finance_review_booking_idx
  on public.payment_finance_reviews (booking_id, reviewed_at desc);
create unique index payment_finance_review_one_final_idx
  on public.payment_finance_reviews (comparison_id)
  where outcome in ('approved', 'rejected');

alter table public.payment_evidence_candidates enable row level security;
alter table public.payment_evidence_comparisons enable row level security;
alter table public.payment_finance_reviews enable row level security;

revoke all on public.payment_evidence_candidates,
  public.payment_evidence_comparisons,
  public.payment_finance_reviews
  from public, anon, authenticated, service_role;
grant select on public.payment_evidence_candidates,
  public.payment_evidence_comparisons,
  public.payment_finance_reviews
  to authenticated;

create policy payment_evidence_finance_read
  on public.payment_evidence_candidates for select to authenticated
  using (public.current_staff_authorized('read_finance', property_id));
create policy payment_comparison_finance_read
  on public.payment_evidence_comparisons for select to authenticated
  using (public.current_staff_authorized('read_finance', property_id));
create policy payment_review_finance_read
  on public.payment_finance_reviews for select to authenticated
  using (public.current_staff_authorized('read_finance', property_id));

create or replace function public.record_payment_evidence_candidate(
  p_booking_id uuid,
  p_source_type text,
  p_source_artifact_id text,
  p_content_hash text,
  p_idempotency_key text,
  p_parser_version text,
  p_observed_at timestamptz,
  p_amount numeric default null,
  p_currency text default null,
  p_reference text default null,
  p_confidence numeric default null,
  p_advisory_labels text[] default '{}'::text[],
  p_source_admissibility text default 'not_applicable',
  p_failure_code text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.booking_inquiries%rowtype;
  v_existing_id uuid;
  v_duplicate_id uuid;
  v_id uuid;
  v_currency text := nullif(upper(btrim(coalesce(p_currency, ''))), '');
  v_reference text := nullif(regexp_replace(upper(btrim(coalesce(p_reference, ''))), '[^A-Z0-9]', '', 'g'), '');
  v_status text;
begin
  if p_source_type not in ('receipt_ocr','openrouter_advice','bank_email','manual_evidence') then
    raise exception using errcode = '22023', message = 'invalid evidence source';
  end if;
  if p_source_artifact_id is null or p_source_artifact_id !~ '^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}$' then
    raise exception using errcode = '22023', message = 'opaque source artifact id required';
  end if;
  if p_content_hash is null or lower(p_content_hash) !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'sha256 content hash required';
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode = '22023', message = 'invalid evidence idempotency key';
  end if;
  if p_parser_version is null or p_parser_version !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' then
    raise exception using errcode = '22023', message = 'invalid parser version';
  end if;
  if p_observed_at is null or p_observed_at > now() + interval '5 minutes' then
    raise exception using errcode = '22023', message = 'invalid evidence timestamp';
  end if;
  if p_amount is not null and p_amount <= 0 then
    raise exception using errcode = '22023', message = 'invalid evidence amount';
  end if;
  if v_currency is not null and v_currency !~ '^[A-Z]{3}$' then
    raise exception using errcode = '22023', message = 'invalid evidence currency';
  end if;
  if v_reference is not null and v_reference !~ '^[A-Z0-9]{4,64}$' then
    raise exception using errcode = '22023', message = 'invalid evidence reference';
  end if;
  if p_confidence is not null and (p_confidence < 0 or p_confidence > 1) then
    raise exception using errcode = '22023', message = 'invalid advisory confidence';
  end if;
  if cardinality(coalesce(p_advisory_labels, '{}'::text[])) > 12
    or exists (
      select 1 from unnest(coalesce(p_advisory_labels, '{}'::text[])) label
      where label !~ '^[a-z0-9_]{2,40}$'
    ) then
    raise exception using errcode = '22023', message = 'invalid advisory labels';
  end if;
  if p_source_admissibility not in ('allowlisted','rejected','missing','not_applicable')
    or (p_source_type = 'bank_email' and p_source_admissibility = 'not_applicable')
    or (p_source_type <> 'bank_email' and p_source_admissibility <> 'not_applicable') then
    raise exception using errcode = '22023', message = 'invalid source admissibility';
  end if;
  if p_failure_code is not null and p_failure_code not in (
    'unreadable','schema_invalid','parser_error','sender_not_allowlisted',
    'subject_not_allowlisted','missing_message','malformed_message'
  ) then
    raise exception using errcode = '22023', message = 'invalid evidence failure code';
  end if;
  if p_source_admissibility in ('rejected','missing') and p_failure_code is null then
    raise exception using errcode = '22023', message = 'closed source requires failure code';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('cascade-payment-evidence:' || p_idempotency_key, 0));
  select id into v_existing_id
  from public.payment_evidence_candidates where idempotency_key = p_idempotency_key;
  if found then return v_existing_id; end if;

  select * into v_booking from public.booking_inquiries
  where id = p_booking_id and source = 'direct';
  if not found then raise exception using errcode = '22023', message = 'direct booking not found'; end if;

  select id into v_duplicate_id
  from public.payment_evidence_candidates
  where booking_id = p_booking_id and content_hash = lower(p_content_hash)
  order by created_at, id limit 1;

  v_status := case
    when v_duplicate_id is not null then 'duplicate'
    when p_failure_code is not null then 'failed'
    when p_amount is null or v_currency is null then 'incomplete'
    else 'candidate'
  end;

  insert into public.payment_evidence_candidates (
    property_id, booking_id, source_type, source_artifact_id, content_hash,
    idempotency_key, parser_version, observed_at, normalized_amount,
    normalized_currency, normalized_reference, advisory_confidence,
    advisory_labels, source_admissibility, failure_code, candidate_status,
    duplicate_of_candidate_id
  ) values (
    v_booking.property_id, p_booking_id, p_source_type, p_source_artifact_id,
    lower(p_content_hash), p_idempotency_key, p_parser_version, p_observed_at,
    p_amount, v_currency, v_reference, p_confidence,
    coalesce(p_advisory_labels, '{}'::text[]), p_source_admissibility,
    p_failure_code, v_status, v_duplicate_id
  ) returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.record_payment_evidence_candidate(
  uuid,text,text,text,text,text,timestamptz,numeric,text,text,numeric,text[],text,text
) from public, anon, authenticated;
grant execute on function public.record_payment_evidence_candidate(
  uuid,text,text,text,text,text,timestamptz,numeric,text,text,numeric,text[],text,text
) to service_role;

create or replace function public.compare_booking_payment_evidence(
  p_booking_id uuid,
  p_candidate_ids uuid[]
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.booking_inquiries%rowtype;
  v_ids uuid[];
  v_count integer;
  v_expected numeric(12,2);
  v_outcome text;
  v_reasons text[] := '{}'::text[];
  v_key text;
  v_existing uuid;
  v_id uuid;
  v_amount_delta numeric(12,2);
  v_reference_match boolean;
begin
  select coalesce(array_agg(distinct candidate_id order by candidate_id), '{}'::uuid[])
    into v_ids from unnest(coalesce(p_candidate_ids, '{}'::uuid[])) candidate_id;
  if cardinality(v_ids) not between 1 and 8
    or cardinality(v_ids) <> cardinality(coalesce(p_candidate_ids, '{}'::uuid[])) then
    raise exception using errcode = '22023', message = 'one to eight distinct evidence candidates required';
  end if;

  select * into v_booking from public.booking_inquiries
  where id = p_booking_id and source = 'direct';
  if not found then raise exception using errcode = '22023', message = 'direct booking not found'; end if;
  v_expected := case when v_booking.deposit_amount > 0 then v_booking.deposit_amount else v_booking.total_amount end;

  select count(*) into v_count from public.payment_evidence_candidates
  where id = any(v_ids) and booking_id = p_booking_id and property_id = v_booking.property_id;
  if v_count <> cardinality(v_ids) then
    raise exception using errcode = '22023', message = 'evidence candidate scope mismatch';
  end if;

  if exists (
    select 1 from public.payment_evidence_candidates
    where id = any(v_ids) and candidate_status = 'duplicate'
  ) or (
    select count(distinct content_hash) < count(*)
    from public.payment_evidence_candidates where id = any(v_ids)
  ) then
    v_outcome := 'duplicate_evidence';
    v_reasons := array['duplicate_content'];
  elsif v_expected is null or exists (
    select 1 from public.payment_evidence_candidates
    where id = any(v_ids)
      and (candidate_status in ('failed','incomplete')
        or normalized_amount is null or normalized_currency is null)
  ) then
    v_outcome := 'missing_fields';
    v_reasons := array['required_field_missing'];
  elsif exists (
    select 1 from public.payment_evidence_candidates
    where id = any(v_ids)
      and (normalized_amount <> v_expected or normalized_currency <> 'PHP')
  ) then
    v_outcome := 'mismatch';
    v_reasons := array['amount_or_currency_mismatch'];
  elsif (
    select count(distinct normalized_reference)
    from public.payment_evidence_candidates
    where id = any(v_ids) and normalized_reference is not null
  ) > 1 then
    v_outcome := 'mismatch';
    v_reasons := array['reference_mismatch'];
  elsif cardinality(v_ids) = 1 or exists (
    select 1 from public.payment_evidence_candidates
    where id = any(v_ids) and normalized_reference is null
  ) then
    v_outcome := 'ambiguity';
    v_reasons := array['insufficient_corroboration'];
  else
    v_outcome := 'exact_match';
    v_reasons := array['amount_currency_reference_match'];
  end if;

  select max(abs(normalized_amount - v_expected)) into v_amount_delta
  from public.payment_evidence_candidates where id = any(v_ids);
  select case when count(normalized_reference) = count(*)
    then count(distinct normalized_reference) = 1 else null end
    into v_reference_match
  from public.payment_evidence_candidates where id = any(v_ids);

  v_key := encode(extensions.digest(
    p_booking_id::text || '|' || array_to_string(v_ids, ',') || '|payment-compare-v1',
    'sha256'
  ), 'hex');
  perform pg_advisory_xact_lock(hashtextextended('cascade-payment-comparison:' || v_key, 0));
  select id into v_existing from public.payment_evidence_comparisons where comparison_key = v_key;
  if found then return v_existing; end if;

  insert into public.payment_evidence_comparisons (
    property_id, booking_id, evidence_candidate_ids, expected_amount,
    expected_currency, comparison_outcome, amount_delta, reference_match,
    reason_codes, algorithm_version, comparison_key
  ) values (
    v_booking.property_id, p_booking_id, v_ids, v_expected, 'PHP', v_outcome,
    v_amount_delta, v_reference_match, v_reasons, 'payment-compare-v1', v_key
  ) returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.compare_booking_payment_evidence(uuid,uuid[])
  from public, anon, authenticated;
grant execute on function public.compare_booking_payment_evidence(uuid,uuid[])
  to service_role;

create or replace function public.record_payment_finance_review(
  p_comparison_id uuid,
  p_outcome text,
  p_reason text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_comparison public.payment_evidence_comparisons%rowtype;
  v_existing public.payment_finance_reviews%rowtype;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if p_outcome not in ('approved','rejected','needs_follow_up') then
    raise exception using errcode = '22023', message = 'invalid Finance review outcome';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 3 and 500 then
    raise exception using errcode = '22023', message = 'Finance review reason required';
  end if;
  select * into v_comparison from public.payment_evidence_comparisons
  where id = p_comparison_id;
  if not found then raise exception using errcode = '22023', message = 'comparison not found'; end if;
  if not public.current_staff_authorized('approve_payment', v_comparison.property_id) then
    raise exception using errcode = '42501', message = 'Finance review denied';
  end if;

  if p_outcome in ('approved','rejected') then
    select * into v_existing from public.payment_finance_reviews
    where comparison_id = p_comparison_id and outcome in ('approved','rejected')
    for share;
    if found then
      if v_existing.reviewer_user_id = auth.uid()
        and v_existing.outcome = p_outcome
        and v_existing.reason = btrim(p_reason) then
        return v_existing.id;
      end if;
      raise exception using errcode = '23505', message = 'final Finance review already recorded';
    end if;
  end if;

  insert into public.payment_finance_reviews (
    property_id, booking_id, comparison_id, reviewer_user_id, outcome, reason
  ) values (
    v_comparison.property_id, v_comparison.booking_id, v_comparison.id,
    auth.uid(), p_outcome, btrim(p_reason)
  ) returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.record_payment_finance_review(uuid,text,text)
  from public, anon, service_role;
grant execute on function public.record_payment_finance_review(uuid,text,text)
  to authenticated;

-- Replace the Module B service-only entry point with a reviewed entry point.
alter function public.decide_direct_booking(uuid,text,text)
  rename to decide_direct_booking_without_finance_review;
revoke all on function public.decide_direct_booking_without_finance_review(uuid,text,text)
  from public, anon, authenticated, service_role;

alter table public.booking_decisions
  add column finance_review_id uuid references public.payment_finance_reviews(id);
create unique index booking_decisions_finance_review_unique_idx
  on public.booking_decisions(finance_review_id)
  where finance_review_id is not null;

-- Module B allowed service-role table access while its transaction boundary was
-- being established. Module C closes that bypass: integrations execute only the
-- reviewed RPC and cannot fabricate or relink decision records directly.
revoke all on public.booking_decisions
  from public, anon, authenticated, service_role;

create or replace function public.decide_direct_booking(
  p_booking_id uuid,
  p_action text,
  p_idempotency_key text,
  p_finance_review_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_review public.payment_finance_reviews%rowtype;
  v_existing public.booking_decisions%rowtype;
  v_result jsonb;
begin
  if p_finance_review_id is null then
    raise exception using errcode = '42501', message = 'named Finance review required';
  end if;
  select * into v_review from public.payment_finance_reviews
  where id = p_finance_review_id for share;
  if not found or v_review.booking_id <> p_booking_id then
    raise exception using errcode = '42501', message = 'Finance review does not match booking';
  end if;
  if (p_action = 'confirm' and v_review.outcome <> 'approved')
    or (p_action = 'decline' and v_review.outcome <> 'rejected') then
    raise exception using errcode = '42501', message = 'Finance review outcome does not authorize action';
  end if;

  select * into v_existing from public.booking_decisions
  where idempotency_key = p_idempotency_key;
  if found and v_existing.finance_review_id is distinct from p_finance_review_id then
    raise exception using errcode = '23505', message = 'decision key is linked to another Finance review';
  end if;

  v_result := public.decide_direct_booking_without_finance_review(
    p_booking_id, p_action, p_idempotency_key
  );
  update public.booking_decisions
  set finance_review_id = p_finance_review_id
  where idempotency_key = p_idempotency_key and finance_review_id is null;

  -- The internal engine serializes on the decision idempotency key. Re-read
  -- after it returns so a concurrent caller cannot report a different review
  -- from the one that actually won and was persisted.
  select * into v_existing from public.booking_decisions
  where idempotency_key = p_idempotency_key;
  if not found or v_existing.finance_review_id is distinct from p_finance_review_id then
    raise exception using errcode = '23505', message = 'decision key is linked to another Finance review';
  end if;

  return v_result || jsonb_build_object(
    'finance_review_id', p_finance_review_id,
    'reviewer_user_id', v_review.reviewer_user_id
  );
end;
$$;

revoke all on function public.decide_direct_booking(uuid,text,text,uuid)
  from public, anon, authenticated;
grant execute on function public.decide_direct_booking(uuid,text,text,uuid)
  to service_role;

comment on table public.payment_evidence_candidates is
  'Private advisory payment evidence. Rows cannot confirm payment or bookings.';
comment on table public.payment_evidence_comparisons is
  'Immutable deterministic comparison output; never a payment decision.';
comment on table public.payment_finance_reviews is
  'Immutable named-human Finance review history required by booking decisions.';
comment on function public.record_payment_finance_review(uuid,text,text) is
  'AAL2 named Finance/Admin review entry point. Service roles cannot execute it.';
