-- Wave 3 local candidate: private cleaning/meter evidence and named review.

create table public.cleaning_verification_evidence (
 id uuid primary key default extensions.uuid_generate_v4(),
 property_id uuid not null references public.properties(id) on delete restrict,
 cleaning_session_id uuid not null references public.cleaning_sessions(id) on delete restrict,
 meter_reading_id uuid references public.meter_readings(id) on delete restrict,
 evidence_kind text not null check(evidence_kind in ('preclean_photo','afterclean_photo','meter_photo','checklist')),
 object_path_hash text not null check(object_path_hash ~ '^[a-f0-9]{64}$'),
 content_sha256 text not null check(content_sha256 ~ '^[a-f0-9]{64}$'),
 advisory_result text not null check(advisory_result in ('clear','correction_suggested','uncertain','unavailable')),
 advisory_reason_codes text[] not null default '{}',
 submitted_by_user_id uuid not null references auth.users(id) on delete restrict,
 idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
 created_at timestamptz not null default now(),
 check((evidence_kind='meter_photo')=(meter_reading_id is not null))
);

create table public.cleaning_verification_reviews (
 id uuid primary key default extensions.uuid_generate_v4(),
 evidence_id uuid not null references public.cleaning_verification_evidence(id) on delete restrict,
 property_id uuid not null references public.properties(id) on delete restrict,
 reviewer_user_id uuid not null references auth.users(id) on delete restrict,
 outcome text not null check(outcome in ('accepted','correction_required','inspection_required','overridden')),
 reason text not null check(char_length(reason) between 3 and 2000),
 idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
 reviewed_at timestamptz not null default now()
);
create unique index cleaning_verification_final_review_idx on public.cleaning_verification_reviews(evidence_id)
 where outcome in ('accepted','correction_required','overridden');

alter table public.cleaning_verification_evidence enable row level security;
alter table public.cleaning_verification_reviews enable row level security;
revoke all on public.cleaning_verification_evidence,public.cleaning_verification_reviews from public,anon,authenticated,service_role;
grant select on public.cleaning_verification_evidence,public.cleaning_verification_reviews to authenticated;
create policy cleaning_evidence_ops_read on public.cleaning_verification_evidence for select to authenticated
 using(public.current_staff_authorized('read_operations',property_id));
create policy cleaning_review_ops_read on public.cleaning_verification_reviews for select to authenticated
 using(public.current_staff_authorized('read_operations',property_id));

create or replace function public.record_cleaning_verification_evidence(
 p_cleaning_session_id uuid,p_meter_reading_id uuid,p_evidence_kind text,p_object_path_hash text,
 p_content_sha256 text,p_advisory_result text,p_advisory_reason_codes text[],p_idempotency_key text
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_session public.cleaning_sessions%rowtype; v_id uuid;
begin
 if auth.uid() is null then raise exception using errcode='42501',message='authentication required'; end if;
 select * into v_session from public.cleaning_sessions where id=p_cleaning_session_id for share;
 if not found then raise exception using errcode='22023',message='cleaning session not found'; end if;
 if not public.current_staff_authorized('submit_cleaning',v_session.property_id)
   or v_session.submitted_by_user_id is distinct from auth.uid() then
   raise exception using errcode='42501',message='cleaning evidence submission denied'; end if;
 if p_evidence_kind not in ('preclean_photo','afterclean_photo','meter_photo','checklist')
   or p_object_path_hash !~ '^[a-f0-9]{64}$' or p_content_sha256 !~ '^[a-f0-9]{64}$'
   or p_advisory_result not in ('clear','correction_suggested','uncertain','unavailable')
   or char_length(p_idempotency_key) not between 16 and 160 then
   raise exception using errcode='22023',message='invalid cleaning evidence'; end if;
 if (p_evidence_kind='meter_photo') is distinct from (p_meter_reading_id is not null) then
   raise exception using errcode='22023',message='meter evidence mismatch'; end if;
 if p_meter_reading_id is not null and not exists(select 1 from public.meter_readings m
   where m.id=p_meter_reading_id and m.session_id=v_session.id and m.property_id=v_session.property_id) then
   raise exception using errcode='22023',message='meter reading scope mismatch'; end if;
 select id into v_id from public.cleaning_verification_evidence where idempotency_key=p_idempotency_key;
 if found then return v_id; end if;
 insert into public.cleaning_verification_evidence(property_id,cleaning_session_id,meter_reading_id,evidence_kind,
   object_path_hash,content_sha256,advisory_result,advisory_reason_codes,submitted_by_user_id,idempotency_key)
 values(v_session.property_id,v_session.id,p_meter_reading_id,p_evidence_kind,p_object_path_hash,p_content_sha256,
   p_advisory_result,coalesce(p_advisory_reason_codes,'{}'),auth.uid(),p_idempotency_key) returning id into v_id;
 return v_id;
end;
$$;

create or replace function public.review_cleaning_verification(
 p_evidence_id uuid,p_outcome text,p_reason text,p_idempotency_key text
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_evidence public.cleaning_verification_evidence%rowtype; v_id uuid;
begin
 if auth.uid() is null then raise exception using errcode='42501',message='authentication required'; end if;
 select * into v_evidence from public.cleaning_verification_evidence where id=p_evidence_id for update;
 if not found then raise exception using errcode='22023',message='evidence not found'; end if;
 if not public.current_staff_authorized('inspect_cleaning',v_evidence.property_id) then
   raise exception using errcode='42501',message='cleaning review denied'; end if;
 if p_outcome not in ('accepted','correction_required','inspection_required','overridden')
   or char_length(btrim(p_reason)) not between 3 and 2000 or char_length(p_idempotency_key) not between 16 and 160 then
   raise exception using errcode='22023',message='invalid cleaning review'; end if;
 if p_outcome='overridden' and not public.current_staff_authorized('manage_operations',v_evidence.property_id) then
   raise exception using errcode='42501',message='cleaning override denied'; end if;
 select id into v_id from public.cleaning_verification_reviews where idempotency_key=p_idempotency_key;
 if found then return v_id; end if;
 insert into public.cleaning_verification_reviews(evidence_id,property_id,reviewer_user_id,outcome,reason,idempotency_key)
 values(v_evidence.id,v_evidence.property_id,auth.uid(),p_outcome,btrim(p_reason),p_idempotency_key) returning id into v_id;
 return v_id;
end;
$$;

revoke all on function public.record_cleaning_verification_evidence(uuid,uuid,text,text,text,text,text[],text) from public,anon,service_role;
grant execute on function public.record_cleaning_verification_evidence(uuid,uuid,text,text,text,text,text[],text) to authenticated;
revoke all on function public.review_cleaning_verification(uuid,text,text,text) from public,anon,service_role;
grant execute on function public.review_cleaning_verification(uuid,text,text,text) to authenticated;

comment on table public.cleaning_verification_evidence is 'Private operational evidence. Advisory results never approve cleaning or meter readings.';
