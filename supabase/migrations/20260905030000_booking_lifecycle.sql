-- Wave 1 / Module E local candidate: reliable direct-booking lifecycle.
-- Supabase owns every state transition. Provider delivery remains outbox-only.

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
    when p_action in (
      'manage_staff','approve_payment','read_finance','manage_privacy',
      'manage_booking','approve_refund','publish_rate_policy'
    ) and p_aal is distinct from 'aal2' then false
    when p_role in ('owner','admin') then p_action in (
      'manage_staff','approve_payment','read_finance','read_operations',
      'manage_operations','inspect_cleaning','submit_cleaning','manage_inventory',
      'manage_maintenance','manage_privacy','manage_booking','approve_refund',
      'publish_rate_policy'
    )
    when p_role = 'finance' then p_action in (
      'approve_payment','read_finance','read_operations','approve_refund'
    )
    when p_role = 'inspector' then p_action in (
      'read_operations','inspect_cleaning','submit_cleaning'
    )
    when p_role = 'cleaner' then p_action in ('read_operations','submit_cleaning')
    when p_role = 'maintenance' then p_action in ('read_operations','manage_maintenance')
    else false
  end;
$$;

create table public.booking_rate_policy_versions (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  effective_from date not null,
  effective_to date,
  nightly_rate numeric(10,2) not null check (nightly_rate > 0),
  currency text not null default 'PHP' check (currency ~ '^[A-Z]{3}$'),
  terms jsonb not null default '{}'::jsonb check (jsonb_typeof(terms) = 'object'),
  approved_by uuid not null references auth.users(id) on delete restrict,
  approved_at timestamptz not null default now(),
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  check (effective_to is null or effective_to >= effective_from)
);

create table public.booking_holds (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  -- Logical references until the separately reviewed legacy-key repair.
  booking_id uuid not null,
  rate_policy_version_id uuid references public.booking_rate_policy_versions(id) on delete restrict,
  checkin_date date not null,
  checkout_date date not null,
  expires_at timestamptz not null,
  status text not null default 'active' check (status in ('active','expired','released','converted')),
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (checkout_date > checkin_date)
);

create index booking_holds_property_dates_active_idx
  on public.booking_holds(property_id, checkin_date, checkout_date)
  where status = 'active';
create index booking_holds_expiry_idx
  on public.booking_holds(expires_at) where status = 'active';

