-- Wave 2 local candidate: consent-aware shared guest inbox.
-- No function in this migration sends a message or calls a provider.

create or replace function public.staff_access_allowed(
  p_role text,p_action text,p_disabled_at timestamptz,p_aal text
) returns boolean language sql immutable set search_path='' as $$
  select case
    when p_disabled_at is not null then false
    when p_action in (
      'manage_staff','approve_payment','read_finance','manage_privacy','manage_booking',
      'approve_refund','publish_rate_policy','manage_guest_inbox'
    ) and p_aal is distinct from 'aal2' then false
    when p_role in ('owner','admin') then p_action in (
      'manage_staff','approve_payment','read_finance','read_operations','manage_operations',
      'inspect_cleaning','submit_cleaning','manage_inventory','manage_maintenance',
      'manage_privacy','manage_booking','approve_refund','publish_rate_policy','manage_guest_inbox'
    )
    when p_role='finance' then p_action in ('approve_payment','read_finance','read_operations','approve_refund')
    when p_role='inspector' then p_action in ('read_operations','inspect_cleaning','submit_cleaning')
    when p_role='cleaner' then p_action in ('read_operations','submit_cleaning')
    when p_role='maintenance' then p_action in ('read_operations','manage_maintenance')
    else false end;
$$;

create table public.guest_conversations (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  guest_id uuid references public.guests(id) on delete set null,
  booking_id uuid,
  channel text not null check(channel in ('direct_web','email','messenger','whatsapp','internal')),
  purpose text not null default 'stay_service' check(purpose in ('stay_service','booking_support','service_recovery')),
  external_thread_hash text not null check(external_thread_hash ~ '^[a-f0-9]{64}$'),
  status text not null default 'open' check(status in ('open','escalated','resolved')),
  escalation_code text check(escalation_code is null or escalation_code in (
    'payment','refund','cancellation','complaint','safety','access','policy_exception','uncertain'
  )),
  assigned_to uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(property_id,channel,external_thread_hash)
);

