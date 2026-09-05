-- Wave 5 local candidate: named Finance reconciliation and internal management analytics.
-- No tax/statutory filing output, bank/provider action, or OPS delivery exists here.

create function public.finance_human_authorized(p_property_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select auth.uid() is not null
    and public.current_staff_authorized('read_finance',p_property_id);
$$;
revoke all on function public.finance_human_authorized(uuid) from public,anon,service_role;
grant execute on function public.finance_human_authorized(uuid) to authenticated;

create function public.management_owner_authorized(p_property_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.staff_access_profiles p
    where p.user_id=auth.uid() and p.role='owner' and p.disabled_at is null
      and auth.jwt()->>'aal'='aal2'
      and (p.sessions_revoked_after is null
        or to_timestamp(coalesce((auth.jwt()->>'iat')::bigint,0))>p.sessions_revoked_after)
      and exists(select 1 from public.properties x where x.id=p_property_id)
  );
$$;
revoke all on function public.management_owner_authorized(uuid) from public,anon,service_role;
grant execute on function public.management_owner_authorized(uuid) to authenticated;

create table public.finance_reconciliation_candidates (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  fact_kind text not null check(fact_kind in (
    'gross_booking_income','operating_expense','nonoperating_exclusion',
    'occupied_nights','available_nights','electricity_usage','electricity_cost',
    'water_usage','water_cost'
  )),
  fact_date date not null,
  unit text not null check(unit in ('PHP','night','kWh','m3')),
  category_slug text not null check(category_slug ~ '^[a-z][a-z0-9_]{1,63}$'),
  channel text not null default 'not_applicable'
    check(channel in ('direct','airbnb','other','not_applicable')),
  primary_source_kind text not null check(primary_source_kind in (
    'booking','calendar','payment_review','airbnb_reservation','airbnb_payout',
    'ledger_transaction','approved_expense','inventory_purchase','meter_reading'
  )),
  primary_source_ref text not null
    check(primary_source_ref ~ '^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}$'),
  primary_source_hash text not null check(primary_source_hash ~ '^[a-f0-9]{64}$'),
  primary_value numeric(14,4) not null check(primary_value>0 and primary_value<10000000000),
  counterpart_source_kind text check(counterpart_source_kind in (
    'booking','calendar','payment_review','airbnb_reservation','airbnb_payout',
    'ledger_transaction','approved_expense','inventory_purchase','meter_reading'
  )),
  counterpart_source_ref text
    check(counterpart_source_ref ~ '^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}$'),
  counterpart_source_hash text check(counterpart_source_hash ~ '^[a-f0-9]{64}$'),
  counterpart_value numeric(14,4) check(counterpart_value>0 and counterpart_value<10000000000),
  comparison_outcome text not null
    check(comparison_outcome in ('exact_match','mismatch','missing_fields','duplicate_source')),
  value_delta numeric(14,4),
  reason_codes text[] not null,
  advisory_only boolean not null default true check(advisory_only),
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
  created_at timestamptz not null default now(),
  check(
    (counterpart_source_kind is null and counterpart_source_ref is null
      and counterpart_source_hash is null and counterpart_value is null)
    or
    (counterpart_source_kind is not null and counterpart_source_ref is not null
      and counterpart_source_hash is not null and counterpart_value is not null)
  ),
  check((fact_kind='gross_booking_income')=(channel<>'not_applicable')),
  check(
    (unit='PHP' and fact_kind in ('gross_booking_income','operating_expense','nonoperating_exclusion','electricity_cost','water_cost'))
    or (unit='night' and fact_kind in ('occupied_nights','available_nights'))
    or (unit='kWh' and fact_kind='electricity_usage')
    or (unit='m3' and fact_kind='water_usage')
  )
);

create table public.finance_reconciliation_reviews (
  id uuid primary key default extensions.uuid_generate_v4(),
  candidate_id uuid not null references public.finance_reconciliation_candidates(id) on delete restrict,
  property_id uuid not null references public.properties(id) on delete restrict,
  outcome text not null check(outcome in ('approved','rejected','needs_follow_up')),
  reconciled_value numeric(14,4),
  reason text not null check(char_length(btrim(reason)) between 3 and 2000),
  reviewer_user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
  reviewed_at timestamptz not null default now(),
  check((outcome='approved')=(reconciled_value is not null))
);
create unique index finance_reconciliation_final_review_idx
  on public.finance_reconciliation_reviews(candidate_id)
  where outcome in ('approved','rejected');

create table public.finance_reconciled_facts (
  id uuid primary key default extensions.uuid_generate_v4(),
  candidate_id uuid not null unique references public.finance_reconciliation_candidates(id) on delete restrict,
  review_id uuid not null unique references public.finance_reconciliation_reviews(id) on delete restrict,
  property_id uuid not null references public.properties(id) on delete restrict,
  fact_kind text not null,
  fact_date date not null,
  unit text not null,
  category_slug text not null,
  channel text not null,
  reconciled_value numeric(14,4) not null check(reconciled_value>0),
  reconciled_by_user_id uuid not null references auth.users(id) on delete restrict,
  reconciled_at timestamptz not null default now()
);

create table public.management_target_versions (
  id uuid primary key default extensions.uuid_generate_v4(),
  property_id uuid not null references public.properties(id) on delete restrict,
  target_kind text not null check(target_kind in (
    'gross_booking_income','operating_expense','operating_profit',
    'cost_per_available_night','cost_per_occupied_night','adr','revpar','occupancy_pct',
    'electricity_daily_kwh','electricity_daily_cost','water_daily_m3','water_daily_cost'
  )),
  target_value numeric(14,4) not null check(target_value>=0 and target_value<10000000000),
  unit text not null check(unit in ('PHP','PHP/night','percent','kWh/day','PHP/day','m3/day')),
  effective_from date not null,
  effective_to date,
  reason text not null check(char_length(btrim(reason)) between 3 and 2000),
  approved_by_user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
  approved_at timestamptz not null default now(),
  check(effective_to is null or effective_to>=effective_from),
  check(
    (unit='PHP' and target_kind in ('gross_booking_income','operating_expense','operating_profit'))
    or (unit='PHP/night' and target_kind in ('cost_per_available_night','cost_per_occupied_night','adr','revpar'))
    or (unit='percent' and target_kind='occupancy_pct')
    or (unit='kWh/day' and target_kind='electricity_daily_kwh')
    or (unit='m3/day' and target_kind='water_daily_m3')
    or (unit='PHP/day' and target_kind in ('electricity_daily_cost','water_daily_cost'))
  )
);

create function public.record_finance_reconciliation(
  p_property_id uuid,p_fact_kind text,p_fact_date date,p_unit text,p_category_slug text,p_channel text,
  p_primary_source_kind text,p_primary_source_ref text,p_primary_source_hash text,p_primary_value numeric,
  p_counterpart_source_kind text,p_counterpart_source_ref text,p_counterpart_source_hash text,
  p_counterpart_value numeric,p_idempotency_key text
) returns uuid language plpgsql security definer set search_path='' as $$
declare c public.finance_reconciliation_candidates%rowtype; v_outcome text; v_delta numeric; v_reasons text[]; v_id uuid; v_duplicate boolean;
begin
  if not public.finance_human_authorized(p_property_id) then raise exception using errcode='42501',message='finance reconciliation denied'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-finance-reconciliation-property:'||p_property_id::text,0));
  select * into c from public.finance_reconciliation_candidates where idempotency_key=p_idempotency_key;
  if found then
    if c.property_id is distinct from p_property_id or c.fact_kind is distinct from p_fact_kind or c.fact_date is distinct from p_fact_date
      or c.unit is distinct from p_unit or c.category_slug is distinct from p_category_slug or c.channel is distinct from p_channel
      or c.primary_source_kind is distinct from p_primary_source_kind or c.primary_source_ref is distinct from p_primary_source_ref
      or c.primary_source_hash is distinct from p_primary_source_hash or c.primary_value is distinct from p_primary_value
      or c.counterpart_source_kind is distinct from p_counterpart_source_kind or c.counterpart_source_ref is distinct from p_counterpart_source_ref
      or c.counterpart_source_hash is distinct from p_counterpart_source_hash or c.counterpart_value is distinct from p_counterpart_value
      or c.created_by_user_id is distinct from auth.uid() then raise exception using errcode='22023',message='idempotency conflict'; end if;
    return c.id;
  end if;
  if p_fact_date is null or p_primary_value is null or p_primary_value<=0 or p_primary_value>=10000000000
    or p_primary_value<>round(p_primary_value,case when p_unit='PHP' then 2 else 4 end)
    or p_fact_kind not in ('gross_booking_income','operating_expense','nonoperating_exclusion','occupied_nights','available_nights','electricity_usage','electricity_cost','water_usage','water_cost')
    or p_unit not in ('PHP','night','kWh','m3') or p_category_slug !~ '^[a-z][a-z0-9_]{1,63}$'
    or p_channel not in ('direct','airbnb','other','not_applicable')
    or p_primary_source_kind not in ('booking','calendar','payment_review','airbnb_reservation','airbnb_payout','ledger_transaction','approved_expense','inventory_purchase','meter_reading')
    or p_primary_source_ref !~ '^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}$' or p_primary_source_hash !~ '^[a-f0-9]{64}$'
    or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160
    or (p_fact_kind='gross_booking_income') is distinct from (p_channel<>'not_applicable')
    or not ((p_unit='PHP' and p_fact_kind in ('gross_booking_income','operating_expense','nonoperating_exclusion','electricity_cost','water_cost'))
      or (p_unit='night' and p_fact_kind in ('occupied_nights','available_nights'))
      or (p_unit='kWh' and p_fact_kind='electricity_usage') or (p_unit='m3' and p_fact_kind='water_usage')) then
    raise exception using errcode='22023',message='invalid reconciliation candidate';
  end if;
  if (p_counterpart_source_kind is null) is distinct from (p_counterpart_source_ref is null)
    or (p_counterpart_source_kind is null) is distinct from (p_counterpart_source_hash is null)
    or (p_counterpart_source_kind is null) is distinct from (p_counterpart_value is null) then
    raise exception using errcode='22023',message='incomplete counterpart';
  end if;
  if p_counterpart_source_kind is not null and (
    p_counterpart_source_kind not in ('booking','calendar','payment_review','airbnb_reservation','airbnb_payout','ledger_transaction','approved_expense','inventory_purchase','meter_reading')
    or p_counterpart_source_ref !~ '^[A-Za-z0-9][A-Za-z0-9:_-]{7,159}$' or p_counterpart_source_hash !~ '^[a-f0-9]{64}$'
    or p_counterpart_value<=0 or p_counterpart_value>=10000000000
    or p_counterpart_value<>round(p_counterpart_value,case when p_unit='PHP' then 2 else 4 end)
  ) then raise exception using errcode='22023',message='invalid counterpart'; end if;
  select exists(select 1 from public.finance_reconciliation_candidates x where x.property_id=p_property_id and (
    x.primary_source_hash in (p_primary_source_hash,p_counterpart_source_hash)
    or x.counterpart_source_hash in (p_primary_source_hash,p_counterpart_source_hash)
  )) into v_duplicate;
  if v_duplicate then v_outcome:='duplicate_source';v_delta:=null;v_reasons:=array['source_seen_before'];
  elsif p_counterpart_value is null then v_outcome:='missing_fields';v_delta:=null;v_reasons:=array['counterpart_missing'];
  elsif p_primary_value=p_counterpart_value then v_outcome:='exact_match';v_delta:=0;v_reasons:=array['values_equal'];
  else v_outcome:='mismatch';v_delta:=p_primary_value-p_counterpart_value;v_reasons:=array['values_differ']; end if;
  insert into public.finance_reconciliation_candidates(property_id,fact_kind,fact_date,unit,category_slug,channel,
    primary_source_kind,primary_source_ref,primary_source_hash,primary_value,counterpart_source_kind,
    counterpart_source_ref,counterpart_source_hash,counterpart_value,comparison_outcome,value_delta,reason_codes,
    created_by_user_id,idempotency_key)
  values(p_property_id,p_fact_kind,p_fact_date,p_unit,p_category_slug,p_channel,p_primary_source_kind,
    p_primary_source_ref,p_primary_source_hash,p_primary_value,p_counterpart_source_kind,p_counterpart_source_ref,
    p_counterpart_source_hash,p_counterpart_value,v_outcome,v_delta,v_reasons,auth.uid(),p_idempotency_key)
  returning id into v_id;
  return v_id;
end;
$$;

create function public.review_finance_reconciliation(
  p_candidate_id uuid,p_outcome text,p_reconciled_value numeric,p_reason text,p_idempotency_key text
) returns uuid language plpgsql security definer set search_path='' as $$
declare c public.finance_reconciliation_candidates%rowtype; r public.finance_reconciliation_reviews%rowtype; v_id uuid;
begin
  select * into c from public.finance_reconciliation_candidates where id=p_candidate_id for update;
  if not found or not public.finance_human_authorized(c.property_id) then raise exception using errcode='42501',message='finance review denied'; end if;
  select * into r from public.finance_reconciliation_reviews where idempotency_key=p_idempotency_key;
  if found then
    if r.candidate_id is distinct from c.id or r.outcome is distinct from p_outcome or r.reconciled_value is distinct from p_reconciled_value
      or r.reason is distinct from btrim(p_reason) or r.reviewer_user_id is distinct from auth.uid() then raise exception using errcode='22023',message='review conflict'; end if;
    return r.id;
  end if;
  if p_outcome not in ('approved','rejected','needs_follow_up') or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000
    or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160
    or (p_outcome='approved') is distinct from (p_reconciled_value is not null) then raise exception using errcode='22023',message='invalid finance review'; end if;
  if p_outcome='approved' and (c.comparison_outcome in ('missing_fields','duplicate_source')
    or p_reconciled_value<=0 or p_reconciled_value>=10000000000
    or p_reconciled_value<>round(p_reconciled_value,case when c.unit='PHP' then 2 else 4 end)
    or (c.comparison_outcome='exact_match' and p_reconciled_value<>c.primary_value)
    or (c.comparison_outcome='mismatch' and p_reconciled_value not in (c.primary_value,c.counterpart_value))) then
    raise exception using errcode='22023',message='reconciled value not supported';
  end if;
  insert into public.finance_reconciliation_reviews(candidate_id,property_id,outcome,reconciled_value,reason,reviewer_user_id,idempotency_key)
  values(c.id,c.property_id,p_outcome,p_reconciled_value,btrim(p_reason),auth.uid(),p_idempotency_key) returning id into v_id;
  if p_outcome='approved' then
    insert into public.finance_reconciled_facts(candidate_id,review_id,property_id,fact_kind,fact_date,unit,category_slug,channel,reconciled_value,reconciled_by_user_id)
    values(c.id,v_id,c.property_id,c.fact_kind,c.fact_date,c.unit,c.category_slug,c.channel,p_reconciled_value,auth.uid());
  end if;
  return v_id;
end;
$$;

create function public.publish_management_target(
  p_property_id uuid,p_target_kind text,p_target_value numeric,p_unit text,p_effective_from date,
  p_effective_to date,p_reason text,p_idempotency_key text
) returns uuid language plpgsql security definer set search_path='' as $$
declare t public.management_target_versions%rowtype; v_id uuid;
begin
  if not public.management_owner_authorized(p_property_id) then raise exception using errcode='42501',message='owner target approval required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('cascade-management-target:'||p_property_id::text||':'||coalesce(p_target_kind,''),0));
  select * into t from public.management_target_versions where idempotency_key=p_idempotency_key;
  if found then
    if t.property_id is distinct from p_property_id or t.target_kind is distinct from p_target_kind
      or t.target_value is distinct from p_target_value or t.unit is distinct from p_unit
      or t.effective_from is distinct from p_effective_from or t.effective_to is distinct from p_effective_to
      or t.reason is distinct from btrim(p_reason) or t.approved_by_user_id is distinct from auth.uid() then
      raise exception using errcode='22023',message='target idempotency conflict';
    end if;
    return t.id;
  end if;
  if p_target_kind not in ('gross_booking_income','operating_expense','operating_profit','cost_per_available_night','cost_per_occupied_night','adr','revpar','occupancy_pct','electricity_daily_kwh','electricity_daily_cost','water_daily_m3','water_daily_cost')
    or p_target_value is null or p_target_value<0 or p_target_value>=10000000000 or p_effective_from is null
    or not ((p_unit='PHP' and p_target_kind in ('gross_booking_income','operating_expense','operating_profit'))
      or (p_unit='PHP/night' and p_target_kind in ('cost_per_available_night','cost_per_occupied_night','adr','revpar'))
      or (p_unit='percent' and p_target_kind='occupancy_pct') or (p_unit='kWh/day' and p_target_kind='electricity_daily_kwh')
      or (p_unit='m3/day' and p_target_kind='water_daily_m3') or (p_unit='PHP/day' and p_target_kind in ('electricity_daily_cost','water_daily_cost')))
    or (p_effective_to is not null and p_effective_to<p_effective_from) or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000
    or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode='22023',message='invalid management target'; end if;
  if exists(select 1 from public.management_target_versions x where x.property_id=p_property_id and x.target_kind=p_target_kind
    and daterange(x.effective_from,coalesce(x.effective_to,'infinity'::date),'[]') && daterange(p_effective_from,coalesce(p_effective_to,'infinity'::date),'[]')) then
    raise exception using errcode='23P01',message='target effective dates overlap'; end if;
  insert into public.management_target_versions(property_id,target_kind,target_value,unit,effective_from,effective_to,reason,approved_by_user_id,idempotency_key)
  values(p_property_id,p_target_kind,p_target_value,p_unit,p_effective_from,p_effective_to,btrim(p_reason),auth.uid(),p_idempotency_key) returning id into v_id;
  return v_id;
end;
$$;

create function public.get_management_metrics(p_property_id uuid,p_period_start date,p_period_end date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_income numeric;v_expense numeric;v_excluded numeric;v_occupied numeric;v_available numeric;v_electric numeric;v_electric_cost numeric;v_water numeric;v_water_cost numeric;v_fresh timestamptz;v_days integer;v_targets jsonb;
begin
  if not public.finance_human_authorized(p_property_id) then raise exception using errcode='42501',message='management metrics denied'; end if;
  if p_period_start is null or p_period_end is null or p_period_end<p_period_start or p_period_end-p_period_start>365 then raise exception using errcode='22023',message='invalid reporting period'; end if;
  select coalesce(sum(reconciled_value) filter(where fact_kind='gross_booking_income'),0),
    coalesce(sum(reconciled_value) filter(where fact_kind='operating_expense'),0),
    coalesce(sum(reconciled_value) filter(where fact_kind='nonoperating_exclusion'),0),
    coalesce(sum(reconciled_value) filter(where fact_kind='occupied_nights'),0),
    coalesce(sum(reconciled_value) filter(where fact_kind='available_nights'),0),
    coalesce(sum(reconciled_value) filter(where fact_kind='electricity_usage'),0),
    coalesce(sum(reconciled_value) filter(where fact_kind='electricity_cost'),0),
    coalesce(sum(reconciled_value) filter(where fact_kind='water_usage'),0),
    coalesce(sum(reconciled_value) filter(where fact_kind='water_cost'),0),max(reconciled_at)
  into v_income,v_expense,v_excluded,v_occupied,v_available,v_electric,v_electric_cost,v_water,v_water_cost,v_fresh
  from public.finance_reconciled_facts where property_id=p_property_id and fact_date between p_period_start and p_period_end;
  v_days:=p_period_end-p_period_start+1;
  select coalesce(jsonb_object_agg(target_kind,jsonb_build_object('value',target_value,'unit',unit,'effective_from',effective_from,'effective_to',effective_to)),'{}'::jsonb)
  into v_targets from (
    select distinct on(target_kind) target_kind,target_value,unit,effective_from,effective_to
    from public.management_target_versions where property_id=p_property_id and effective_from<=p_period_end
      and (effective_to is null or effective_to>=p_period_end)
    order by target_kind,effective_from desc,approved_at desc
  ) x;
  return jsonb_build_object(
    'property_id',p_property_id,'period_start',p_period_start,'period_end',p_period_end,
    'internal_management_only',true,'statutory_or_tax_compliance',false,'currency','PHP',
    'data_freshness',v_fresh,'targets',v_targets,
    'exclusions',jsonb_build_object('nonoperating_amount',v_excluded,'categories',jsonb_build_array('tax','owner_drawings','depreciation','debt')),
    'metrics',jsonb_build_object(
      'gross_booking_income',v_income,'operating_expenses',v_expense,'operating_profit',v_income-v_expense,
      'occupied_nights',v_occupied,'available_nights',v_available,
      'cost_per_available_night',case when v_available>0 then round(v_expense/v_available,2) end,
      'cost_per_occupied_night',case when v_occupied>0 then round(v_expense/v_occupied,2) end,
      'adr',case when v_occupied>0 then round(v_income/v_occupied,2) end,
      'revpar',case when v_available>0 then round(v_income/v_available,2) end,
      'occupancy_pct',case when v_available>0 then round(v_occupied/v_available*100,2) end,
      'electricity_daily_kwh',round(v_electric/v_days,4),'electricity_daily_cost',round(v_electric_cost/v_days,2),
      'water_daily_m3',round(v_water/v_days,4),'water_daily_cost',round(v_water_cost/v_days,2)
    )
  );
end;
$$;

alter table public.finance_reconciliation_candidates enable row level security;
alter table public.finance_reconciliation_reviews enable row level security;
alter table public.finance_reconciled_facts enable row level security;
alter table public.management_target_versions enable row level security;
revoke all on public.finance_reconciliation_candidates,public.finance_reconciliation_reviews,
  public.finance_reconciled_facts,public.management_target_versions from public,anon,authenticated,service_role;
grant select on public.finance_reconciliation_candidates,public.finance_reconciliation_reviews,
  public.finance_reconciled_facts,public.management_target_versions to authenticated;
create policy finance_candidates_read on public.finance_reconciliation_candidates for select to authenticated using(public.finance_human_authorized(property_id));
create policy finance_reviews_read on public.finance_reconciliation_reviews for select to authenticated using(public.finance_human_authorized(property_id));
create policy finance_facts_read on public.finance_reconciled_facts for select to authenticated using(public.finance_human_authorized(property_id));
create policy management_targets_read on public.management_target_versions for select to authenticated using(public.finance_human_authorized(property_id));
revoke all on function public.record_finance_reconciliation(uuid,text,date,text,text,text,text,text,text,numeric,text,text,text,numeric,text) from public,anon,service_role;
revoke all on function public.review_finance_reconciliation(uuid,text,numeric,text,text) from public,anon,service_role;
revoke all on function public.publish_management_target(uuid,text,numeric,text,date,date,text,text) from public,anon,service_role;
revoke all on function public.get_management_metrics(uuid,date,date) from public,anon,service_role;
grant execute on function public.record_finance_reconciliation(uuid,text,date,text,text,text,text,text,text,numeric,text,text,text,numeric,text) to authenticated;
grant execute on function public.review_finance_reconciliation(uuid,text,numeric,text,text) to authenticated;
grant execute on function public.publish_management_target(uuid,text,numeric,text,date,date,text,text) to authenticated;
grant execute on function public.get_management_metrics(uuid,date,date) to authenticated;
comment on table public.finance_reconciliation_candidates is 'Deterministic source comparison only. No candidate is a financial fact until named Finance review.';
comment on table public.finance_reconciled_facts is 'Immutable, named-human reconciled facts used only for internal management analytics.';
comment on function public.get_management_metrics(uuid,date,date) is 'Internal management information; never a tax, statutory, BIR, or filing-compliance output.';
