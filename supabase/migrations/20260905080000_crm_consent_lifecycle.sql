-- Wave 6 local candidate: private hashed CRM identity, consent, lifecycle, and retention controls.
create function public.crm_human_authorized(p_property_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.staff_access_profiles p where p.user_id=auth.uid()
   and p.role in ('owner','admin') and p.disabled_at is null and auth.jwt()->>'aal'='aal2'
   and (p.sessions_revoked_after is null or to_timestamp(coalesce((auth.jwt()->>'iat')::bigint,0))>p.sessions_revoked_after)
   and (p.role='owner' or exists(select 1 from public.staff_property_access s where s.user_id=p.user_id and s.property_id=p_property_id)));
$$;
revoke all on function public.crm_human_authorized(uuid) from public,anon,service_role;
grant execute on function public.crm_human_authorized(uuid) to authenticated;

create table public.crm_guest_profiles(
 id uuid primary key default extensions.uuid_generate_v4(),property_id uuid not null references public.properties(id) on delete restrict,
 guest_id uuid not null references public.guests(id) on delete restrict,email_hash text check(email_hash~'^[a-f0-9]{64}$'),
 phone_hash text check(phone_hash~'^[a-f0-9]{64}$'),created_by_user_id uuid not null references auth.users(id) on delete restrict,
 idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),created_at timestamptz not null default now(),
 unique(property_id,guest_id),check(email_hash is not null or phone_hash is not null)
);
create unique index crm_guest_email_hash_idx on public.crm_guest_profiles(property_id,email_hash) where email_hash is not null;
create unique index crm_guest_phone_hash_idx on public.crm_guest_profiles(property_id,phone_hash) where phone_hash is not null;

create table public.crm_consent_events(
 id uuid primary key default extensions.uuid_generate_v4(),profile_id uuid not null references public.crm_guest_profiles(id) on delete restrict,
 property_id uuid not null references public.properties(id) on delete restrict,purpose text not null check(purpose in ('operational','service_recovery','marketing')),
 status text not null check(status in ('granted','withdrawn')),evidence_hash text not null check(evidence_hash~'^[a-f0-9]{64}$'),
 effective_at timestamptz not null,recorded_by_user_id uuid not null references auth.users(id) on delete restrict,
 reason text not null check(char_length(btrim(reason)) between 3 and 2000),idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
 created_at timestamptz not null default now()
);
create table public.crm_lifecycle_events(
 id uuid primary key default extensions.uuid_generate_v4(),profile_id uuid not null references public.crm_guest_profiles(id) on delete restrict,
 property_id uuid not null references public.properties(id) on delete restrict,event_type text not null check(event_type in (
  'preference_recorded','stay_booked','stay_completed','stay_cancelled','recovery_opened','recovery_resolved')),
 event_code text not null check(event_code~'^[a-z][a-z0-9_]{1,63}$'),value_hash text check(value_hash~'^[a-f0-9]{64}$'),booking_id uuid,
 suppress_marketing boolean not null default false,occurred_at timestamptz not null,recorded_by_user_id uuid not null references auth.users(id) on delete restrict,
 reason text not null check(char_length(btrim(reason)) between 3 and 2000),idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
 created_at timestamptz not null default now(),check((event_type='recovery_opened') is not true or suppress_marketing)
);
create table public.crm_retention_decisions(
 id uuid primary key default extensions.uuid_generate_v4(),profile_id uuid not null references public.crm_guest_profiles(id) on delete restrict,
 property_id uuid not null references public.properties(id) on delete restrict,action text not null check(action in ('retain_until','restrict','delete_due','legal_hold')),
 effective_until date,reason text not null check(char_length(btrim(reason)) between 3 and 2000),decided_by_user_id uuid not null references auth.users(id) on delete restrict,
 idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),decided_at timestamptz not null default now(),
 check((action='retain_until')=(effective_until is not null)),check(action<>'legal_hold' or effective_until is null)
);