create table public.guest_conversation_messages (
  id uuid primary key default extensions.uuid_generate_v4(),
  conversation_id uuid not null references public.guest_conversations(id) on delete restrict,
  direction text not null check(direction in ('inbound','outbound_record')),
  sender_kind text not null check(sender_kind in ('guest','staff','provider_import')),
  body_ciphertext text not null check(char_length(body_ciphertext) between 24 and 20000),
  preview_redacted text not null check(
    char_length(preview_redacted) between 1 and 240
    and preview_redacted !~* '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}'
    and preview_redacted !~ '[0-9]{7,}'
  ),
  content_sha256 text not null check(content_sha256 ~ '^[a-f0-9]{64}$'),
  source_artifact_hash text not null check(source_artifact_hash ~ '^[a-f0-9]{64}$'),
  idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
  received_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table public.guest_reply_drafts (
  id uuid primary key default extensions.uuid_generate_v4(),
  conversation_id uuid not null references public.guest_conversations(id) on delete restrict,
  proposed_by text not null check(proposed_by in ('assistant','staff')),
  body_ciphertext text not null check(char_length(body_ciphertext) between 24 and 20000),
  preview_redacted text not null check(
    char_length(preview_redacted) between 1 and 240
    and preview_redacted !~* '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}'
    and preview_redacted !~ '[0-9]{7,}'
  ),
  risk_code text not null check(risk_code in (
    'routine','payment','refund','cancellation','complaint','safety','access','policy_exception','uncertain'
  )),
  status text not null default 'proposed' check(status in ('proposed','approved','rejected','withdrawn')),
  reviewer_user_id uuid references auth.users(id) on delete restrict,
  review_reason text check(review_reason is null or char_length(review_reason) between 3 and 2000),
  reviewed_at timestamptz,
  idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
  created_at timestamptz not null default now(),
  check(
    (status='proposed' and reviewer_user_id is null and review_reason is null and reviewed_at is null)
    or (status in ('approved','rejected') and reviewer_user_id is not null and review_reason is not null and reviewed_at is not null)
    or status='withdrawn'
  )
);

create table public.guest_conversation_audit (
  id uuid primary key default extensions.uuid_generate_v4(),
  conversation_id uuid not null references public.guest_conversations(id) on delete restrict,
  actor_user_id uuid references auth.users(id) on delete restrict,
  action text not null check(action in ('message_ingested','escalated','assigned','resolved','reopened','draft_proposed','draft_approved','draft_rejected')),
  reason_code text not null check(char_length(reason_code) between 3 and 80),
  idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 180),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index guest_conversations_queue_idx on public.guest_conversations(property_id,status,updated_at desc);
create index guest_messages_timeline_idx on public.guest_conversation_messages(conversation_id,received_at,id);

alter table public.guest_conversations enable row level security;
alter table public.guest_conversation_messages enable row level security;
alter table public.guest_reply_drafts enable row level security;
alter table public.guest_conversation_audit enable row level security;
revoke all on public.guest_conversations,public.guest_conversation_messages,
  public.guest_reply_drafts,public.guest_conversation_audit from public,anon,authenticated,service_role;

create policy guest_conversations_admin_read on public.guest_conversations for select to authenticated
  using(public.current_staff_authorized('manage_guest_inbox',property_id));
create policy guest_messages_admin_read on public.guest_conversation_messages for select to authenticated
  using(exists(select 1 from public.guest_conversations c where c.id=conversation_id
    and public.current_staff_authorized('manage_guest_inbox',c.property_id)));
create policy guest_drafts_admin_read on public.guest_reply_drafts for select to authenticated
  using(exists(select 1 from public.guest_conversations c where c.id=conversation_id
    and public.current_staff_authorized('manage_guest_inbox',c.property_id)));
create policy guest_audit_admin_read on public.guest_conversation_audit for select to authenticated
  using(exists(select 1 from public.guest_conversations c where c.id=conversation_id
    and public.current_staff_authorized('manage_guest_inbox',c.property_id)));
grant select on public.guest_conversations,public.guest_conversation_messages,
  public.guest_reply_drafts,public.guest_conversation_audit to authenticated;

create or replace function public.ingest_guest_message(
  p_property_id uuid,p_guest_id uuid,p_booking_id uuid,p_channel text,
  p_external_thread_hash text,p_body_ciphertext text,p_preview_redacted text,
  p_content_sha256 text,p_source_artifact_hash text,p_received_at timestamptz,
  p_escalation_code text,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_conversation public.guest_conversations%rowtype; v_message_id uuid; v_is_escalated boolean;
begin
  if p_channel not in ('direct_web','email','messenger','whatsapp','internal')
    or p_external_thread_hash !~ '^[a-f0-9]{64}$' or p_content_sha256 !~ '^[a-f0-9]{64}$'
    or p_source_artifact_hash !~ '^[a-f0-9]{64}$' or char_length(p_body_ciphertext) not between 24 and 20000
    or char_length(p_preview_redacted) not between 1 and 240
    or p_preview_redacted ~* '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' or p_preview_redacted ~ '[0-9]{7,}'
    or p_received_at is null or p_received_at > now()+interval '5 minutes'
    or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160
    or (p_escalation_code is not null and p_escalation_code not in (
      'payment','refund','cancellation','complaint','safety','access','policy_exception','uncertain'
    )) then raise exception using errcode='22023',message='invalid guest message'; end if;
  select c.* into v_conversation from public.guest_conversations c
    where c.property_id=p_property_id and c.channel=p_channel and c.external_thread_hash=p_external_thread_hash for update;
  if not found then
    insert into public.guest_conversations(property_id,guest_id,booking_id,channel,external_thread_hash)
    values(p_property_id,p_guest_id,p_booking_id,p_channel,p_external_thread_hash) returning * into v_conversation;
  end if;
  select id into v_message_id from public.guest_conversation_messages where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('ok',true,'conversation_id',v_conversation.id,'message_id',v_message_id,'already_processed',true); end if;
  insert into public.guest_conversation_messages(
    conversation_id,direction,sender_kind,body_ciphertext,preview_redacted,content_sha256,
    source_artifact_hash,idempotency_key,received_at
  ) values(v_conversation.id,'inbound','provider_import',p_body_ciphertext,p_preview_redacted,
    p_content_sha256,p_source_artifact_hash,p_idempotency_key,p_received_at) returning id into v_message_id;
  v_is_escalated := p_escalation_code is not null;
  update public.guest_conversations set status=case when v_is_escalated then 'escalated' else status end,
    escalation_code=coalesce(p_escalation_code,escalation_code),updated_at=now() where id=v_conversation.id;
  insert into public.guest_conversation_audit(conversation_id,action,reason_code,idempotency_key,details)
  values(v_conversation.id,'message_ingested','provider_ingest','audit:'||p_idempotency_key,
    jsonb_build_object('message_id',v_message_id,'channel',p_channel));
  if v_is_escalated then
    insert into public.guest_conversation_audit(conversation_id,action,reason_code,idempotency_key)
    values(v_conversation.id,'escalated',p_escalation_code,'escalate:'||p_idempotency_key);
  end if;
  return jsonb_build_object('ok',true,'conversation_id',v_conversation.id,'message_id',v_message_id,
    'escalated',v_is_escalated,'already_processed',false);
end;
$$;

create or replace function public.propose_guest_reply(
  p_conversation_id uuid,p_body_ciphertext text,p_preview_redacted text,p_risk_code text,p_idempotency_key text
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_conversation public.guest_conversations%rowtype;
begin
  select * into v_conversation from public.guest_conversations where id=p_conversation_id for update;
  if not found then raise exception using errcode='22023',message='conversation not found'; end if;
  if p_risk_code not in ('routine','payment','refund','cancellation','complaint','safety','access','policy_exception','uncertain')
    or char_length(p_body_ciphertext) not between 24 and 20000 or char_length(p_preview_redacted) not between 1 and 240
    or p_preview_redacted ~* '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' or p_preview_redacted ~ '[0-9]{7,}'
    or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160
    then raise exception using errcode='22023',message='invalid reply draft'; end if;
  select id into v_id from public.guest_reply_drafts where idempotency_key=p_idempotency_key;
  if found then return v_id; end if;
  insert into public.guest_reply_drafts(conversation_id,proposed_by,body_ciphertext,preview_redacted,risk_code,idempotency_key)
    values(p_conversation_id,'assistant',p_body_ciphertext,p_preview_redacted,p_risk_code,p_idempotency_key) returning id into v_id;
  if p_risk_code<>'routine' then
    update public.guest_conversations set status='escalated',escalation_code=p_risk_code,updated_at=now() where id=p_conversation_id;
  end if;
  insert into public.guest_conversation_audit(conversation_id,action,reason_code,idempotency_key,details)
    values(p_conversation_id,'draft_proposed',p_risk_code,'audit:'||p_idempotency_key,jsonb_build_object('draft_id',v_id));
  return v_id;
end;
$$;

create or replace function public.manage_guest_conversation(
  p_conversation_id uuid,p_action text,p_target_user_id uuid,p_reason text,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_conversation public.guest_conversations%rowtype; v_audit_action text;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='authentication required'; end if;
  select * into v_conversation from public.guest_conversations where id=p_conversation_id for update;
  if not found then raise exception using errcode='22023',message='conversation not found'; end if;
  if not public.current_staff_authorized('manage_guest_inbox',v_conversation.property_id) then
    raise exception using errcode='42501',message='guest inbox denied'; end if;
  if p_action not in ('assign','resolve','reopen') or char_length(btrim(p_reason)) not between 3 and 2000
    or char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode='22023',message='invalid conversation action'; end if;
  if exists(select 1 from public.guest_conversation_audit where idempotency_key=p_idempotency_key) then
    return jsonb_build_object('ok',true,'already_processed',true); end if;
  if p_action='assign' then
    if p_target_user_id is null or not exists(
      select 1 from public.staff_access_profiles p join public.staff_property_access s on s.user_id=p.user_id
      where p.user_id=p_target_user_id and p.role in ('owner','admin') and p.disabled_at is null
        and s.property_id=v_conversation.property_id
    ) then raise exception using errcode='42501',message='assignee is not authorized for guest inbox'; end if;
    update public.guest_conversations set assigned_to=p_target_user_id,updated_at=now() where id=p_conversation_id;
    v_audit_action:='assigned';
  else
    update public.guest_conversations set status=case when p_action='resolve' then 'resolved' else 'open' end,
      escalation_code=case when p_action='reopen' then null else escalation_code end,updated_at=now()
      where id=p_conversation_id;
    v_audit_action:=case when p_action='resolve' then 'resolved' else 'reopened' end;
  end if;
  insert into public.guest_conversation_audit(conversation_id,actor_user_id,action,reason_code,idempotency_key,details)
    values(p_conversation_id,auth.uid(),v_audit_action,'human_action',p_idempotency_key,
      jsonb_build_object('reason',btrim(p_reason),'target_user_id',p_target_user_id));
  return jsonb_build_object('ok',true,'already_processed',false);
end;
$$;

create or replace function public.review_guest_reply_draft(
  p_draft_id uuid,p_outcome text,p_reason text,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_draft public.guest_reply_drafts%rowtype; v_property_id uuid;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='authentication required'; end if;
  select d.* into v_draft from public.guest_reply_drafts d
    where d.id=p_draft_id for update;
  if not found then raise exception using errcode='22023',message='draft not found'; end if;
  select c.property_id into v_property_id from public.guest_conversations c
    where c.id=v_draft.conversation_id;
  if not public.current_staff_authorized('manage_guest_inbox',v_property_id) then
    raise exception using errcode='42501',message='guest reply review denied'; end if;
  if p_outcome not in ('approved','rejected') or char_length(btrim(p_reason)) not between 3 and 2000
    or char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode='22023',message='invalid draft review'; end if;
  if v_draft.status<>'proposed' then
    if exists(select 1 from public.guest_conversation_audit where idempotency_key=p_idempotency_key) then
      return jsonb_build_object('ok',true,'already_processed',true); end if;
    raise exception using errcode='23514',message='draft already reviewed';
  end if;
  update public.guest_reply_drafts set status=p_outcome,reviewer_user_id=auth.uid(),
    review_reason=btrim(p_reason),reviewed_at=now() where id=p_draft_id;
  insert into public.guest_conversation_audit(conversation_id,actor_user_id,action,reason_code,idempotency_key,details)
    values(v_draft.conversation_id,auth.uid(),'draft_'||p_outcome,'human_review',p_idempotency_key,
      jsonb_build_object('draft_id',p_draft_id,'reason',btrim(p_reason)));
  return jsonb_build_object('ok',true,'already_processed',false,'send_authorized',false);
end;
$$;

revoke all on function public.ingest_guest_message(uuid,uuid,uuid,text,text,text,text,text,text,timestamptz,text,text) from public,anon,authenticated;
grant execute on function public.ingest_guest_message(uuid,uuid,uuid,text,text,text,text,text,text,timestamptz,text,text) to service_role;
revoke all on function public.propose_guest_reply(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.propose_guest_reply(uuid,text,text,text,text) to service_role;
revoke all on function public.manage_guest_conversation(uuid,text,uuid,text,text) from public,anon,service_role;
grant execute on function public.manage_guest_conversation(uuid,text,uuid,text,text) to authenticated;
revoke all on function public.review_guest_reply_draft(uuid,text,text,text) from public,anon,service_role;
grant execute on function public.review_guest_reply_draft(uuid,text,text,text) to authenticated;

comment on table public.guest_reply_drafts is 'Advisory drafts only. Approval records review but does not send.';
