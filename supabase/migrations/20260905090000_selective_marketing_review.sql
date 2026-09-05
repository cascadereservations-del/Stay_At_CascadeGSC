-- Wave 7 local candidate: consent-gated drafts and exact-content named-human review.
-- No function in this migration publishes, sends, queues, or invokes a provider.

create table public.marketing_drafts (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  profile_id uuid not null references public.crm_guest_profiles(id) on delete restrict,
  channel text not null check (channel in ('email', 'whatsapp', 'social')),
  subject_ciphertext text,
  subject_hash text check (subject_hash ~ '^[a-f0-9]{64}$'),
  content_ciphertext text not null check (char_length(content_ciphertext) between 16 and 20000),
  content_hash text not null check (content_hash ~ '^[a-f0-9]{64}$'),
  draft_source text not null check (draft_source in ('human', 'advisory_model')),
  advisory_output_hash text check (advisory_output_hash ~ '^[a-f0-9]{64}$'),
  target_reason text not null check (char_length(btrim(target_reason)) between 3 and 2000),
  includes_discount boolean not null default false,
  discount_terms_hash text check (discount_terms_hash ~ '^[a-f0-9]{64}$'),
  includes_claim boolean not null default false,
  claim_evidence_hash text check (claim_evidence_hash ~ '^[a-f0-9]{64}$'),
  consent_eligible_at_draft boolean not null check (consent_eligible_at_draft),
  publication_authorized boolean not null default false check (not publication_authorized),
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  created_at timestamptz not null default now(),
  check ((subject_ciphertext is null) = (subject_hash is null)),
  check ((draft_source = 'advisory_model') = (advisory_output_hash is not null)),
  check (includes_discount = (discount_terms_hash is not null)),
  check (includes_claim = (claim_evidence_hash is not null))
);

create table public.marketing_draft_reviews (
  id uuid primary key default extensions.uuid_generate_v4(),
  draft_id uuid not null unique references public.marketing_drafts(id) on delete restrict,
  property_id uuid not null references public.properties(id) on delete restrict,
  decision text not null check (decision in ('approved', 'rejected')),
  reviewed_content_hash text not null check (reviewed_content_hash ~ '^[a-f0-9]{64}$'),
  targeting_approved boolean not null,
  discount_approved boolean not null,
  claim_approved boolean not null,
  consent_rechecked boolean not null check (consent_rechecked),
  publication_authorized boolean not null default false check (not publication_authorized),
  reviewed_by_user_id uuid not null references auth.users(id) on delete restrict,
  reason text not null check (char_length(btrim(reason)) between 3 and 2000),
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  reviewed_at timestamptz not null default now(),
  check (
    decision = 'approved'
    or (not targeting_approved and not discount_approved and not claim_approved)
  )
);

