-- Wave 4 local candidate. No delivery or supplier execution boundary.
create function public.inventory_human_authorized(p_property_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(
   select 1
   from public.staff_access_profiles p
   where p.user_id=auth.uid()
     and p.role in ('owner','admin')
     and p.disabled_at is null
     and auth.jwt()->>'aal'='aal2'
     and (p.sessions_revoked_after is null
       or to_timestamp(coalesce((auth.jwt()->>'iat')::bigint,0))>p.sessions_revoked_after)
     and (p.role='owner' or exists(
       select 1 from public.staff_property_access s
       where s.user_id=p.user_id and s.property_id=p_property_id
     ))
 );
$$;
revoke all on function public.inventory_human_authorized(uuid) from public,anon,service_role;
grant execute on function public.inventory_human_authorized(uuid) to authenticated;

create table public.inventory_stock_movements (
 id uuid primary key default extensions.uuid_generate_v4(),
 item_id uuid not null references public.inventory_items(id) on delete restrict,
 property_id uuid not null references public.properties(id) on delete restrict,
 sequence_no bigint generated always as identity unique,
 kind text not null check(kind in ('receipt','usage','adjustment','reconcile')),
 quantity_before numeric not null check(quantity_before >= 0 and quantity_before < 100000000),
 quantity_after numeric not null check(quantity_after >= 0 and quantity_after < 100000000),
 reason text not null check(char_length(btrim(reason)) between 3 and 2000),
 actor_user_id uuid not null references auth.users(id) on delete restrict,
 idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
 created_at timestamptz not null default now()
);
create table public.inventory_forecasts (
 id uuid primary key default extensions.uuid_generate_v4(),
 item_id uuid not null references public.inventory_items(id) on delete restrict,
 property_id uuid not null references public.properties(id) on delete restrict,
 movement_id uuid not null references public.inventory_stock_movements(id) on delete restrict,
 stock_snapshot numeric not null,
 lookback_days integer not null check(lookback_days between 1 and 365),
 horizon_days integer not null check(horizon_days between 1 and 90),
 usage_quantity numeric not null,
 recommended_quantity numeric not null check(recommended_quantity >= 0),
 method text not null default 'recorded-usage-v1' check(method='recorded-usage-v1'),
 advisory_only boolean not null default true check(advisory_only),
 created_by_user_id uuid not null references auth.users(id) on delete restrict,
 idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
 created_at timestamptz not null default now()
);
create table public.inventory_purchase_reviews (
 id uuid primary key default extensions.uuid_generate_v4(),
 forecast_id uuid not null unique references public.inventory_forecasts(id) on delete restrict,
 property_id uuid not null references public.properties(id) on delete restrict,
 outcome text not null check(outcome in ('approved','rejected')),
 quantity numeric not null check(quantity > 0 and quantity < 100000000),
 reason text not null check(char_length(btrim(reason)) between 3 and 2000),
 reviewer_user_id uuid not null references auth.users(id) on delete restrict,
 order_authorized boolean not null default false check(not order_authorized),
 idempotency_key text not null unique check(char_length(idempotency_key) between 16 and 160),
 reviewed_at timestamptz not null default now()
);

create function public.record_inventory_movement(p_item_id uuid,p_kind text,p_quantity numeric,p_reason text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare i public.inventory_items%rowtype; m public.inventory_stock_movements%rowtype; v_after numeric; v_id uuid;
begin
 select * into i from public.inventory_items where id=p_item_id for update;
 if not found or not public.inventory_human_authorized(i.property_id) then raise exception using errcode='42501',message='inventory access denied'; end if;
 if p_kind is null or p_kind not in ('receipt','usage','adjustment','reconcile') or p_quantity is null
 or p_quantity <= -100000000 or p_quantity >= 100000000 or p_quantity <> round(p_quantity,2) or p_quantity::text in ('NaN','Infinity','-Infinity')
 or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000
 or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then
 raise exception using errcode='22023',message='invalid stock movement'; end if;
 select * into m from public.inventory_stock_movements where item_id=i.id and idempotency_key=p_idempotency_key;
 if found then
 if m.kind is distinct from p_kind or m.reason is distinct from btrim(p_reason) or m.actor_user_id is distinct from auth.uid()
 or (case when p_kind='reconcile' then m.quantity_after else m.quantity_after-m.quantity_before end) is distinct from p_quantity then
 raise exception using errcode='22023',message='idempotency conflict'; end if;
 return m.id; end if;
 if not coalesce(i.is_active,false) or i.qty_on_hand is null or i.qty_on_hand < 0 or i.qty_on_hand >= 100000000 then
 raise exception using errcode='22023',message='invalid canonical stock'; end if;
 select * into m from public.inventory_stock_movements where item_id=i.id order by sequence_no desc limit 1;
 if p_kind <> 'reconcile' and (not found or m.quantity_after is distinct from i.qty_on_hand or m.property_id is distinct from i.property_id) then
 raise exception using errcode='22023',message='stock reconciliation required'; end if;
 if (p_kind='receipt' and p_quantity<=0) or (p_kind='usage' and p_quantity>=0) then
 raise exception using errcode='22023',message='invalid movement direction'; end if;
 v_after := case when p_kind='reconcile' then p_quantity else i.qty_on_hand+p_quantity end;
 insert into public.inventory_stock_movements(item_id,property_id,kind,quantity_before,quantity_after,reason,actor_user_id,idempotency_key)
 values(i.id,i.property_id,p_kind,i.qty_on_hand,v_after,btrim(p_reason),auth.uid(),p_idempotency_key) returning id into v_id;
 update public.inventory_items set qty_on_hand=v_after where id=i.id;
 return v_id;
end;
$$;

create function public.forecast_inventory(p_item_id uuid,p_lookback_days integer,p_horizon_days integer,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare i public.inventory_items%rowtype; m public.inventory_stock_movements%rowtype; f public.inventory_forecasts%rowtype; v_usage numeric; v_id uuid;
begin
 select * into i from public.inventory_items where id=p_item_id for update;
 if not found or not public.inventory_human_authorized(i.property_id) then raise exception using errcode='42501',message='inventory access denied'; end if;
 if p_lookback_days is null or p_lookback_days not between 1 and 365 or p_horizon_days is null or p_horizon_days not between 1 and 90
 or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode='22023',message='invalid forecast'; end if;
 select * into f from public.inventory_forecasts where item_id=i.id and idempotency_key=p_idempotency_key;
 if found then
 if f.lookback_days is distinct from p_lookback_days or f.horizon_days is distinct from p_horizon_days or f.created_by_user_id is distinct from auth.uid() then raise exception using errcode='22023',message='idempotency conflict'; end if;
 return f.id; end if;
 select * into m from public.inventory_stock_movements where item_id=i.id order by sequence_no desc limit 1;
 if not found or m.quantity_after is distinct from i.qty_on_hand or m.property_id is distinct from i.property_id or not coalesce(i.is_active,false) then
 raise exception using errcode='22023',message='stock reconciliation required'; end if;
 select coalesce(sum(quantity_before-quantity_after),0) into v_usage from public.inventory_stock_movements
 where item_id=i.id and property_id=i.property_id and kind='usage' and created_at>=now()-make_interval(days=>p_lookback_days);
 insert into public.inventory_forecasts(item_id,property_id,movement_id,stock_snapshot,lookback_days,horizon_days,usage_quantity,recommended_quantity,created_by_user_id,idempotency_key)
 values(i.id,i.property_id,m.id,i.qty_on_hand,p_lookback_days,p_horizon_days,v_usage,
 greatest(0,ceil(v_usage/p_lookback_days*p_horizon_days-i.qty_on_hand)),auth.uid(),p_idempotency_key) returning id into v_id;
 return v_id;
end;
$$;

create function public.review_inventory_purchase(p_forecast_id uuid,p_outcome text,p_quantity numeric,p_reason text,p_idempotency_key text)
returns uuid language plpgsql security definer set search_path='' as $$
declare f public.inventory_forecasts%rowtype; i public.inventory_items%rowtype; r public.inventory_purchase_reviews%rowtype; v_movement uuid; v_id uuid;
begin
 select * into f from public.inventory_forecasts where id=p_forecast_id;
 if not found or not public.inventory_human_authorized(f.property_id) then raise exception using errcode='42501',message='purchase review denied'; end if;
 -- Same item lock as movements and forecast creation: no stale approval race.
 select * into i from public.inventory_items where id=f.item_id for update;
 select * into r from public.inventory_purchase_reviews where forecast_id=f.id;
 if found then
 if r.idempotency_key is distinct from p_idempotency_key or r.outcome is distinct from p_outcome or r.quantity is distinct from p_quantity
 or r.reason is distinct from btrim(p_reason) or r.reviewer_user_id is distinct from auth.uid() then raise exception using errcode='22023',message='review conflict'; end if;
 return r.id; end if;
 if p_outcome is null or p_outcome not in ('approved','rejected') or p_quantity is null or p_quantity<=0 or p_quantity>=100000000
 or p_quantity <> round(p_quantity,2) or p_quantity::text in ('NaN','Infinity','-Infinity') or p_reason is null or char_length(btrim(p_reason)) not between 3 and 2000
 or p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode='22023',message='invalid purchase review'; end if;
 select id into v_movement from public.inventory_stock_movements where item_id=i.id order by sequence_no desc limit 1;
 if i.property_id is distinct from f.property_id or not coalesce(i.is_active,false) or i.qty_on_hand is distinct from f.stock_snapshot
 or v_movement is distinct from f.movement_id or f.created_at < now()-interval '24 hours' then raise exception using errcode='22023',message='stale forecast'; end if;
 insert into public.inventory_purchase_reviews(forecast_id,property_id,outcome,quantity,reason,reviewer_user_id,idempotency_key)
 values(f.id,f.property_id,p_outcome,p_quantity,btrim(p_reason),auth.uid(),p_idempotency_key) returning id into v_id;
 return v_id;
end;
$$;

alter table public.inventory_stock_movements enable row level security;
alter table public.inventory_forecasts enable row level security;
alter table public.inventory_purchase_reviews enable row level security;
revoke all on public.inventory_stock_movements,public.inventory_forecasts,public.inventory_purchase_reviews from public,anon,authenticated,service_role;
grant select on public.inventory_stock_movements,public.inventory_forecasts,public.inventory_purchase_reviews to authenticated;
create policy inventory_movements_read on public.inventory_stock_movements for select to authenticated using(public.inventory_human_authorized(property_id));
create policy inventory_forecasts_read on public.inventory_forecasts for select to authenticated using(public.inventory_human_authorized(property_id));
create policy inventory_reviews_read on public.inventory_purchase_reviews for select to authenticated using(public.inventory_human_authorized(property_id));
revoke all on function public.record_inventory_movement(uuid,text,numeric,text,text) from public,anon,service_role;
revoke all on function public.forecast_inventory(uuid,integer,integer,text) from public,anon,service_role;
revoke all on function public.review_inventory_purchase(uuid,text,numeric,text,text) from public,anon,service_role;
grant execute on function public.record_inventory_movement(uuid,text,numeric,text,text) to authenticated;
grant execute on function public.forecast_inventory(uuid,integer,integer,text) to authenticated;
grant execute on function public.review_inventory_purchase(uuid,text,numeric,text,text) to authenticated;
comment on table public.inventory_forecasts is 'Advisory recorded-usage forecast; incomplete history may understate demand. Never a supplier order.';
comment on table public.inventory_purchase_reviews is 'Immutable named-human shopping-list decision only. Fulfilment and financial approval remain separate.';
