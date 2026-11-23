-- Session 133: release s133_option_stock_20261203 (D-399 to D-402). Per-product stock: brands (options) of one item each carry their own quantity on hand, a receipt can add several brands at once, the group update sheet saves many items in
-- one transaction, and product links / photos follow the new payload rules. Over s132_inventory_update_20261202 (live), which must already be applied.
--
--   RULE 0   nothing released in s132 is edited: reconcile_inventory_baseline_v1, record_inventory_usage, record_inventory_receipt_v1, inventory_receipt_manual_v1, record_inventory_damage_v1 and every undo function keep their md5
--            (the guard below asserts it, 55000 otherwise). New behaviour is NEW wrapper functions that call them, plus one trigger.
--   COLUMNS  inventory_item_options.qty_on_hand numeric not null default 0 check (>= 0) (D-402);  inventory_purchases.option_id uuid null references inventory_item_options on delete set null (the brand a receipt line was for).
--            Invariant: sum(options.qty_on_hand of an item) <= inventory_items.qty_on_hand. "Not sorted" = the difference, computed, never stored.
--   TRIGGER  inventory_items_option_clamp_v1 (AFTER UPDATE OF qty_on_hand on inventory_items; internal s_inventory_option_clamp_v1, security definer, search_path ''): when the item quantity falls below the options' sum (usage, damage,
--            undo, a recount through the old path) it shrinks the options until the invariant holds: the usual option first, then the others by largest quantity, then by id. It never raises (a problem is a warning).
--   NEW      inventory_option_count_v1, inventory_receipt_lines_v1, inventory_option_use_v1, inventory_group_update_v1, inventory_item_history_v2, inventory_log_v1 (read only whole-inventory log, contract 5) (authenticated only);
--            internal s_inventory_option_clamp_v1 and s_inventory_derive_key_v1 (no grant).
--   CHANGED  s_inventory_option_payload_v1 (internal, same signature, create or replace behind an md5 guard): source_url is any https link whose host has no '@' (no userinfo), image_url is one of the two current hosts or a stored photo path items/<item>/<uuid>.webp|jpg;
--            the table checks inventory_item_options_source_url_check and _image_url_check are relaxed to match. Every other check of the validator is unchanged.
--            inventory_item_options_v1 (read, same signature, one anchored edit behind an md5 guard): every option also carries qty_on_hand.
-- Order of work in the count wrapper: the listed options are set first and the item recount (reconcile) follows in the same transaction. The contract says reconcile first; the result is the same, but the other order stops the trigger
-- from shrinking an option the caller did not list (the trigger would see the old option quantities against the new, lower item quantity).
-- Known limits: an undo of a count / receipt / use restores the item quantity and the trigger clamps the options (it cannot know which brand the undone stock was); a replay returns the same shape built from the wrapped replays, not a stored copy;
-- a multi-brand receipt leaves the usage learning's last refill marker on the last line.
-- Guard (55000, nothing changes): the live bodies named above must be the s132 ones or this release. Grants restated (ML-21).
-- Rollback: supabase/rollbacks/20261203_s133_option_stock.sql.

begin;

-- 0. guard ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare r record; v text;
begin
  for r in select * from (values
    ('public.reconcile_inventory_baseline_v1(uuid,numeric,text,text)', 'fdeaf212bebc578ee82f9240e6c05417', null),
    ('public.record_inventory_usage(uuid,date,text,text,jsonb)', '365f7c6d50258a611612465e4ad3624b', null),
    ('public.record_inventory_receipt_v1(uuid,numeric,numeric,text,date,text,uuid,text,uuid,text)', 'd190f6b6051be034e9e9babb99cbbf56', null),
    ('public.inventory_receipt_manual_v1(jsonb,date,text,text,numeric,text,text)', '8c407320edbbc9d944a86461bef23adf', null),
    ('public.record_inventory_damage_v1(uuid,jsonb,text,uuid,boolean,text,text,text)', '5e8e9bb09ce488f86566236d32620a01', null),
    ('public.undo_inventory_damage_v1(uuid)', 'bbb566116e036671a30fa15f1c2ba1e7', null),
    ('public.undo_inventory_usage_v1(text)', '77de62aa768dc56b9c711beb9c10e49f', null),
    ('public.undo_linen_stain_v1(text)', '5d6fdd96f8fd8e3a53ca158f3859d9e1', null),
    ('public.inventory_undo_v1(uuid,uuid)', '5125463a4d686d5a180f1ee599fa00b7', null),
    ('public.inventory_item_change_undo_v1(uuid)', 'f513d523af5ef4f99055ca73e789b7ce', null),
    ('public.inventory_item_history_v1(uuid)', 'bbf90cfbd5f97158307e12502ae1223e', null),
    ('public.inventory_item_options_v1(uuid)', '8f1ca123739b2d13d23c92dcac3ba76d', '55f85ee60e29243ef6dfc68173a76912'),
    ('public.s_inventory_option_payload_v1(uuid,jsonb,boolean)', 'ce729144e29fba1dd96aab1d46aadeff', '065b6b1d88c60712b51ea5713e68c3b4')
  ) t(sig, m_a, m_b) loop
    select md5(replace(p.prosrc, chr(13), '')) into v from pg_proc p where p.oid = to_regprocedure(r.sig);
    if v is null then raise exception 's133: % is missing (apply s132 first)', r.sig using errcode = '55000'; end if;
    if v is distinct from r.m_a and v is distinct from r.m_b then
      raise exception 's133: % is not the body this release was cut from (md5 %): re-cut it from the live body', r.sig, v using errcode = '55000';
    end if;
  end loop;
end $g$;

-- 1. columns -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_item_options add column if not exists qty_on_hand numeric not null default 0 constraint inventory_item_options_qty_on_hand_check check (qty_on_hand >= 0);
alter table public.inventory_purchases add column if not exists option_id uuid references public.inventory_item_options(id) on delete set null;
comment on column public.inventory_item_options.qty_on_hand is 'S133: units of this brand on hand. sum over an item <= inventory_items.qty_on_hand; the rest is "Not sorted" (computed, never stored). Shrunk by the clamp trigger when the item quantity falls.';
comment on column public.inventory_purchases.option_id is 'S133: the brand (option) a receipt line was for; null for a line with no brand. History v2 shows its title.';

-- 2. product link and photo rules (contract 2e): table checks relaxed, validator re-cut -------------------------------------------------------------------------------------------------------------------------------
alter table public.inventory_item_options drop constraint if exists inventory_item_options_source_url_check;
alter table public.inventory_item_options add constraint inventory_item_options_source_url_check
  check (source_url is null or source_url ~ '^https://[^\s/@]+\.[^\s/@]+(/\S*)?$');
alter table public.inventory_item_options drop constraint if exists inventory_item_options_image_url_check;
alter table public.inventory_item_options add constraint inventory_item_options_image_url_check
  check (image_url is null or image_url ~ '^https://(cdn\.shopify\.com|down-ph\.img\.susercontent\.com)/' or image_url ~ ('^items/' || item_id::text || '/[0-9a-f-]{36}\.(webp|jpg)$'));

