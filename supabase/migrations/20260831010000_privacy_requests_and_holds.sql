create table public.privacy_requests (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  request_type text not null check (request_type in ('access','correction','deletion')),
  subject_kind text not null check (subject_kind in ('guest','staff','other')),
  subject_reference text not null check (char_length(subject_reference) between 1 and 200),
  contact_method text not null check (contact_method in ('email','phone','in_person','other')),
  scope text not null check (char_length(scope) between 3 and 2000),
  received_at timestamptz not null default now(),
  status text not null default 'received' check (status in (
    'received','identity_verified','in_review','on_hold','approved','denied','completed','cancelled'
  )),
  identity_verified_at timestamptz,
  identity_verified_by uuid,
  decided_at timestamptz,
  decided_by uuid,
  responded_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.privacy_holds (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  subject_kind text not null check (subject_kind in ('guest','staff','other')),
  subject_reference text not null check (char_length(subject_reference) between 1 and 200),
  hold_type text not null check (hold_type in (
    'legal','dispute','chargeback','safety','tax_accounting','unresolved_payment'
  )),
  reason text not null check (char_length(reason) between 3 and 2000),
  status text not null default 'active' check (status in ('active','released')),
  opened_by uuid not null,
  opened_at timestamptz not null default now(),
  released_by uuid,
  released_at timestamptz,
  release_reason text check (release_reason is null or char_length(release_reason) between 3 and 2000),
  check (
    (status = 'active' and released_by is null and released_at is null and release_reason is null)
    or
    (status = 'released' and released_by is not null and released_at is not null and release_reason is not null)
  )
);

create table public.privacy_action_audit (
  id uuid primary key default extensions.uuid_generate_v4(),
  entity_type text not null check (entity_type in ('request','hold')),
  entity_id uuid not null,
  property_id uuid not null references public.properties(id) on delete restrict,
  actor_user_id uuid not null,
  action text not null check (char_length(action) between 3 and 100),
  before_state jsonb not null default '{}'::jsonb,
  after_state jsonb not null default '{}'::jsonb,
  reason text not null check (char_length(reason) between 3 and 2000),
  created_at timestamptz not null default now()
);

create index privacy_requests_status_received_idx
  on public.privacy_requests (property_id, status, received_at)
  include (request_type, subject_kind);

create index privacy_holds_subject_status_idx
  on public.privacy_holds (property_id, subject_kind, subject_reference, status);

create index privacy_action_audit_entity_created_idx
  on public.privacy_action_audit (entity_type, entity_id, created_at desc);

alter table public.privacy_requests enable row level security;
alter table public.privacy_holds enable row level security;
alter table public.privacy_action_audit enable row level security;

revoke all on public.privacy_requests, public.privacy_holds, public.privacy_action_audit
  from public, anon, authenticated, service_role;

create or replace function public.staff_access_allowed(
  p_role text,
  p_action text,
  p_disabled_at timestamptz,
  p_aal text
)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_disabled_at is not null then false
    when p_action in ('manage_staff','approve_payment','read_finance','manage_privacy')
      and p_aal is distinct from 'aal2' then false
    when p_role in ('owner','admin') then p_action in (
      'manage_staff',
      'approve_payment',
      'read_finance',
      'read_operations',
      'manage_operations',
      'inspect_cleaning',
      'submit_cleaning',
      'manage_inventory',
      'manage_maintenance',
      'manage_privacy'
    )
    when p_role = 'finance' then p_action in (
      'approve_payment',
      'read_finance',
      'read_operations'
    )
    when p_role = 'inspector' then p_action in (
      'read_operations',
      'inspect_cleaning',
      'submit_cleaning'
    )
    when p_role = 'cleaner' then p_action in (
      'read_operations',
      'submit_cleaning'
    )
    when p_role = 'maintenance' then p_action in (
      'read_operations',
      'manage_maintenance'
    )
    else false
  end;
$$;

create or replace function public.create_privacy_request(
  p_property_id uuid,
  p_request_type text,
  p_subject_kind text,
  p_subject_reference text,
  p_contact_method text,
  p_scope text,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request_id uuid;
  v_after jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if not public.current_staff_authorized('manage_privacy', p_property_id) then
    raise exception using errcode = '42501', message = 'privacy management denied';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000 then
    raise exception using errcode = '22023', message = 'reason must be 3 to 2000 characters';
  end if;

  insert into public.privacy_requests (
    property_id, request_type, subject_kind, subject_reference,
    contact_method, scope, created_by
  ) values (
    p_property_id, p_request_type, p_subject_kind, btrim(p_subject_reference),
    p_contact_method, btrim(p_scope), auth.uid()
  )
  returning id, to_jsonb(privacy_requests.*) into v_request_id, v_after;

  insert into public.privacy_action_audit (
    entity_type, entity_id, property_id, actor_user_id, action, after_state, reason
  ) values (
    'request', v_request_id, p_property_id, auth.uid(), 'request_created', v_after, btrim(p_reason)
  );

  return v_request_id;
end;
$$;

create or replace function public.transition_privacy_request(
  p_request_id uuid,
  p_action text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.privacy_requests%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_has_hold boolean;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000 then
    raise exception using errcode = '22023', message = 'reason must be 3 to 2000 characters';
  end if;

  select * into v_request
  from public.privacy_requests
  where id = p_request_id
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'privacy request not found';
  end if;
  if not public.current_staff_authorized('manage_privacy', v_request.property_id) then
    raise exception using errcode = '42501', message = 'privacy management denied';
  end if;

  v_before := to_jsonb(v_request);
  select exists (
    select 1 from public.privacy_holds h
    where h.property_id = v_request.property_id
      and h.subject_kind = v_request.subject_kind
      and h.subject_reference = v_request.subject_reference
      and h.status = 'active'
  ) into v_has_hold;

  case p_action
    when 'verify_identity' then
      if v_request.status <> 'received' then
        raise exception using errcode = '23514', message = 'invalid privacy request transition';
      end if;
      update public.privacy_requests set
        status = 'identity_verified', identity_verified_at = now(),
        identity_verified_by = auth.uid(), updated_at = now()
      where id = p_request_id;
    when 'start_review' then
      if v_request.status <> 'identity_verified' then
        raise exception using errcode = '23514', message = 'invalid privacy request transition';
      end if;
      update public.privacy_requests set status = 'in_review', updated_at = now()
      where id = p_request_id;
    when 'place_on_hold' then
      if v_request.status <> 'in_review' or not v_has_hold then
        raise exception using errcode = '23514', message = 'active matching privacy hold required';
      end if;
      update public.privacy_requests set status = 'on_hold', updated_at = now()
      where id = p_request_id;
    when 'resume_review' then
      if v_request.status <> 'on_hold' then
        raise exception using errcode = '23514', message = 'invalid privacy request transition';
      end if;
      if v_has_hold then
        raise exception using errcode = '23514', message = 'active privacy hold blocks review';
      end if;
      update public.privacy_requests set status = 'in_review', updated_at = now()
      where id = p_request_id;
    when 'approve' then
      if v_request.status <> 'in_review' then
        raise exception using errcode = '23514', message = 'invalid privacy request transition';
      end if;
      if v_request.request_type = 'deletion' and v_has_hold then
        raise exception using errcode = '23514', message = 'active privacy hold blocks deletion approval';
      end if;
      update public.privacy_requests set
        status = 'approved', decided_at = now(), decided_by = auth.uid(), updated_at = now()
      where id = p_request_id;
    when 'deny' then
      if v_request.status <> 'in_review' then
        raise exception using errcode = '23514', message = 'invalid privacy request transition';
      end if;
      update public.privacy_requests set
        status = 'denied', decided_at = now(), decided_by = auth.uid(),
        responded_at = now(), updated_at = now()
      where id = p_request_id;
    when 'complete' then
      if v_request.status <> 'approved' then
        raise exception using errcode = '23514', message = 'invalid privacy request transition';
      end if;
      if v_request.request_type = 'deletion' and v_has_hold then
        raise exception using errcode = '23514', message = 'active privacy hold blocks deletion completion';
      end if;
      update public.privacy_requests set status = 'completed', responded_at = now(), updated_at = now()
      where id = p_request_id;
    when 'cancel' then
      if v_request.status not in ('received','identity_verified','in_review','on_hold') then
        raise exception using errcode = '23514', message = 'invalid privacy request transition';
      end if;
      update public.privacy_requests set
        status = 'cancelled', decided_at = now(), decided_by = auth.uid(),
        responded_at = now(), updated_at = now()
      where id = p_request_id;
    else
      raise exception using errcode = '22023', message = 'invalid privacy request action';
  end case;

  select to_jsonb(r) into v_after from public.privacy_requests r where r.id = p_request_id;
  insert into public.privacy_action_audit (
    entity_type, entity_id, property_id, actor_user_id, action, before_state, after_state, reason
  ) values (
    'request', p_request_id, v_request.property_id, auth.uid(),
    'request_' || p_action, v_before, v_after, btrim(p_reason)
  );
  return v_after;
end;
$$;

create or replace function public.manage_privacy_hold(
  p_hold_id uuid,
  p_action text,
  p_property_id uuid default null,
  p_subject_kind text default null,
  p_subject_reference text default null,
  p_hold_type text default null,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hold_id uuid;
  v_hold public.privacy_holds%rowtype;
  v_before jsonb := '{}'::jsonb;
  v_after jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'authentication required';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000 then
    raise exception using errcode = '22023', message = 'reason must be 3 to 2000 characters';
  end if;

  if p_action = 'create' then
    if p_property_id is null or not public.current_staff_authorized('manage_privacy', p_property_id) then
      raise exception using errcode = '42501', message = 'privacy management denied';
    end if;
    v_hold_id := coalesce(p_hold_id, extensions.uuid_generate_v4());
    insert into public.privacy_holds (
      id, property_id, subject_kind, subject_reference, hold_type, reason, opened_by
    ) values (
      v_hold_id, p_property_id, p_subject_kind, btrim(p_subject_reference),
      p_hold_type, btrim(p_reason), auth.uid()
    )
    returning * into v_hold;
    v_after := to_jsonb(v_hold);
  elsif p_action = 'release' then
    select * into v_hold from public.privacy_holds where id = p_hold_id for update;
    if not found then
      raise exception using errcode = '22023', message = 'privacy hold not found';
    end if;
    if not public.current_staff_authorized('manage_privacy', v_hold.property_id) then
      raise exception using errcode = '42501', message = 'privacy management denied';
    end if;
    if v_hold.status <> 'active' then
      raise exception using errcode = '23514', message = 'privacy hold is not active';
    end if;
    v_hold_id := v_hold.id;
    v_before := to_jsonb(v_hold);
    update public.privacy_holds set
      status = 'released', released_by = auth.uid(), released_at = now(),
      release_reason = btrim(p_reason)
    where id = v_hold_id
    returning * into v_hold;
    v_after := to_jsonb(v_hold);
  else
    raise exception using errcode = '22023', message = 'invalid privacy hold action';
  end if;

  insert into public.privacy_action_audit (
    entity_type, entity_id, property_id, actor_user_id, action, before_state, after_state, reason
  ) values (
    'hold', v_hold_id, v_hold.property_id, auth.uid(),
    'hold_' || p_action, v_before, v_after, btrim(p_reason)
  );
  return v_after;
end;
$$;

revoke all on function public.staff_access_allowed(text,text,timestamptz,text)
  from public, anon, authenticated, service_role;
grant execute on function public.staff_access_allowed(text,text,timestamptz,text)
  to service_role;

revoke all on function public.create_privacy_request(uuid,text,text,text,text,text,text)
  from public, anon, authenticated, service_role;
revoke all on function public.transition_privacy_request(uuid,text,text)
  from public, anon, authenticated, service_role;
revoke all on function public.manage_privacy_hold(uuid,text,uuid,text,text,text,text)
  from public, anon, authenticated, service_role;

grant execute on function public.create_privacy_request(uuid,text,text,text,text,text,text)
  to authenticated;
grant execute on function public.transition_privacy_request(uuid,text,text)
  to authenticated;
grant execute on function public.manage_privacy_hold(uuid,text,uuid,text,text,text,text)
  to authenticated;

comment on table public.privacy_requests is
  'Reviewed Cascade access, correction and deletion requests. No row automatically deletes operational data.';
comment on table public.privacy_holds is
  'Human-opened legal, dispute, payment, safety and accounting holds that block deletion transitions.';
comment on table public.privacy_action_audit is
  'Append-only audit trail for privacy request and hold actions; actor UUIDs survive Auth-user retirement.';
comment on function public.create_privacy_request(uuid,text,text,text,text,text,text) is
  'AAL2 owner/admin entry point for property-scoped privacy requests.';
comment on function public.transition_privacy_request(uuid,text,text) is
  'AAL2 owner/admin privacy request state machine; active matching holds block deletion.';
comment on function public.manage_privacy_hold(uuid,text,uuid,text,text,text,text) is
  'AAL2 owner/admin create/release workflow for property-scoped privacy holds.';