create function public.create_crm_profile(p_guest_id uuid,p_email_hash text,p_phone_hash text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare g public.guests%rowtype;p public.crm_guest_profiles%rowtype;v_id uuid;
begin select * into g from public.guests where id=p_guest_id;
 if not found or not public.crm_human_authorized(g.property_id) then raise exception using errcode='42501',message='CRM profile denied';end if;
 select * into p from public.crm_guest_profiles where idempotency_key=p_idempotency_key;if found then
  if p.guest_id is distinct from p_guest_id or p.email_hash is distinct from p_email_hash or p.phone_hash is distinct from p_phone_hash or p.created_by_user_id is distinct from auth.uid() then raise exception using errcode='22023',message='idempotency conflict';end if;return p.id;end if;
 if (p_email_hash is null and p_phone_hash is null) or (p_email_hash is not null and p_email_hash!~'^[a-f0-9]{64}$') or (p_phone_hash is not null and p_phone_hash!~'^[a-f0-9]{64}$') then raise exception using errcode='22023',message='invalid identity hash';end if;
 if exists(select 1 from public.crm_guest_profiles x where x.property_id=g.property_id and ((p_email_hash is not null and x.email_hash=p_email_hash) or (p_phone_hash is not null and x.phone_hash=p_phone_hash)) and x.guest_id<>g.id) then raise exception using errcode='23505',message='identity hash conflict';end if;
 insert into public.crm_guest_profiles(property_id,guest_id,email_hash,phone_hash,created_by_user_id,idempotency_key) values(g.property_id,g.id,p_email_hash,p_phone_hash,auth.uid(),p_idempotency_key) returning id into v_id;return v_id;
end;$$;
create function public.resolve_crm_identity(p_property_id uuid,p_identity_type text,p_identity_hash text)
returns uuid language plpgsql stable security definer set search_path='' as $$
declare v_guest uuid;begin if not public.crm_human_authorized(p_property_id) then raise exception using errcode='42501',message='CRM resolution denied';end if;
 if p_identity_type not in ('email','phone') or p_identity_hash!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='invalid identity lookup';end if;
 select guest_id into v_guest from public.crm_guest_profiles where property_id=p_property_id and case when p_identity_type='email' then email_hash=p_identity_hash else phone_hash=p_identity_hash end;return v_guest;end;$$;
create function public.record_crm_consent(p_profile_id uuid,p_purpose text,p_status text,p_evidence_hash text,p_effective_at timestamptz,p_reason text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare p public.crm_guest_profiles%rowtype;e public.crm_consent_events%rowtype;v_id uuid;begin select * into p from public.crm_guest_profiles where id=p_profile_id;
 if not found or not public.crm_human_authorized(p.property_id) then raise exception using errcode='42501',message='consent record denied';end if;
 select * into e from public.crm_consent_events where idempotency_key=p_idempotency_key;if found then
  if e.profile_id is distinct from p_profile_id or e.purpose is distinct from p_purpose or e.status is distinct from p_status or e.evidence_hash is distinct from p_evidence_hash or e.effective_at is distinct from p_effective_at or e.reason is distinct from btrim(p_reason) or e.recorded_by_user_id is distinct from auth.uid() then raise exception using errcode='22023',message='consent idempotency conflict';end if;return e.id;end if;
 if p_purpose not in ('operational','service_recovery','marketing') or p_status not in ('granted','withdrawn') or p_evidence_hash!~'^[a-f0-9]{64}$' or p_effective_at is null or char_length(btrim(p_reason))<3 then raise exception using errcode='22023',message='invalid consent record';end if;
 insert into public.crm_consent_events(profile_id,property_id,purpose,status,evidence_hash,effective_at,recorded_by_user_id,reason,idempotency_key) values(p.id,p.property_id,p_purpose,p_status,p_evidence_hash,p_effective_at,auth.uid(),btrim(p_reason),p_idempotency_key) returning id into v_id;return v_id;end;$$;
create function public.record_crm_lifecycle(p_profile_id uuid,p_event_type text,p_event_code text,p_value_hash text,p_booking_id uuid,p_suppress_marketing boolean,p_occurred_at timestamptz,p_reason text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare p public.crm_guest_profiles%rowtype;e public.crm_lifecycle_events%rowtype;v_id uuid;begin select * into p from public.crm_guest_profiles where id=p_profile_id;
 if not found or not public.crm_human_authorized(p.property_id) then raise exception using errcode='42501',message='lifecycle record denied';end if;
 select * into e from public.crm_lifecycle_events where idempotency_key=p_idempotency_key;if found then
  if e.profile_id is distinct from p_profile_id or e.event_type is distinct from p_event_type or e.event_code is distinct from p_event_code or e.value_hash is distinct from p_value_hash or e.booking_id is distinct from p_booking_id or e.suppress_marketing is distinct from coalesce(p_suppress_marketing,false) or e.occurred_at is distinct from p_occurred_at or e.reason is distinct from btrim(p_reason) or e.recorded_by_user_id is distinct from auth.uid() then raise exception using errcode='22023',message='lifecycle idempotency conflict';end if;return e.id;end if;
 if p_event_type not in ('preference_recorded','stay_booked','stay_completed','stay_cancelled','recovery_opened','recovery_resolved') or p_event_code!~'^[a-z][a-z0-9_]{1,63}$' or p_occurred_at is null or (p_value_hash is not null and p_value_hash!~'^[a-f0-9]{64}$') or (p_event_type='recovery_opened' and not coalesce(p_suppress_marketing,false)) or char_length(btrim(p_reason))<3 then raise exception using errcode='22023',message='invalid lifecycle record';end if;
 insert into public.crm_lifecycle_events(profile_id,property_id,event_type,event_code,value_hash,booking_id,suppress_marketing,occurred_at,recorded_by_user_id,reason,idempotency_key) values(p.id,p.property_id,p_event_type,p_event_code,p_value_hash,p_booking_id,coalesce(p_suppress_marketing,false),p_occurred_at,auth.uid(),btrim(p_reason),p_idempotency_key) returning id into v_id;return v_id;end;$$;
create function public.record_crm_retention(p_profile_id uuid,p_action text,p_effective_until date,p_reason text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare p public.crm_guest_profiles%rowtype;d public.crm_retention_decisions%rowtype;v_id uuid;begin select * into p from public.crm_guest_profiles where id=p_profile_id;
 if not found or not public.crm_human_authorized(p.property_id) then raise exception using errcode='42501',message='retention decision denied';end if;
 select * into d from public.crm_retention_decisions where idempotency_key=p_idempotency_key;if found then
  if d.profile_id is distinct from p_profile_id or d.action is distinct from p_action or d.effective_until is distinct from p_effective_until or d.reason is distinct from btrim(p_reason) or d.decided_by_user_id is distinct from auth.uid() then raise exception using errcode='22023',message='retention idempotency conflict';end if;return d.id;end if;
 if p_action not in ('retain_until','restrict','delete_due','legal_hold') or (p_action='retain_until') is distinct from (p_effective_until is not null) or (p_action='legal_hold' and p_effective_until is not null) or char_length(btrim(p_reason))<3 then raise exception using errcode='22023',message='invalid retention decision';end if;
 insert into public.crm_retention_decisions(profile_id,property_id,action,effective_until,reason,decided_by_user_id,idempotency_key) values(p.id,p.property_id,p_action,p_effective_until,btrim(p_reason),auth.uid(),p_idempotency_key) returning id into v_id;return v_id;end;$$;
create function public.crm_marketing_eligible(p_profile_id uuid)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare p public.crm_guest_profiles%rowtype;v_consent text;v_recovery text;v_retention text;begin select * into p from public.crm_guest_profiles where id=p_profile_id;
 if not found or not public.crm_human_authorized(p.property_id) then raise exception using errcode='42501',message='CRM eligibility denied';end if;
 select status into v_consent from public.crm_consent_events where profile_id=p.id and purpose='marketing' order by effective_at desc,created_at desc limit 1;
 select event_type into v_recovery from public.crm_lifecycle_events where profile_id=p.id and event_type in ('recovery_opened','recovery_resolved') order by occurred_at desc,created_at desc limit 1;
 select action into v_retention from public.crm_retention_decisions where profile_id=p.id order by decided_at desc limit 1;
 return coalesce(v_consent='granted' and v_recovery is distinct from 'recovery_opened' and coalesce(v_retention,'') not in ('restrict','delete_due','legal_hold'),false);end;$$;

alter table public.crm_guest_profiles enable row level security;alter table public.crm_consent_events enable row level security;alter table public.crm_lifecycle_events enable row level security;alter table public.crm_retention_decisions enable row level security;
revoke all on public.crm_guest_profiles,public.crm_consent_events,public.crm_lifecycle_events,public.crm_retention_decisions from public,anon,authenticated,service_role;
grant select on public.crm_guest_profiles,public.crm_consent_events,public.crm_lifecycle_events,public.crm_retention_decisions to authenticated;
create policy crm_profiles_read on public.crm_guest_profiles for select to authenticated using(public.crm_human_authorized(property_id));
create policy crm_consents_read on public.crm_consent_events for select to authenticated using(public.crm_human_authorized(property_id));
create policy crm_lifecycle_read on public.crm_lifecycle_events for select to authenticated using(public.crm_human_authorized(property_id));
create policy crm_retention_read on public.crm_retention_decisions for select to authenticated using(public.crm_human_authorized(property_id));
revoke all on function public.create_crm_profile(uuid,text,text,text),public.resolve_crm_identity(uuid,text,text),public.record_crm_consent(uuid,text,text,text,timestamptz,text,text),public.record_crm_lifecycle(uuid,text,text,text,uuid,boolean,timestamptz,text,text),public.record_crm_retention(uuid,text,date,text,text),public.crm_marketing_eligible(uuid) from public,anon,service_role;
grant execute on function public.create_crm_profile(uuid,text,text,text),public.resolve_crm_identity(uuid,text,text),public.record_crm_consent(uuid,text,text,text,timestamptz,text,text),public.record_crm_lifecycle(uuid,text,text,text,uuid,boolean,timestamptz,text,text),public.record_crm_retention(uuid,text,date,text,text),public.crm_marketing_eligible(uuid) to authenticated;
comment on table public.crm_guest_profiles is 'Private CRM linkage using hashes only; raw contact data is not duplicated here.';
comment on function public.crm_marketing_eligible(uuid) is 'Deterministic eligibility only. It does not authorize targeting, drafting, sending, or publication.';