create table public.booking_refund_authorizations (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  booking_id uuid not null,
  reviewer_user_id uuid not null references auth.users(id) on delete restrict,
  amount numeric(10,2) not null check (amount > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  reason text not null check (char_length(reason) between 3 and 2000),
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  authorized_at timestamptz not null default now()
);

create table public.booking_lifecycle_events (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  booking_id uuid,
  event_type text not null check (event_type in (
    'hold_created','hold_expired','amended','cancelled','no_show',
    'refund_authorized','calendar_reconciled','rate_policy_published'
  )),
  actor_user_id uuid references auth.users(id) on delete restrict,
  reason text not null check (char_length(reason) between 3 and 2000),
  idempotency_key text not null unique check (char_length(idempotency_key) between 16 and 160),
  before_state jsonb not null default '{}'::jsonb,
  after_state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index booking_lifecycle_booking_created_idx
  on public.booking_lifecycle_events(booking_id, created_at desc);

alter table public.booking_rate_policy_versions enable row level security;
alter table public.booking_holds enable row level security;
alter table public.booking_refund_authorizations enable row level security;
alter table public.booking_lifecycle_events enable row level security;

revoke all on public.booking_rate_policy_versions, public.booking_holds,
  public.booking_refund_authorizations, public.booking_lifecycle_events
  from public, anon, authenticated, service_role;

create policy booking_rate_policy_finance_read on public.booking_rate_policy_versions
  for select to authenticated
  using (public.current_staff_authorized('read_finance', property_id));
create policy booking_refund_finance_read on public.booking_refund_authorizations
  for select to authenticated
  using (public.current_staff_authorized('read_finance', property_id));
create policy booking_lifecycle_admin_read on public.booking_lifecycle_events
  for select to authenticated
  using (public.current_staff_authorized('manage_booking', property_id));
grant select on public.booking_rate_policy_versions, public.booking_refund_authorizations,
  public.booking_lifecycle_events to authenticated;

-- This guard makes holds effective at the canonical booking update itself.
-- The reviewed decision RPC already holds the same property advisory lock, so
-- a concurrent hold or confirmation cannot pass a stale availability check.
create or replace function public.guard_direct_booking_lifecycle_transition()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.source = 'direct' and new.status = 'confirmed'
    and old.status is distinct from 'confirmed' then
    if old.status in ('expired','cancelled','no_show') then
      raise exception using errcode='23514',message='terminal booking cannot be confirmed';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('cascade-booking-property:' || new.property_id::text,0));
    if exists (
      select 1 from public.booking_holds h
      where h.property_id=new.property_id and h.status='active' and h.expires_at > now()
        and h.booking_id<>new.id and h.checkin_date<new.checkout_date and h.checkout_date>new.checkin_date
    ) then
      raise exception using errcode='23P01',message='active hold conflicts with confirmation';
    end if;
    update public.booking_holds set status='converted',updated_at=now()
      where booking_id=new.id and status='active';
  elsif new.source='direct' and new.status='cancelled'
    and old.status is distinct from 'cancelled' then
    update public.booking_holds set status='released',updated_at=now()
      where booking_id=new.id and status='active';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_direct_booking_lifecycle_transition on public.booking_inquiries;
create trigger guard_direct_booking_lifecycle_transition
before update of status on public.booking_inquiries
for each row execute function public.guard_direct_booking_lifecycle_transition();

create or replace function public.publish_booking_rate_policy(
  p_property_id uuid,
  p_effective_from date,
  p_effective_to date,
  p_nightly_rate numeric,
  p_currency text,
  p_terms jsonb,
  p_reason text,
  p_idempotency_key text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null or not public.current_staff_authorized('publish_rate_policy', p_property_id) then
    raise exception using errcode = '42501', message = 'rate policy publication denied';
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160
    or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000
    or p_effective_from is null or (p_effective_to is not null and p_effective_to < p_effective_from)
    or p_nightly_rate is null or p_nightly_rate <= 0
    or upper(p_currency) !~ '^[A-Z]{3}$'
    or jsonb_typeof(coalesce(p_terms, '{}'::jsonb)) <> 'object' then
    raise exception using errcode = '22023', message = 'invalid rate policy';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('cascade-rate-policy:' || p_property_id::text, 0));
  select id into v_id from public.booking_rate_policy_versions where idempotency_key = p_idempotency_key;
  if found then return v_id; end if;
  if exists (
    select 1 from public.booking_rate_policy_versions v
    where v.property_id = p_property_id
      and daterange(v.effective_from, coalesce(v.effective_to + 1, 'infinity'::date), '[)')
          && daterange(p_effective_from, coalesce(p_effective_to + 1, 'infinity'::date), '[)')
  ) then
    raise exception using errcode = '23P01', message = 'rate policy dates overlap';
  end if;
  insert into public.booking_rate_policy_versions(
    property_id,effective_from,effective_to,nightly_rate,currency,terms,approved_by,idempotency_key
  ) values (
    p_property_id,p_effective_from,p_effective_to,p_nightly_rate,upper(p_currency),
    coalesce(p_terms,'{}'::jsonb),auth.uid(),p_idempotency_key
  ) returning id into v_id;
  insert into public.booking_lifecycle_events(
    property_id,booking_id,event_type,actor_user_id,reason,idempotency_key,after_state
  ) values (
    p_property_id,null,'rate_policy_published',auth.uid(),
    btrim(p_reason),'audit:' || p_idempotency_key,jsonb_build_object('rate_policy_version_id',v_id)
  );
  return v_id;
end;
$$;

create or replace function public.create_booking_hold(
  p_booking_id uuid,
  p_expires_at timestamptz,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.booking_inquiries%rowtype;
  v_existing public.booking_holds%rowtype;
  v_hold_id uuid;
  v_policy_id uuid;
begin
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160
    or p_expires_at is null or p_expires_at < now() + interval '5 minutes'
    or p_expires_at > now() + interval '48 hours' then
    raise exception using errcode = '22023', message = 'invalid booking hold';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-hold:' || p_idempotency_key, 0));
  select * into v_existing from public.booking_holds where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object('ok',true,'hold_id',v_existing.id,'already_processed',true);
  end if;
  select * into v_booking from public.booking_inquiries
    where id = p_booking_id and source = 'direct' for update;
  if not found then raise exception using errcode = '22023', message = 'direct booking not found'; end if;
  if v_booking.status <> 'pending' then
    raise exception using errcode = '23514', message = 'booking is not holdable';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-property:' || v_booking.property_id::text, 0));
  if exists (
    select 1 from public.calendar_events c
    where c.property_id = v_booking.property_id and c.status in ('confirmed','blocked')
      and c.checkin_date < v_booking.checkout_date and c.checkout_date > v_booking.checkin_date
      and c.uid not in ('direct:' || v_booking.id::text,'cascade-direct-' || v_booking.id::text)
  ) or exists (
    select 1 from public.booking_holds h
    where h.property_id = v_booking.property_id and h.status = 'active' and h.expires_at > now()
      and h.checkin_date < v_booking.checkout_date and h.checkout_date > v_booking.checkin_date
      and h.booking_id <> v_booking.id
  ) then
    raise exception using errcode = '23P01', message = 'booking dates unavailable';
  end if;
  select id into v_policy_id from public.booking_rate_policy_versions
    where property_id = v_booking.property_id
      and effective_from <= v_booking.checkin_date
      and (effective_to is null or effective_to >= v_booking.checkin_date)
    order by effective_from desc limit 1;
  insert into public.booking_holds(
    property_id,booking_id,rate_policy_version_id,checkin_date,checkout_date,expires_at,idempotency_key
  ) values (
    v_booking.property_id,v_booking.id,v_policy_id,v_booking.checkin_date,v_booking.checkout_date,
    p_expires_at,p_idempotency_key
  ) returning id into v_hold_id;
  insert into public.booking_lifecycle_events(
    property_id,booking_id,event_type,reason,idempotency_key,after_state
  ) values (
    v_booking.property_id,v_booking.id,'hold_created','Automated availability hold',
    'audit:' || p_idempotency_key,
    jsonb_build_object('hold_id',v_hold_id,'expires_at',p_expires_at,'rate_policy_version_id',v_policy_id)
  );
  return jsonb_build_object('ok',true,'hold_id',v_hold_id,'already_processed',false);
end;
$$;

create or replace function public.expire_booking_holds(
  p_cutoff timestamptz default now(),
  p_limit integer default 100
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_hold public.booking_holds%rowtype;
begin
  if p_limit not between 1 and 500 then
    raise exception using errcode = '22023', message = 'invalid expiry batch limit';
  end if;
  for v_hold in
    select * from public.booking_holds
    where status = 'active' and expires_at <= p_cutoff
    order by expires_at,id for update skip locked limit p_limit
  loop
    update public.booking_holds set status='expired',updated_at=now() where id=v_hold.id;
    update public.booking_inquiries set status='expired'
      where id=v_hold.booking_id and status='pending';
    insert into public.booking_lifecycle_events(
      property_id,booking_id,event_type,reason,idempotency_key,before_state,after_state
    ) values (
      v_hold.property_id,v_hold.booking_id,'hold_expired','Automated hold expiry',
      'expire:' || v_hold.id::text,to_jsonb(v_hold),jsonb_build_object('status','expired')
    ) on conflict(idempotency_key) do nothing;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.record_booking_lifecycle_action(
  p_booking_id uuid,
  p_action text,
  p_idempotency_key text,
  p_reason text,
  p_checkin_date date default null,
  p_checkout_date date default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.booking_inquiries%rowtype;
  v_existing public.booking_lifecycle_events%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_event_type text;
  v_calendar_id uuid;
  v_sync_hash text;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='authentication required'; end if;
  if p_action not in ('amend','cancel','no_show','reconcile_calendar')
    or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160
    or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000 then
    raise exception using errcode='22023',message='invalid lifecycle action';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-lifecycle:' || p_idempotency_key,0));
  select * into v_existing from public.booking_lifecycle_events where idempotency_key=p_idempotency_key;
  if found then return jsonb_build_object('ok',true,'event_id',v_existing.id,'already_processed',true); end if;
  select * into v_booking from public.booking_inquiries
    where id=p_booking_id and source='direct' for update;
  if not found then raise exception using errcode='22023',message='direct booking not found'; end if;
  if not public.current_staff_authorized('manage_booking',v_booking.property_id) then
    raise exception using errcode='42501',message='booking lifecycle denied';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-booking-property:' || v_booking.property_id::text,0));
  v_before := to_jsonb(v_booking);

  if p_action='amend' then
    if v_booking.status not in ('pending','confirmed') or p_checkin_date is null
      or p_checkout_date is null or p_checkout_date <= p_checkin_date then
      raise exception using errcode='23514',message='invalid booking amendment';
    end if;
    if exists (
      select 1 from public.calendar_events c where c.property_id=v_booking.property_id
        and c.status in ('confirmed','blocked') and c.checkin_date < p_checkout_date
        and c.checkout_date > p_checkin_date
        and c.uid not in ('direct:' || v_booking.id::text,'cascade-direct-' || v_booking.id::text)
    ) or exists (
      select 1 from public.booking_holds h where h.property_id=v_booking.property_id
        and h.status='active' and h.expires_at>now() and h.booking_id<>v_booking.id
        and h.checkin_date<p_checkout_date and h.checkout_date>p_checkin_date
    ) then raise exception using errcode='23P01',message='amended dates unavailable'; end if;
    update public.booking_inquiries set checkin_date=p_checkin_date,checkout_date=p_checkout_date where id=v_booking.id;
    update public.booking_holds set checkin_date=p_checkin_date,checkout_date=p_checkout_date,updated_at=now()
      where booking_id=v_booking.id and status='active';
    update public.airbnb_reservations set checkin_date=p_checkin_date,checkout_date=p_checkout_date
      where confirmation_code='DIRECT:' || v_booking.id::text;
    update public.calendar_events set checkin_date=p_checkin_date,checkout_date=p_checkout_date,
      recon_status='matched',updated_at=now()
      where property_id=v_booking.property_id
        and uid in ('direct:' || v_booking.id::text,'cascade-direct-' || v_booking.id::text)
      returning id into v_calendar_id;
    v_event_type := 'amended';
  elsif p_action='cancel' then
    if v_booking.status in ('cancelled','expired') then
      raise exception using errcode='23514',message='booking cannot be cancelled';
    end if;
    update public.booking_inquiries set status='cancelled' where id=v_booking.id;
    update public.booking_holds set status='released',updated_at=now()
      where booking_id=v_booking.id and status='active';
    update public.airbnb_reservations set status='cancelled',cancelled_at=now()
      where confirmation_code='DIRECT:' || v_booking.id::text;
    update public.calendar_events set status='cancelled',recon_status='matched',updated_at=now()
      where property_id=v_booking.property_id
        and uid in ('direct:' || v_booking.id::text,'cascade-direct-' || v_booking.id::text)
      returning id into v_calendar_id;
    v_event_type := 'cancelled';
  elsif p_action='no_show' then
    if v_booking.status <> 'confirmed' then
      raise exception using errcode='23514',message='only confirmed bookings can be no-show';
    end if;
    update public.booking_inquiries set status='no_show' where id=v_booking.id;
    v_event_type := 'no_show';
  else
    if v_booking.status <> 'confirmed' then
      raise exception using errcode='23514',message='only confirmed bookings can be reconciled';
    end if;
    if exists (
      select 1 from public.calendar_events c where c.property_id=v_booking.property_id
        and c.status in ('confirmed','blocked') and c.checkin_date < v_booking.checkout_date
        and c.checkout_date > v_booking.checkin_date
        and c.uid not in ('direct:' || v_booking.id::text,'cascade-direct-' || v_booking.id::text)
    ) then raise exception using errcode='23P01',message='calendar reconciliation conflict'; end if;
    select id into v_calendar_id from public.calendar_events
      where property_id=v_booking.property_id
        and uid in ('direct:' || v_booking.id::text,'cascade-direct-' || v_booking.id::text)
      order by case when uid='cascade-direct-' || v_booking.id::text then 0 else 1 end limit 1 for update;
    if v_calendar_id is null then
      insert into public.calendar_events(property_id,uid,source,checkin_date,checkout_date,guest_name,guest_phone,status,recon_status)
      values(v_booking.property_id,'cascade-direct-' || v_booking.id::text,'direct',v_booking.checkin_date,v_booking.checkout_date,
        v_booking.guest_name,v_booking.guest_phone,'confirmed','matched') returning id into v_calendar_id;
    else
      update public.calendar_events set uid='cascade-direct-' || v_booking.id::text,
        checkin_date=v_booking.checkin_date,checkout_date=v_booking.checkout_date,status='confirmed',
        recon_status='matched',updated_at=now() where id=v_calendar_id;
    end if;
    v_event_type := 'calendar_reconciled';
  end if;

  select to_jsonb(b) into v_after from public.booking_inquiries b where b.id=v_booking.id;
  insert into public.booking_lifecycle_events(
    property_id,booking_id,event_type,actor_user_id,reason,idempotency_key,before_state,after_state
  ) values(v_booking.property_id,v_booking.id,v_event_type,auth.uid(),btrim(p_reason),p_idempotency_key,v_before,v_after)
  returning id into v_calendar_id;

  if p_action in ('amend','reconcile_calendar') then
    v_sync_hash := encode(extensions.digest(concat_ws('|',v_booking.id::text,p_action,coalesce(p_checkin_date,v_booking.checkin_date)::text,coalesce(p_checkout_date,v_booking.checkout_date)::text),'sha256'),'hex');
    insert into public.automation_outbox(event_type,aggregate_type,aggregate_id,idempotency_key,payload,route_class,template_key)
    values('calendar.projection_requested','booking_inquiry',v_booking.id,
      'calendar.projection_requested:' || v_booking.id::text || ':' || v_sync_hash,
      jsonb_build_object('schema_version',1,'booking_type','direct','booking_id',v_booking.id,'operation','upsert','sync_hash',v_sync_hash),
      'internal','internal.calendar_projection') on conflict(idempotency_key) do nothing;
  end if;
  return jsonb_build_object('ok',true,'event_id',v_calendar_id,'already_processed',false);
end;
$$;

create or replace function public.authorize_booking_refund(
  p_booking_id uuid,
  p_amount numeric,
  p_currency text,
  p_reason text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.booking_inquiries%rowtype;
  v_refund public.booking_refund_authorizations%rowtype;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='authentication required'; end if;
  select * into v_booking from public.booking_inquiries where id=p_booking_id and source='direct' for update;
  if not found then raise exception using errcode='22023',message='direct booking not found'; end if;
  if not public.current_staff_authorized('approve_refund',v_booking.property_id) then
    raise exception using errcode='42501',message='refund authorization denied';
  end if;
  if v_booking.status not in ('cancelled','no_show') then
    raise exception using errcode='23514',message='booking is not refundable';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > coalesce(v_booking.total_amount,0)
    or upper(p_currency) !~ '^[A-Z]{3}$'
    or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000
    or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then
    raise exception using errcode='22023',message='invalid refund authorization';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-refund:' || p_idempotency_key,0));
  select * into v_refund from public.booking_refund_authorizations where idempotency_key=p_idempotency_key;
  if found then
    if v_refund.booking_id<>p_booking_id or v_refund.reviewer_user_id<>auth.uid()
      or v_refund.amount<>p_amount or v_refund.currency<>upper(p_currency) then
      raise exception using errcode='23505',message='refund key already used';
    end if;
    return jsonb_build_object('ok',true,'authorization_id',v_refund.id,'already_processed',true);
  end if;
  insert into public.booking_refund_authorizations(
    property_id,booking_id,reviewer_user_id,amount,currency,reason,idempotency_key
  ) values(v_booking.property_id,v_booking.id,auth.uid(),p_amount,upper(p_currency),btrim(p_reason),p_idempotency_key)
  returning * into v_refund;
  insert into public.booking_lifecycle_events(
    property_id,booking_id,event_type,actor_user_id,reason,idempotency_key,after_state
  ) values(v_booking.property_id,v_booking.id,'refund_authorized',auth.uid(),btrim(p_reason),
    'audit:' || p_idempotency_key,jsonb_build_object('authorization_id',v_refund.id,'amount',p_amount,'currency',upper(p_currency)));
  return jsonb_build_object('ok',true,'authorization_id',v_refund.id,'already_processed',false);
end;
$$;

revoke all on function public.publish_booking_rate_policy(uuid,date,date,numeric,text,jsonb,text,text) from public,anon,service_role;
grant execute on function public.publish_booking_rate_policy(uuid,date,date,numeric,text,jsonb,text,text) to authenticated;
revoke all on function public.create_booking_hold(uuid,timestamptz,text) from public,anon,authenticated;
grant execute on function public.create_booking_hold(uuid,timestamptz,text) to service_role;
revoke all on function public.expire_booking_holds(timestamptz,integer) from public,anon,authenticated;
grant execute on function public.expire_booking_holds(timestamptz,integer) to service_role;
revoke all on function public.record_booking_lifecycle_action(uuid,text,text,text,date,date) from public,anon,service_role;
grant execute on function public.record_booking_lifecycle_action(uuid,text,text,text,date,date) to authenticated;
revoke all on function public.authorize_booking_refund(uuid,numeric,text,text,text) from public,anon,service_role;
grant execute on function public.authorize_booking_refund(uuid,numeric,text,text,text) to authenticated;

comment on table public.booking_refund_authorizations is
  'Named-human Finance/Admin approval only. An authorization never executes or marks a refund paid.';
comment on function public.record_booking_lifecycle_action(uuid,text,text,text,date,date) is
  'AAL2 Admin lifecycle command. It cannot confirm a booking or change payment facts.';