create function public.create_marketing_draft(
  p_profile_id uuid,
  p_channel text,
  p_subject_ciphertext text,
  p_subject_hash text,
  p_content_ciphertext text,
  p_content_hash text,
  p_draft_source text,
  p_advisory_output_hash text,
  p_target_reason text,
  p_includes_discount boolean,
  p_discount_terms_hash text,
  p_includes_claim boolean,
  p_claim_evidence_hash text,
  p_idempotency_key text
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_profile public.crm_guest_profiles%rowtype;
  v_existing public.marketing_drafts%rowtype;
  v_id uuid;
begin
  select * into v_profile from public.crm_guest_profiles where id = p_profile_id;
  if not found or not public.crm_human_authorized(v_profile.property_id) then
    raise exception using errcode = '42501', message = 'marketing draft denied';
  end if;

  select * into v_existing from public.marketing_drafts where idempotency_key = p_idempotency_key;
  if found then
    if v_existing.profile_id is distinct from p_profile_id
      or v_existing.channel is distinct from p_channel
      or v_existing.subject_ciphertext is distinct from p_subject_ciphertext
      or v_existing.subject_hash is distinct from p_subject_hash
      or v_existing.content_ciphertext is distinct from p_content_ciphertext
      or v_existing.content_hash is distinct from p_content_hash
      or v_existing.draft_source is distinct from p_draft_source
      or v_existing.advisory_output_hash is distinct from p_advisory_output_hash
      or v_existing.target_reason is distinct from btrim(p_target_reason)
      or v_existing.includes_discount is distinct from coalesce(p_includes_discount, false)
      or v_existing.discount_terms_hash is distinct from p_discount_terms_hash
      or v_existing.includes_claim is distinct from coalesce(p_includes_claim, false)
      or v_existing.claim_evidence_hash is distinct from p_claim_evidence_hash
      or v_existing.created_by_user_id is distinct from auth.uid()
    then
      raise exception using errcode = '22023', message = 'marketing draft idempotency conflict';
    end if;
    return v_existing.id;
  end if;

  if not public.crm_marketing_eligible(p_profile_id) then
    raise exception using errcode = '22023', message = 'marketing profile is not eligible';
  end if;
  if p_channel not in ('email', 'whatsapp', 'social')
    or char_length(coalesce(p_content_ciphertext, '')) not between 16 and 20000
    or p_content_hash !~ '^[a-f0-9]{64}$'
    or ((p_subject_ciphertext is null) is distinct from (p_subject_hash is null))
    or (p_subject_hash is not null and p_subject_hash !~ '^[a-f0-9]{64}$')
    or p_draft_source not in ('human', 'advisory_model')
    or ((p_draft_source = 'advisory_model') is distinct from (p_advisory_output_hash is not null))
    or (p_advisory_output_hash is not null and p_advisory_output_hash !~ '^[a-f0-9]{64}$')
    or char_length(btrim(coalesce(p_target_reason, ''))) < 3
    or (coalesce(p_includes_discount, false) is distinct from (p_discount_terms_hash is not null))
    or (p_discount_terms_hash is not null and p_discount_terms_hash !~ '^[a-f0-9]{64}$')
    or (coalesce(p_includes_claim, false) is distinct from (p_claim_evidence_hash is not null))
    or (p_claim_evidence_hash is not null and p_claim_evidence_hash !~ '^[a-f0-9]{64}$')
  then
    raise exception using errcode = '22023', message = 'invalid marketing draft';
  end if;

  insert into public.marketing_drafts (
    property_id, profile_id, channel, subject_ciphertext, subject_hash,
    content_ciphertext, content_hash, draft_source, advisory_output_hash,
    target_reason, includes_discount, discount_terms_hash, includes_claim,
    claim_evidence_hash, consent_eligible_at_draft, publication_authorized,
    created_by_user_id, idempotency_key
  ) values (
    v_profile.property_id, v_profile.id, p_channel, p_subject_ciphertext, p_subject_hash,
    p_content_ciphertext, p_content_hash, p_draft_source, p_advisory_output_hash,
    btrim(p_target_reason), coalesce(p_includes_discount, false), p_discount_terms_hash,
    coalesce(p_includes_claim, false), p_claim_evidence_hash, true, false,
    auth.uid(), p_idempotency_key
  ) returning id into v_id;
  return v_id;
end;
$$;

create function public.review_marketing_draft(
  p_draft_id uuid,
  p_decision text,
  p_content_hash text,
  p_targeting_approved boolean,
  p_discount_approved boolean,
  p_claim_approved boolean,
  p_reason text,
  p_idempotency_key text
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_draft public.marketing_drafts%rowtype;
  v_existing public.marketing_draft_reviews%rowtype;
  v_id uuid;
begin
  select * into v_draft from public.marketing_drafts where id = p_draft_id for update;
  if not found or not public.crm_human_authorized(v_draft.property_id) then
    raise exception using errcode = '42501', message = 'marketing review denied';
  end if;

  select * into v_existing from public.marketing_draft_reviews where idempotency_key = p_idempotency_key;
  if found then
    if v_existing.draft_id is distinct from p_draft_id
      or v_existing.decision is distinct from p_decision
      or v_existing.reviewed_content_hash is distinct from p_content_hash
      or v_existing.targeting_approved is distinct from coalesce(p_targeting_approved, false)
      or v_existing.discount_approved is distinct from coalesce(p_discount_approved, false)
      or v_existing.claim_approved is distinct from coalesce(p_claim_approved, false)
      or v_existing.reason is distinct from btrim(p_reason)
      or v_existing.reviewed_by_user_id is distinct from auth.uid()
    then
      raise exception using errcode = '22023', message = 'marketing review idempotency conflict';
    end if;
    return v_existing.id;
  end if;

  if p_decision not in ('approved', 'rejected')
    or p_content_hash is distinct from v_draft.content_hash
    or char_length(btrim(coalesce(p_reason, ''))) < 3
  then
    raise exception using errcode = '22023', message = 'invalid or stale marketing review';
  end if;
  if p_decision = 'approved' and not public.crm_marketing_eligible(v_draft.profile_id) then
    raise exception using errcode = '22023', message = 'marketing consent or lifecycle no longer eligible';
  end if;
  if p_decision = 'approved' and (
    not coalesce(p_targeting_approved, false)
    or (v_draft.includes_discount and not coalesce(p_discount_approved, false))
    or (v_draft.includes_claim and not coalesce(p_claim_approved, false))
  ) then
    raise exception using errcode = '22023', message = 'required marketing review scope missing';
  end if;
  if p_decision = 'rejected' and (
    coalesce(p_targeting_approved, false)
    or coalesce(p_discount_approved, false)
    or coalesce(p_claim_approved, false)
  ) then
    raise exception using errcode = '22023', message = 'rejected draft cannot carry approvals';
  end if;

  insert into public.marketing_draft_reviews (
    draft_id, property_id, decision, reviewed_content_hash, targeting_approved,
    discount_approved, claim_approved, consent_rechecked, publication_authorized,
    reviewed_by_user_id, reason, idempotency_key
  ) values (
    v_draft.id, v_draft.property_id, p_decision, p_content_hash,
    coalesce(p_targeting_approved, false), coalesce(p_discount_approved, false),
    coalesce(p_claim_approved, false), true, false, auth.uid(), btrim(p_reason),
    p_idempotency_key
  ) returning id into v_id;
  return v_id;
end;
$$;

alter table public.marketing_drafts enable row level security;
alter table public.marketing_draft_reviews enable row level security;
revoke all on public.marketing_drafts, public.marketing_draft_reviews from public, anon, authenticated, service_role;
grant select on public.marketing_drafts, public.marketing_draft_reviews to authenticated;
create policy marketing_drafts_read on public.marketing_drafts for select to authenticated
  using (public.crm_human_authorized(property_id));
create policy marketing_reviews_read on public.marketing_draft_reviews for select to authenticated
  using (public.crm_human_authorized(property_id));

revoke all on function public.create_marketing_draft(uuid,text,text,text,text,text,text,text,text,boolean,text,boolean,text,text),
  public.review_marketing_draft(uuid,text,text,boolean,boolean,boolean,text,text)
  from public, anon, service_role;
grant execute on function public.create_marketing_draft(uuid,text,text,text,text,text,text,text,text,boolean,text,boolean,text,text),
  public.review_marketing_draft(uuid,text,text,boolean,boolean,boolean,text,text)
  to authenticated;

comment on table public.marketing_drafts is 'Private immutable draft material. Ciphertext and hashes only; no guest contact address or provider delivery state.';
comment on table public.marketing_draft_reviews is 'Named-human review bound to the exact content hash. Publication remains unauthorized.';
comment on function public.review_marketing_draft(uuid,text,text,boolean,boolean,boolean,text,text) is 'Approves review scope only. It never publishes, sends, queues, or invokes a provider.';