create or replace function public.s_inventory_option_payload_v1(p_prop uuid, p_payload jsonb, p_allow_price boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_out jsonb := '{}'::jsonb; k text; v jsonb; t text;
begin
  if p_payload is null then return v_out; end if;
  if jsonb_typeof(p_payload) <> 'object' then raise exception using errcode = '22023', message = 'payload must be an object'; end if;
  for k, v in select * from jsonb_each(p_payload) loop
    if k <> all (array['title', 'brand', 'pack_label', 'pack_size', 'price', 'image_url', 'source_url', 'supplier_id', 'available']) then
      raise exception using errcode = '22023', message = 'field not allowed: ' || k;
    end if;
    if k = 'price' and not p_allow_price then
      if v <> 'null'::jsonb then raise exception using errcode = '22023', message = 'price_not_allowed'; end if;
      continue;
    end if;
    if v = 'null'::jsonb then
      if k in ('title', 'supplier_id') then raise exception using errcode = '22023', message = k || ' cannot be cleared'; end if;
      v_out := v_out || jsonb_build_object(k, null);
      continue;
    end if;
    t := jsonb_typeof(v);
    if k in ('title', 'brand', 'pack_label', 'image_url', 'source_url', 'supplier_id') and t <> 'string' then raise exception using errcode = '22023', message = k || ' must be text'; end if;
    if k in ('pack_size', 'price') and t <> 'number' then raise exception using errcode = '22023', message = k || ' must be a number'; end if;
    if k = 'available' and t <> 'boolean' then raise exception using errcode = '22023', message = 'available must be true or false'; end if;
    if k = 'title' and char_length(btrim(v #>> '{}')) not between 1 and 160 then raise exception using errcode = '22023', message = 'title must be 1 to 160 characters'; end if;
    if k = 'brand' and char_length(v #>> '{}') > 60 then raise exception using errcode = '22023', message = 'brand is too long'; end if;
    if k = 'pack_label' and char_length(v #>> '{}') > 40 then raise exception using errcode = '22023', message = 'pack label is too long'; end if;
    if k = 'pack_size' and not ((v #>> '{}')::numeric > 0 and (v #>> '{}')::numeric < 100000) then raise exception using errcode = '22023', message = 'pack size must be more than 0 and below 100000'; end if;
    if k = 'price' and not ((v #>> '{}')::numeric >= 0.01 and (v #>> '{}')::numeric < 1000000) then raise exception using errcode = '22023', message = 'price must be at least 0.01 and below 1000000'; end if;
    if k = 'image_url' and (v #>> '{}') !~ '^https://(cdn\.shopify\.com|down-ph\.img\.susercontent\.com)/' and (v #>> '{}') !~ '^items/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(webp|jpg)$' then raise exception using errcode = '22023', message = 'image must be https on cdn.shopify.com or down-ph.img.susercontent.com, or a stored photo of this item'; end if;
    if k = 'source_url' and (v #>> '{}') !~ '^https://[^\s/@]+\.[^\s/@]+(/\S*)?$' then raise exception using errcode = '22023', message = 'product link must be an https link'; end if;
    if k in ('image_url', 'source_url') and char_length(v #>> '{}') > 500 then raise exception using errcode = '22023', message = k || ' is too long'; end if;
    if k = 'supplier_id' then
      if (v #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         or not exists (select 1 from public.inventory_suppliers s where s.id = (v #>> '{}')::uuid and s.property_id = p_prop and s.is_active) then
        raise exception using errcode = '22023', message = 'supplier must be an active supplier of this property';
      end if;
    end if;
    v_out := v_out || jsonb_build_object(k, case when k = 'title' then to_jsonb(btrim(v #>> '{}')) else v end);
  end loop;
  return v_out;
end;
$$;
revoke all on function public.s_inventory_option_payload_v1(uuid, jsonb, boolean) from public, anon, authenticated, service_role;

-- 3. the options read carries qty_on_hand (contract 2f) --------------------------------------------------------------------------------------------------------------------------------------------------------------
do $g$
declare v_src text; v_new text;
begin
  select replace(p.prosrc, chr(13), '') into v_src from pg_proc p where p.oid = to_regprocedure('public.inventory_item_options_v1(uuid)');
  if v_src is null then raise exception 's133: public.inventory_item_options_v1(uuid) is missing' using errcode = '55000'; end if;
  if md5(v_src) = '55f85ee60e29243ef6dfc68173a76912' then raise notice 's133: inventory_item_options_v1 already carries this change'; return; end if;
  if md5(v_src) <> '8f1ca123739b2d13d23c92dcac3ba76d' then raise exception 's133: inventory_item_options_v1 is not the body this release was cut from (md5 %): re-cut it from the live body', md5(v_src) using errcode = '55000'; end if;
  v_new := replace(v_src, replace($f$'preferred', o.is_preferred, 'available', o.available,$f$, chr(13), ''), replace($r$'preferred', o.is_preferred, 'qty_on_hand', o.qty_on_hand, 'available', o.available,$r$, chr(13), ''));
  if v_new = v_src or md5(v_new) <> '55f85ee60e29243ef6dfc68173a76912' then raise exception 's133: inventory_item_options_v1 patch did not produce the expected body (md5 %)', md5(v_new) using errcode = '55000'; end if;
  execute format($e$create or replace function public.inventory_item_options_v1(p_item_id uuid)
    returns jsonb language plpgsql stable security definer set search_path = '' as %L$e$, v_new);
end $g$;
revoke all on function public.inventory_item_options_v1(uuid) from public, anon, service_role;
grant execute on function public.inventory_item_options_v1(uuid) to authenticated;

-- 4. internal helpers ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- a key derived from a caller's key: key:gSUFFIX (the fixed ':g' marks it as derived, so the log can tell a group's rows from a Staff single-call key), or a fixed-length hash when that would pass 160 characters (so a nested group -> row -> line key never passes the 16..160 limit of the wrapped functions)
create or replace function public.s_inventory_derive_key_v1(p_key text, p_suffix text)
returns text language sql immutable set search_path = '' as $$
  select case when char_length(p_key || ':g' || p_suffix) <= 160 then p_key || ':g' || p_suffix else 'h' || md5(p_key || ':g' || p_suffix) end
$$;
revoke all on function public.s_inventory_derive_key_v1(text, text) from public, anon, authenticated, service_role;

-- 5. the clamp trigger (contract 1) ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.s_inventory_option_clamp_v1()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_sum numeric; v_excess numeric; r record; v_cut numeric;
begin
  begin
    if new.qty_on_hand is null then return null; end if;
    select coalesce(sum(o.qty_on_hand), 0) into v_sum from public.inventory_item_options o where o.item_id = new.id;
    v_excess := v_sum - new.qty_on_hand;
    if v_excess > 0 then
      -- the usual option first, then the others by largest quantity, then by id
      for r in select o.id, o.qty_on_hand from public.inventory_item_options o where o.item_id = new.id and o.qty_on_hand > 0 order by o.is_usual desc, o.qty_on_hand desc, o.id for update loop
        exit when v_excess <= 0;
        v_cut := least(r.qty_on_hand, v_excess);
        update public.inventory_item_options set qty_on_hand = qty_on_hand - v_cut where id = r.id;
        v_excess := v_excess - v_cut;
      end loop;
    end if;
  exception when others then
    raise warning 's133 option clamp (item %): % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end;
$$;
revoke all on function public.s_inventory_option_clamp_v1() from public, anon, authenticated, service_role;
drop trigger if exists inventory_items_option_clamp_v1 on public.inventory_items;
create trigger inventory_items_option_clamp_v1 after update of qty_on_hand on public.inventory_items
  for each row when (new.qty_on_hand is distinct from old.qty_on_hand) execute function public.s_inventory_option_clamp_v1();

-- 6. inventory_option_count_v1 (contract 2a) -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Count the brands of one item: each listed option gets its quantity, p_unsorted is what is on the shelf with no brand, the item total is their sum. Gate = reconcile_inventory_baseline_v1 (manage_inventory, else submit_cleaning,
-- else report_supply). Options not listed keep their quantity; when they would not fit under the new total the call returns {ok:false, error:'counts_exceed'} and changes nothing.
create or replace function public.inventory_option_count_v1(p_item_id uuid, p_counts jsonb, p_unsorted numeric, p_note text, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  i public.inventory_items%rowtype; c jsonb; v_counts jsonb := coalesce(p_counts, '[]'::jsonb); v_oid uuid; v_q numeric; v_ids uuid[] := '{}'; v_sum numeric := 0; v_uns numeric := coalesce(p_unsorted, 0);
  v_total numeric; v_other numeric; v_res jsonb; v_opts jsonb; v_replay boolean;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select * into i from public.inventory_items x where x.id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  if not public.current_staff_authorized('manage_inventory', i.property_id) then
    if not public.current_staff_authorized('submit_cleaning', i.property_id) then perform public.admin_require('report_supply', i.property_id); end if;
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters'; end if;
  if jsonb_typeof(v_counts) <> 'array' or jsonb_array_length(v_counts) > 100 then raise exception using errcode = '22023', message = 'counts must be a list of up to 100 options'; end if;
  if v_uns < 0 or v_uns <> round(v_uns, 2) then raise exception using errcode = '22023', message = 'not sorted must be 0 or more with at most 2 decimals'; end if;
  for c in select e.value from jsonb_array_elements(v_counts) e loop
    if jsonb_typeof(c) <> 'object' or jsonb_typeof(c -> 'option_id') is distinct from 'string' or jsonb_typeof(c -> 'qty') is distinct from 'number'
       or (c ->> 'option_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception using errcode = '22023', message = 'each count needs an option_id and a qty';
    end if;
    v_oid := (c ->> 'option_id')::uuid; v_q := (c ->> 'qty')::numeric;
    if v_q < 0 or v_q <> round(v_q, 2) then raise exception using errcode = '22023', message = 'counts must be 0 or more with at most 2 decimals'; end if;
    if v_oid = any (v_ids) then raise exception using errcode = '22023', message = 'an option is listed twice'; end if;
    if not exists (select 1 from public.inventory_item_options o where o.id = v_oid and o.item_id = p_item_id) then raise exception using errcode = '22023', message = 'option does not belong to this item'; end if;
    v_ids := v_ids || v_oid; v_sum := v_sum + v_q;
  end loop;
  v_total := v_sum + v_uns;
  -- a replay (the count movement of this key exists) changes no option: the stock was set by the first call
  v_replay := exists (select 1 from public.inventory_stock_movements m where m.item_id = p_item_id and m.idempotency_key = p_idempotency_key);
  if not v_replay then
    perform 1 from public.inventory_item_options o where o.item_id = p_item_id for update;
    select coalesce(sum(o.qty_on_hand), 0) into v_other from public.inventory_item_options o where o.item_id = p_item_id and o.id <> all (v_ids);
    if v_other > v_uns then return jsonb_build_object('ok', false, 'error', 'counts_exceed'); end if;
    update public.inventory_item_options o set qty_on_hand = (e.value ->> 'qty')::numeric
      from jsonb_array_elements(v_counts) e where o.item_id = p_item_id and o.id = (e.value ->> 'option_id')::uuid;
  end if;
  v_res := public.reconcile_inventory_baseline_v1(p_item_id, v_total, p_note, p_idempotency_key);
  select coalesce(jsonb_agg(jsonb_build_object('option_id', o.id, 'qty', o.qty_on_hand) order by e.ord), '[]'::jsonb) into v_opts
    from jsonb_array_elements(v_counts) with ordinality e(value, ord) join public.inventory_item_options o on o.id = (e.value ->> 'option_id')::uuid and o.item_id = p_item_id;
  return v_res || jsonb_build_object('ok', true, 'total', v_total, 'options', v_opts) || case when v_replay then jsonb_build_object('replayed', true) else '{}'::jsonb end;
end;
$$;

-- 7. inventory_receipt_lines_v1 (contract 2b) ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- One receipt, several brands. Units of a line = packs x the option's pack_size (the item's own units_per_purchase when the line has no option or the option has no size). Every line is one record_inventory_receipt_v1 call with
-- p_packs = units / units_per_purchase (the receipt multiplies it back, so exactly the line's units are added), key = key:gLINE_NO. The option's quantity grows by what the receipt added; a line with no option adds to Not sorted.
-- p_total_paid is split over the lines by their share of price x packs (the line's unit_cost, else the option price, else the item's unit cost x pack), each share rounded to 2 places, the remainder on the last line.
create or replace function public.inventory_receipt_lines_v1(p_item_id uuid, p_lines jsonb, p_total_paid numeric, p_purchased_at date, p_supplier_id uuid, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  i public.inventory_items%rowtype; o public.inventory_item_options%rowtype; v_upp numeric; e jsonb; v_n integer; v_no integer := 0; v_plan jsonb := '[]'::jsonb; v_size numeric; v_packs numeric; v_cost numeric; v_oid uuid;
  v_units numeric; v_price numeric; v_w numeric; v_wsum numeric := 0; v_left numeric; v_t numeric; v_lcost numeric; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total_units numeric := 0; v_replayed boolean := true;
  v_added numeric; v_pid uuid; p jsonb;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  select * into i from public.inventory_items x where x.id = p_item_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('manage_inventory', i.property_id);
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) not between 1 and 20 then raise exception using errcode = '22023', message = 'lines must be 1 to 20'; end if;
  if p_total_paid is not null and (p_total_paid < 0 or p_total_paid >= 100000000) then raise exception using errcode = '22023', message = 'total paid must be 0 or more'; end if;
  v_upp := coalesce(i.units_per_purchase, 1);
  if v_upp <= 0 then raise exception using errcode = '22023', message = 'the item has no valid pack size'; end if;
  v_n := jsonb_array_length(p_lines);
  -- pass 1: validate every line and work out its units and its weight before anything is written
  for e in select x.value from jsonb_array_elements(p_lines) x loop
    v_no := v_no + 1;
    if jsonb_typeof(e) <> 'object' then raise exception using errcode = '22023', message = 'line ' || v_no || ' must be an object'; end if;
    if jsonb_typeof(e -> 'packs') is distinct from 'number' or (e ->> 'packs')::numeric <= 0 or (e ->> 'packs')::numeric >= 100000 then raise exception using errcode = '22023', message = 'packs must be positive'; end if;
    v_packs := (e ->> 'packs')::numeric;
    if e -> 'unit_cost' is not null and jsonb_typeof(e -> 'unit_cost') <> 'null' then
      if jsonb_typeof(e -> 'unit_cost') <> 'number' or (e ->> 'unit_cost')::numeric < 0 or (e ->> 'unit_cost')::numeric >= 1000000 then raise exception using errcode = '22023', message = 'unit cost must be 0 or more'; end if;
      v_cost := (e ->> 'unit_cost')::numeric;
    else
      v_cost := null;
    end if;
    v_oid := null; o := null;
    if e -> 'option_id' is not null and jsonb_typeof(e -> 'option_id') <> 'null' then
      if jsonb_typeof(e -> 'option_id') <> 'string' or (e ->> 'option_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception using errcode = '22023', message = 'option does not belong to this item'; end if;
      v_oid := (e ->> 'option_id')::uuid;
      select * into o from public.inventory_item_options x where x.id = v_oid and x.item_id = p_item_id;
      if not found then raise exception using errcode = '22023', message = 'option does not belong to this item'; end if;
    end if;
    v_size := coalesce(case when v_oid is not null then o.pack_size end, v_upp);
    v_units := round(v_packs * v_size, 2);
    if v_units <= 0 then raise exception using errcode = '22023', message = 'quantity is too small'; end if;
    -- the line's default price per pack: what was typed, else the option price, else the item's unit cost per base unit x the pack
    v_price := coalesce(v_cost, case when v_oid is not null then o.price end, i.unit_cost * v_size, 0);
    v_w := v_price * v_packs;
    v_wsum := v_wsum + v_w;
    v_plan := v_plan || jsonb_build_object('line_no', v_no, 'option_id', v_oid, 'packs', v_packs, 'unit_cost', v_cost, 'size', v_size, 'units', v_units, 'w', v_w);
  end loop;
  -- the shares of the total paid: round(total x w / sum w, 2) per line, never more than what is left, the remainder on the last line; when every weight is 0 the share follows the units
  if p_total_paid is not null and v_wsum = 0 then
    v_wsum := 0;
    for p in select x.value from jsonb_array_elements(v_plan) x loop v_wsum := v_wsum + (p ->> 'units')::numeric; end loop;
  end if;
  v_left := p_total_paid;
  -- pass 2: one receipt per line
  for p in select x.value from jsonb_array_elements(v_plan) x loop
    v_no := (p ->> 'line_no')::integer;
    v_units := (p ->> 'units')::numeric; v_packs := (p ->> 'packs')::numeric; v_size := (p ->> 'size')::numeric;
    v_oid := nullif(p ->> 'option_id', '')::uuid;
    v_lcost := nullif(p ->> 'unit_cost', '')::numeric;
    if p_total_paid is not null then
      if v_no = v_n then v_t := v_left;
      else v_t := least(v_left, round(p_total_paid * case when (select sum((q ->> 'w')::numeric) from jsonb_array_elements(v_plan) q) = 0 then v_units else (p ->> 'w')::numeric end / v_wsum, 2));
      end if;
      v_left := v_left - v_t;
      v_lcost := round(v_t / v_packs, 4);   -- paid per line pack
    end if;
    v_res := public.record_inventory_receipt_v1(p_item_id, v_units / v_upp, case when v_lcost is not null then v_lcost * v_upp / v_size end, null, p_purchased_at, null, null,
                                                 public.s_inventory_derive_key_v1(p_idempotency_key, v_no::text), p_supplier_id, null);
    if coalesce((v_res ->> 'ok')::boolean, false) is not true then raise exception using errcode = '22023', message = 'line ' || v_no || ' was not recorded'; end if;
    if coalesce((v_res ->> 'replayed')::boolean, false) is not true then
      v_replayed := false;
      v_added := coalesce((v_res ->> 'unitsAdded')::numeric, v_units);
      if v_oid is not null then
        update public.inventory_item_options set qty_on_hand = qty_on_hand + v_added where id = v_oid;
        v_pid := nullif(v_res ->> 'purchaseId', '')::uuid;
        if v_pid is not null then update public.inventory_purchases set option_id = v_oid where id = v_pid; end if;
      end if;
    end if;
    v_total_units := v_total_units + v_units;
    v_out := v_out || jsonb_build_object('line_no', v_no, 'option_id', v_oid, 'units', v_units, 'result', v_res);
  end loop;
  return jsonb_build_object('ok', true, 'lines', v_out, 'total_units', v_total_units) || case when v_replayed then jsonb_build_object('replayed', true) else '{}'::jsonb end;
end;
$$;

-- 8. inventory_option_use_v1 (contract 2c) -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Use some of one brand: min(p_qty, the brand's quantity) comes off the brand first, the rest from Not sorted; then record_inventory_usage is called with one row in the shape the Staff app sends. With no option it is that call
-- unchanged (the trigger keeps the invariant). Gate = record_inventory_usage (submit_cleaning or report_supply).
create or replace function public.inventory_option_use_v1(p_property_id uuid, p_item_id uuid, p_option_id uuid, p_qty numeric, p_note text, p_session_date date, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i public.inventory_items%rowtype; o public.inventory_item_options%rowtype; v_sub numeric := 0; v_res jsonb; v_replay boolean;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if not (public.current_staff_authorized('submit_cleaning', p_property_id) or public.current_staff_authorized('report_supply', p_property_id)) then raise exception using errcode = '42501', message = 'staff access denied'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters'; end if;
  if p_qty is null or p_qty <= 0 then raise exception using errcode = '22023', message = 'each row needs item_id and a positive used_qty'; end if;
  select * into i from public.inventory_items x where x.id = p_item_id and x.property_id = p_property_id for update;
  if not found then raise exception using errcode = '22023', message = 'unknown item for property'; end if;
  if p_option_id is not null then
    select * into o from public.inventory_item_options x where x.id = p_option_id and x.item_id = p_item_id for update;
    if not found then raise exception using errcode = '22023', message = 'option does not belong to this item'; end if;
    -- a replay (a usage row of this key exists) takes nothing off the brand again; the same LIKE predicate record_inventory_usage uses, so the two always agree
    v_replay := exists (select 1 from public.inventory_usage u where (u.item_id = p_item_id or u.moved_from_item_id = p_item_id) and u.notes like '%[key:' || p_idempotency_key || ']%');
    if not v_replay then
      v_sub := least(p_qty, o.qty_on_hand);
      if v_sub > 0 then update public.inventory_item_options set qty_on_hand = qty_on_hand - v_sub where id = p_option_id; end if;
    end if;
  end if;
  v_res := public.record_inventory_usage(p_property_id, p_session_date, null, coalesce(left(nullif(btrim(coalesce(p_note, '')), ''), 200), 'Logged in the staff app'),
             jsonb_build_array(jsonb_build_object('item_id', p_item_id, 'used_qty', p_qty, 'usage_key', p_idempotency_key)));
  if p_option_id is null then return v_res; end if;
  return v_res || jsonb_build_object('option_id', p_option_id, 'from_option', v_sub, 'from_not_sorted', case when v_replay then 0 else p_qty - v_sub end);
end;
$$;

-- 9. inventory_group_update_v1 (contract 2d) -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Many items in one transaction: mode count ({item_id, qty[, note]}), used ({item_id, qty[, option_id][, note]}) or bought ({item_id, lines[, total_paid][, supplier_id]}). Each row calls the single-item function with key:gIDX
-- (IDX counts from 0, the position in p_rows). Any failing row raises "row idx: ..." with the original SQLSTATE and the whole call rolls back, so nothing is half saved. The same item may appear once in count and bought.
create or replace function public.inventory_group_update_v1(p_property_id uuid, p_mode text, p_rows jsonb, p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r jsonb; v_idx integer := -1; v_item uuid; v_seen uuid[] := '{}'; v_res jsonb; v_key text; v_oid uuid; v_qty numeric; v_prop uuid; v_sup uuid; v_tp numeric; v_out jsonb := '[]'::jsonb; v_note text;
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_property_id is null then raise exception using errcode = '22023', message = 'property required'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) not between 16 and 160 then raise exception using errcode = '22023', message = 'idempotency key must be 16 to 160 characters'; end if;
  if p_mode is null or p_mode not in ('count', 'bought', 'used') then raise exception using errcode = '22023', message = 'mode must be count, bought or used'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) not between 1 and 60 then raise exception using errcode = '22023', message = 'rows must be 1 to 60'; end if;
  for r in select x.value from jsonb_array_elements(p_rows) x loop
    v_idx := v_idx + 1;
    begin
      if jsonb_typeof(r) <> 'object' then raise exception using errcode = '22023', message = 'the row must be an object'; end if;
      if jsonb_typeof(r -> 'item_id') is distinct from 'string' or (r ->> 'item_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception using errcode = '22023', message = 'the row needs an item_id'; end if;
      v_item := (r ->> 'item_id')::uuid;
      select i.property_id into v_prop from public.inventory_items i where i.id = v_item;
      if v_prop is distinct from p_property_id then raise exception using errcode = '22023', message = 'the item is not in this property'; end if;
      if p_mode in ('count', 'bought') and v_item = any (v_seen) then raise exception using errcode = '22023', message = 'the same item is listed twice'; end if;
      v_seen := v_seen || v_item;
      v_key := public.s_inventory_derive_key_v1(p_idempotency_key, v_idx::text);
      v_note := left(nullif(btrim(coalesce(r ->> 'note', '')), ''), 200);
      if p_mode = 'count' then
        if jsonb_typeof(r -> 'qty') is distinct from 'number' then raise exception using errcode = '22023', message = 'the row needs a qty'; end if;
        v_res := public.reconcile_inventory_baseline_v1(v_item, (r ->> 'qty')::numeric, coalesce(v_note, 'Counted in a group update'), v_key);
      elsif p_mode = 'used' then
        if jsonb_typeof(r -> 'qty') is distinct from 'number' then raise exception using errcode = '22023', message = 'the row needs a qty'; end if;
        v_oid := null;
        if r -> 'option_id' is not null and jsonb_typeof(r -> 'option_id') <> 'null' then
          if jsonb_typeof(r -> 'option_id') <> 'string' or (r ->> 'option_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception using errcode = '22023', message = 'option does not belong to this item'; end if;
          v_oid := (r ->> 'option_id')::uuid;
        end if;
        v_res := public.inventory_option_use_v1(p_property_id, v_item, v_oid, (r ->> 'qty')::numeric, v_note, public.manila_today(), v_key);
      else
        v_tp := null; v_sup := null;
        if r -> 'total_paid' is not null and jsonb_typeof(r -> 'total_paid') <> 'null' then
          if jsonb_typeof(r -> 'total_paid') <> 'number' then raise exception using errcode = '22023', message = 'total paid must be a number'; end if;
          v_tp := (r ->> 'total_paid')::numeric;
        end if;
        if r -> 'supplier_id' is not null and jsonb_typeof(r -> 'supplier_id') <> 'null' then
          if jsonb_typeof(r -> 'supplier_id') <> 'string' or (r ->> 'supplier_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception using errcode = '22023', message = 'supplier must be an id'; end if;
          v_sup := (r ->> 'supplier_id')::uuid;
        end if;
        v_res := public.inventory_receipt_lines_v1(v_item, r -> 'lines', v_tp, public.manila_today(), v_sup, v_key);
      end if;
      if (v_res ->> 'ok') = 'false' then raise exception using errcode = '22023', message = coalesce(v_res ->> 'error', v_res ->> 'reason', 'the row was not saved'); end if;
    exception when others then
      raise exception using errcode = sqlstate, message = 'row ' || v_idx || ': ' || sqlerrm;
    end;
    v_out := v_out || jsonb_build_object('idx', v_idx, 'item_id', v_item, 'result', v_res);
  end loop;
  return jsonb_build_object('ok', true, 'mode', p_mode, 'rows', v_out);
end;
$$;

-- 10. inventory_item_history_v2 (contract 2b) ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- The v1 body (inventory_item_history_v1, untouched) with one more column through its union (pid, the purchase id of a purchase-only row) and one more key on a receipt row: option_title, the title of the brand that line was for.
create or replace function public.inventory_item_history_v2(p_item_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_prop uuid; v_fin boolean; v_c30 integer; v_c14 integer; v_used numeric; v_changes jsonb; v_last jsonb;
begin
  select i.property_id into v_prop from public.inventory_items i where i.id = p_item_id;
  if not found then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  perform public.admin_require('read_operations', v_prop);
  v_fin := public.finance_human_authorized(v_prop);
  select count(*)::integer, (count(*) filter (where cs.cleaned_at >= now() - interval '14 days'))::integer into v_c30, v_c14
  from public.cleaning_sessions cs
  where cs.property_id = v_prop and cs.cleaning_type in ('turnover', 'deep_clean') and cs.cleaned_at >= now() - interval '30 days';
  select coalesce(sum(u.used_qty), 0) into v_used from public.inventory_usage u where u.item_id = p_item_id and u.session_date >= public.manila_today() - 30;
  -- S124: movement rows keep their old shape; a change row is {at, kind: details|price|photo, who, fields}. Price amounts only for finance; photo fields are {}.
  -- S132: every row also carries note (the words typed with it; staff_redact_v1 for anyone without finance) and source ('count','usage','receipt','damage','linen','edit'); rows that were not in the list
  -- before (a usage line, a receipt, a damage report, a linen report) join it, each only when no stock movement already shows it; a row of a few kinds carries qty. A damage or linen movement is shown by its report row.
  select coalesce(jsonb_agg((case when x.fields is not null then jsonb_build_object('at', x.ts, 'kind', x.kind, 'who', x.who, 'fields', x.fields)
                                  else jsonb_build_object('at', x.ts, 'kind', x.kind, 'before', x.qb, 'after', x.qa, 'who', x.who) end)
                            || jsonb_build_object('note', case when x.note is null then null when v_fin then x.note else public.staff_redact_v1(x.note) end, 'source', x.src)
                            || case when x.qty is not null then jsonb_build_object('qty', x.qty) else '{}'::jsonb end || case when x.otitle is not null then jsonb_build_object('option_title', x.otitle) else '{}'::jsonb end
                            order by x.ts desc), '[]'::jsonb) into v_changes
  from (
    select y.ts, y.kind, y.qb, y.qa, y.who, y.fields, y.src, y.qty, y.otitle,
           coalesce(y.note,
             case y.mkind
               when 'usage' then (select nullif(btrim(regexp_replace(coalesce(u2.notes, ''), '\s*\[key:[^]]*\]', '', 'g')), '') from public.inventory_usage u2
                                   where u2.item_id = p_item_id and y.mk = left('evt-' || encode(extensions.digest('inventory_usage|' || u2.id::text || '|' || u2.item_id::text || '|usage', 'sha256'), 'hex'), 80) limit 1)
               when 'receipt' then (select public.s_inventory_purchase_note_v1(p2.notes) from public.inventory_purchases p2
                                     where p2.item_id = p_item_id and y.mk = left('evt-' || encode(extensions.digest('inventory_purchases|' || p2.id::text || '|' || p2.item_id::text || '|receipt', 'sha256'), 'hex'), 80) limit 1)
               when 'reconcile' then nullif(btrim(substring(y.rsn from '^Baseline count: (.*)$')), '')
             end) as note
    from (
      select * from (
        select m.created_at as ts,
               case when m.kind = 'adjustment' and m.reason like 'Undo in the staff app%' then 'undo' when m.kind = 'reconcile' then 'counted'
                    when m.kind = 'receipt' then 'received' when m.kind = 'usage' then 'used' else 'adjusted' end as kind,
               m.quantity_before as qb, m.quantity_after as qa,
               (select public.staff_redact_v1(split_part(btrim(coalesce(nullif(btrim(au.raw_app_meta_data ->> 'display_name'), ''), nullif(btrim(au.raw_user_meta_data ->> 'display_name'), ''),
                         initcap(replace(split_part(coalesce(au.email, ''), '@', 1), '.', ' ')))), ' ', 1)) from auth.users au where au.id = m.actor_user_id) as who,
               null::jsonb as fields,
               case when m.kind = 'reconcile' then 'count' when m.kind = 'receipt' then 'receipt' when m.kind = 'usage' or m.reason like 'Undo usage%' then 'usage' else 'edit' end as src,
               null::numeric as qty, null::text as note, m.kind as mkind, m.reason as rsn, m.idempotency_key as mk, (select op.title from public.inventory_purchases pq join public.inventory_item_options op on op.id = pq.option_id where pq.item_id = m.item_id and m.kind = 'receipt' and m.idempotency_key = left('evt-' || encode(extensions.digest('inventory_purchases|' || pq.id::text || '|' || pq.item_id::text || '|receipt', 'sha256'), 'hex'), 80) limit 1) as otitle
        from public.inventory_stock_movements m
        where m.item_id = p_item_id
          and not (m.kind = 'adjustment' and (m.reason like 'Damage %' or m.reason like 'Undo damage %' or m.reason like 'Linen %' or m.reason like 'Undo linen %'))
        union all
        select a.created_at, 'telegram_count', (a.before ->> 'qty_on_hand')::numeric, (a.after ->> 'qty_on_hand')::numeric, null::text, null::jsonb, 'count', null::numeric, null::text, null::text, null::text, null::text, null::text
        from public.inventory_audit_log a where a.entity_type = 'inventory_items' and a.entity_id = p_item_id and a.action = 'telegram_count'
        union all
        select c.created_at, c.kind, null::numeric, null::numeric, public.s_inventory_actor_name_v1(c.actor),
               case when c.kind = 'details' or (c.kind = 'price' and v_fin)
                    then (select coalesce(jsonb_object_agg(k.key, jsonb_build_object('before', c.before -> k.key, 'after', c.after -> k.key)), '{}'::jsonb) from jsonb_object_keys(c.after) as k(key))
                    else '{}'::jsonb end,
               'edit', null::numeric, null::text, null::text, null::text, null::text, null::text
        from public.inventory_item_changes c where c.item_id = p_item_id and c.undone_at is null
        union all
        (select ub.created_at, 'used', null::numeric, null::numeric, public.s_inventory_actor_name_v1(ub.submitted_by_user_id), null::jsonb, 'usage', ub.used_qty,
                nullif(btrim(regexp_replace(coalesce(ub.notes, ''), '\s*\[key:[^]]*\]', '', 'g')), ''), null::text, null::text, null::text, null::text
           from public.inventory_usage ub
          where ub.item_id = p_item_id and ub.undone_at is null
            and not exists (select 1 from public.inventory_stock_movements m2 where m2.item_id = ub.item_id
                              and m2.idempotency_key = left('evt-' || encode(extensions.digest('inventory_usage|' || ub.id::text || '|' || ub.item_id::text || '|usage', 'sha256'), 'hex'), 80))
          order by ub.created_at desc limit 10)
        union all
        (select pb.created_at, 'received', null::numeric, null::numeric, null::text, null::jsonb, 'receipt', pb.qty, public.s_inventory_purchase_note_v1(pb.notes), null::text, null::text, null::text, (select op.title from public.inventory_item_options op where op.id = pb.option_id)
           from public.inventory_purchases pb
          where pb.item_id = p_item_id
            and not exists (select 1 from public.inventory_stock_movements m3 where m3.item_id = pb.item_id
                              and m3.idempotency_key = left('evt-' || encode(extensions.digest('inventory_purchases|' || pb.id::text || '|' || pb.item_id::text || '|receipt', 'sha256'), 'hex'), 80))
          order by pb.created_at desc limit 10)
        union all
        (select r.created_at, e.value ->> 'reason', (e.value ->> 'before')::numeric, (e.value ->> 'after')::numeric, public.s_inventory_actor_name_v1(r.actor_user_id), null::jsonb, 'damage',
                (e.value ->> 'qty')::numeric, coalesce(nullif(e.value ->> 'note', ''), r.note), null::text, null::text, null::text, null::text
           from public.inventory_damage_reports r cross join lateral jsonb_array_elements(r.rows) e(value)
          where r.property_id = v_prop and r.undone_at is null and e.value ->> 'item_id' = p_item_id::text
          order by r.created_at desc limit 10)
        union all
        (select l.created_at, case when l.outcome = 'cleaned' then 'cleaned' else coalesce(l.reason, 'stained') end, l.stock_before, l.stock_after, public.s_inventory_actor_name_v1(l.reported_by_user_id), null::jsonb, 'linen', l.qty::numeric, l.note,
                null::text, null::text, null::text, null::text
           from public.linen_stain_reports l
          where l.item_id = p_item_id and l.undone_at is null
          order by l.created_at desc limit 10)
      ) u order by u.ts desc limit 10
    ) y
  ) x;
  select jsonb_build_object('at', p.purchased_at, 'qty', p.qty) || case when v_fin then jsonb_build_object('unit_cost', p.unit_cost) else '{}'::jsonb end into v_last
  from public.inventory_purchases p where p.item_id = p_item_id order by p.purchased_at desc, p.created_at desc limit 1;
  return jsonb_build_object('ok', true,
    'usage', jsonb_build_object('cleans_30d', v_c30, 'used_30d', v_used, 'per_clean', case when v_c30 > 0 then round(v_used / v_c30, 2) end, 'cleans_14d', v_c14),
    'changes', v_changes, 'last_bought', v_last);
end;
$$;
revoke all on function public.inventory_item_history_v2(uuid) from public, anon, authenticated, service_role;


-- 12. inventory_log_v1 (contract 5): the whole-inventory history, read only ------------------------------------------------------------------------------------------------------------------------------------------
-- Sources: stock movements (count, bought, used, undo, other adjustments; a damage movement is shown by its report), purchases and usage rows that wrote NO stock movement (a not-controlled item: its bought and used rows
-- exist only in inventory_purchases / inventory_usage, as inventory_item_history_v2 shows them; an undone usage keeps its row with undone_at), damage reports (one row per item line, undone ones kept with undone_at), item
-- changes (created, details, price, photo; undone ones kept with undone_at), stock moves between items (inventory_audit_log). Option edits keep no history table, so none is shown. The brand of a bought row is the title of
-- the option on its purchase. Money: a bought row carries {unit_cost,total_cost} and a price change {before,after} only for finance_human_authorized; everyone else gets money null. group_key is set only for a key made by
-- s_inventory_derive_key_v1 (it ends in ':g<n>' one or more times), so rows written by one group call share it and an unrelated single-call key never does. Paging is by time alone (the cursor is p_before): newest first
-- reads rows older than it, oldest first rows newer than it. A page never ends inside a run of rows with the same timestamp (the run is finished), so no row is skipped or repeated; a page can therefore hold a few more than
-- p_limit rows. next_before is null on the last page. Cost: the evt- key of a purchase or a usage row is hashed once per row in the page window (purchases and usage are bounded by p_item_id, p_kind and the cursor, with a one-day
-- slack for the movement written beside them) and joined to the movements by key; the movement scan uses inventory_stock_movements_property_created_idx.
create index if not exists inventory_stock_movements_property_created_idx on public.inventory_stock_movements (property_id, created_at desc);

create or replace function public.inventory_log_v1(p_property_id uuid, p_before timestamptz default null, p_limit integer default 50, p_kind text default null, p_item_id uuid default null, p_oldest_first boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_fin boolean; v_lim integer := least(greatest(coalesce(p_limit, 50), 1), 100); v_hi timestamptz; v_lo timestamptz; v_rows jsonb; v_next timestamptz; v_more boolean; v_old boolean := coalesce(p_oldest_first, false);
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'authentication required'; end if;
  if p_property_id is null then raise exception using errcode = '22023', message = 'property required'; end if;
  if not public.current_staff_authorized('read_operations', p_property_id) then
    if not public.current_staff_authorized('submit_cleaning', p_property_id) then perform public.admin_require('report_supply', p_property_id); end if;
  end if;
  if p_kind is not null and p_kind not in ('count', 'bought', 'used', 'broken', 'edit') then raise exception using errcode = '22023', message = 'kind must be count, bought, used, broken or edit'; end if;
  if p_item_id is not null and not exists (select 1 from public.inventory_items i where i.id = p_item_id and i.property_id = p_property_id) then raise exception using errcode = 'P0002', message = 'item not found'; end if;
  v_fin := public.finance_human_authorized(p_property_id);
  if v_old then v_lo := p_before; else v_hi := p_before; end if;
  with pur as (
    select pu.id, pu.item_id, pu.created_at, pu.option_id, pu.qty, pu.unit_cost, pu.total_cost, pu.notes,
           left('evt-' || encode(extensions.digest('inventory_purchases|' || pu.id::text || '|' || pu.item_id::text || '|receipt', 'sha256'), 'hex'), 80) as ekey
    from public.inventory_purchases pu join public.inventory_items pi on pi.id = pu.item_id and pi.property_id = p_property_id
    where (p_kind is null or p_kind = 'bought') and (p_item_id is null or pu.item_id = p_item_id)
      and (v_hi is null or pu.created_at < v_hi + interval '1 day') and (v_lo is null or pu.created_at > v_lo - interval '1 day')
  ), usg as (
    select us.id, us.item_id, us.created_at, us.used_qty, us.undone_at, us.undone_qty, us.notes, us.submitted_by_user_id,
           left('evt-' || encode(extensions.digest('inventory_usage|' || us.id::text || '|' || us.item_id::text || '|usage', 'sha256'), 'hex'), 80) as ekey
    from public.inventory_usage us join public.inventory_items ui on ui.id = us.item_id and ui.property_id = p_property_id
    where (p_kind is null or p_kind = 'used') and (p_item_id is null or us.item_id = p_item_id)
      and (v_hi is null or us.created_at < v_hi + interval '1 day') and (v_lo is null or us.created_at > v_lo - interval '1 day')
  ), src as (
    -- stock movements (the purchase / usage row beside a receipt / usage movement gives its note, brand, money and undo state)
    select m.created_at as at, m.item_id,
           case when m.kind = 'reconcile' then 'count' when m.kind = 'receipt' then 'bought' when m.kind = 'usage' then 'used'
                when m.reason like 'Undo%' then 'undo' when m.reason like 'Linen %' then 'broken' else 'edit' end as kind,
           m.quantity_before as qb, m.quantity_after as qa, m.actor_user_id as actor,
           case when m.kind = 'reconcile' then nullif(btrim(substring(m.reason from '^Baseline count: (.*)$')), '')
                when m.kind = 'receipt' then public.s_inventory_purchase_note_v1(pu.notes)
                when m.kind = 'usage' then nullif(btrim(regexp_replace(coalesce(us.notes, ''), '\s*\[key:[^]]*\]', '', 'g')), '')
                else nullif(btrim(m.reason), '') end as note,
           case when m.kind = 'receipt' then nullif(regexp_replace(substring(pu.notes from '\[key:([^]]*)\]'), '(:g[0-9]+)+$', ''), substring(pu.notes from '\[key:([^]]*)\]'))
                when m.kind = 'usage' then nullif(regexp_replace(substring(us.notes from '\[key:([^]]*)\]'), '(:g[0-9]+)+$', ''), substring(us.notes from '\[key:([^]]*)\]'))
                when m.idempotency_key like 'evt-%' then null
                else nullif(regexp_replace(m.idempotency_key, '(:g[0-9]+)+$', ''), m.idempotency_key) end as gk,
           op.title as option_title,
           case when m.kind = 'receipt' and v_fin and pu.id is not null then jsonb_build_object('unit_cost', pu.unit_cost, 'total_cost', pu.total_cost) end as money,
           us.undone_at as undone, null::numeric as qty, m.id::text as rid
    from public.inventory_stock_movements m
    left join pur pu on m.kind = 'receipt' and pu.item_id = m.item_id and pu.ekey = m.idempotency_key
    left join public.inventory_item_options op on op.id = pu.option_id
    left join usg us on m.kind = 'usage' and us.item_id = m.item_id and us.ekey = m.idempotency_key
    where m.property_id = p_property_id and (p_item_id is null or m.item_id = p_item_id)
      and (v_hi is null or m.created_at < v_hi) and (v_lo is null or m.created_at > v_lo)
      and not (m.kind = 'adjustment' and (m.reason like 'Damage %' or m.reason like 'Undo damage %'))
      and (p_kind is null or p_kind = 'edit' or (p_kind = 'count' and m.kind = 'reconcile') or (p_kind = 'bought' and m.kind = 'receipt') or (p_kind = 'used' and m.kind = 'usage')
           or (p_kind = 'broken' and m.kind not in ('reconcile', 'receipt', 'usage') and m.reason like 'Linen %'))
    union all
    -- purchases that wrote no stock movement (a not-controlled item)
    select pb.created_at, pb.item_id, 'bought', null::numeric, null::numeric, null::uuid, public.s_inventory_purchase_note_v1(pb.notes),
           nullif(regexp_replace(substring(pb.notes from '\[key:([^]]*)\]'), '(:g[0-9]+)+$', ''), substring(pb.notes from '\[key:([^]]*)\]')),
           ob.title, case when v_fin then jsonb_build_object('unit_cost', pb.unit_cost, 'total_cost', pb.total_cost) end, null::timestamptz, pb.qty, pb.id::text
    from pur pb left join public.inventory_item_options ob on ob.id = pb.option_id
    where (v_hi is null or pb.created_at < v_hi) and (v_lo is null or pb.created_at > v_lo)
      and not exists (select 1 from public.inventory_stock_movements m2 where m2.item_id = pb.item_id and m2.idempotency_key = pb.ekey)
    union all
    -- usage rows that wrote no stock movement (a not-controlled item); an undone one keeps its row with undone_at and the quantity that was logged
    select ub.created_at, ub.item_id, 'used', null::numeric, null::numeric, ub.submitted_by_user_id, nullif(btrim(regexp_replace(coalesce(ub.notes, ''), '\s*\[key:[^]]*\]', '', 'g')), ''),
           nullif(regexp_replace(substring(ub.notes from '\[key:([^]]*)\]'), '(:g[0-9]+)+$', ''), substring(ub.notes from '\[key:([^]]*)\]')),
           null::text, null::jsonb, ub.undone_at, case when ub.undone_at is not null then ub.undone_qty else ub.used_qty end, ub.id::text
    from usg ub
    where (v_hi is null or ub.created_at < v_hi) and (v_lo is null or ub.created_at > v_lo)
      and not exists (select 1 from public.inventory_stock_movements m3 where m3.item_id = ub.item_id and m3.idempotency_key = ub.ekey)
    union all
    -- damage reports, one row per item line
    select r.created_at, (e.value ->> 'item_id')::uuid, 'broken', (e.value ->> 'before')::numeric, (e.value ->> 'after')::numeric, r.actor_user_id,
           coalesce(nullif(e.value ->> 'note', ''), r.note), null::text, null::text, null::jsonb, r.undone_at, (e.value ->> 'qty')::numeric, r.id::text || ':' || e.ord
    from public.inventory_damage_reports r cross join lateral jsonb_array_elements(r.rows) with ordinality e(value, ord)
    where (p_kind is null or p_kind = 'broken') and r.property_id = p_property_id and (p_item_id is null or e.value ->> 'item_id' = p_item_id::text)
      and (v_hi is null or r.created_at < v_hi) and (v_lo is null or r.created_at > v_lo)
    union all
    -- item changes
    select c.created_at, c.item_id, case when c.kind = 'created' then 'created' else 'edit' end, null::numeric, null::numeric, c.actor,
           null::text, null::text, null::text,
           case when c.kind = 'price' and v_fin then jsonb_build_object('before', (c.before ->> 'unit_cost')::numeric, 'after', (c.after ->> 'unit_cost')::numeric) end, c.undone_at, null::numeric, c.id::text
    from public.inventory_item_changes c
    where (p_kind is null or p_kind = 'edit') and c.property_id = p_property_id and (p_item_id is null or c.item_id = p_item_id)
      and (v_hi is null or c.created_at < v_hi) and (v_lo is null or c.created_at > v_lo)
    union all
    -- stock moved between items
    select a.created_at, a.entity_id, 'moved', (a.before ->> 'qty_on_hand')::numeric, (a.after ->> 'qty_on_hand')::numeric,
           case when a.actor ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then a.actor::uuid end,
           case when a.action = 'stock_moved_out' then 'to ' else 'from ' end || coalesce(a.after ->> 'other_item_name', 'another item'), null::text, null::text, null::jsonb, null::timestamptz, null::numeric, a.id::text
    from public.inventory_audit_log a join public.inventory_items mi on mi.id = a.entity_id and mi.property_id = p_property_id
    where (p_kind is null or p_kind = 'edit') and a.entity_type = 'inventory_items' and a.action in ('stock_moved_out', 'stock_moved_in') and (p_item_id is null or a.entity_id = p_item_id)
      and (v_hi is null or a.created_at < v_hi) and (v_lo is null or a.created_at > v_lo)
  ), shown as (
    select s.*, i.name as item_name, i.unit as unit,
           row_number() over (order by case when v_old then s.at end asc, case when not v_old then s.at end desc, s.rid) as rn
    from src s join public.inventory_items i on i.id = s.item_id and i.property_id = p_property_id
    where p_kind is null or case when p_kind = 'edit' then s.kind in ('edit', 'created', 'moved', 'product', 'undo') else s.kind = p_kind end
  ), cut as (select max(x.at) as at from shown x where x.rn = v_lim)
  select coalesce(jsonb_agg(jsonb_build_object(
      'at', p.at, 'kind', p.kind, 'item_id', p.item_id, 'item_name', p.item_name,
      'summary_parts', (select coalesce(jsonb_agg(t.part order by t.n), '[]'::jsonb) from (values
          (1, case p.kind when 'count' then 'Counted' when 'bought' then 'Bought' when 'used' then 'Used' when 'broken' then 'Broken or missing' when 'moved' then 'Moved' when 'created' then 'Added' when 'undo' then 'Undone' else 'Edited' end),
          (2, case when p.qty is not null then trim_scale(round(p.qty, 2))::text || ' ' || coalesce(p.unit, '')
                   when p.qb is not null and p.qa is not null then trim_scale(round(p.qb, 2))::text || ' to ' || trim_scale(round(p.qa, 2))::text end),
          (3, p.option_title), (4, case when p.kind = 'moved' then p.note end)) t(n, part) where t.part is not null),
      'qty_before', p.qb, 'qty_after', p.qa, 'delta', case when p.qb is not null and p.qa is not null then p.qa - p.qb end, 'unit', p.unit, 'option_title', p.option_title,
      'money', p.money, 'actor_first_name', public.s_inventory_actor_name_v1(p.actor),
      'source_note', case when p.note is null then null when v_fin then p.note else public.staff_redact_v1(p.note) end,
      'undone_at', p.undone, 'undone_by_first_name', null, 'group_key', p.gk)
      order by case when v_old then p.at end asc, case when not v_old then p.at end desc, p.rid), '[]'::jsonb),
    exists (select 1 from shown x where x.rn > v_lim and x.at is distinct from (select c.at from cut c)),
    (select c.at from cut c)
  into v_rows, v_more, v_next
  from shown p where p.rn <= v_lim or p.at = (select c.at from cut c);
  return jsonb_build_object('rows', v_rows, 'next_before', case when v_more then v_next end);
end;
$$;
revoke all on function public.inventory_log_v1(uuid, timestamptz, integer, text, uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.inventory_log_v1(uuid, timestamptz, integer, text, uuid, boolean) to authenticated;

-- 11. grants (ML-21): authenticated only ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.inventory_option_count_v1(uuid, jsonb, numeric, text, text) from public, anon, authenticated, service_role;
grant execute on function public.inventory_option_count_v1(uuid, jsonb, numeric, text, text) to authenticated;
revoke all on function public.inventory_receipt_lines_v1(uuid, jsonb, numeric, date, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.inventory_receipt_lines_v1(uuid, jsonb, numeric, date, uuid, text) to authenticated;
revoke all on function public.inventory_option_use_v1(uuid, uuid, uuid, numeric, text, date, text) from public, anon, authenticated, service_role;
grant execute on function public.inventory_option_use_v1(uuid, uuid, uuid, numeric, text, date, text) to authenticated;
revoke all on function public.inventory_group_update_v1(uuid, text, jsonb, text) from public, anon, authenticated, service_role;
grant execute on function public.inventory_group_update_v1(uuid, text, jsonb, text) to authenticated;
revoke all on function public.inventory_item_history_v2(uuid) from public, anon, authenticated, service_role;
grant execute on function public.inventory_item_history_v2(uuid) to authenticated;

commit;
