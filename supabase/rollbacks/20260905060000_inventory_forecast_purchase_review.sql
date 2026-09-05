-- Local compensating rollback. Export/review audit records before any approved release rollback.
-- Does not reverse physical stock facts recorded while installed. No legacy objects/grants changed.
begin;
drop function public.review_inventory_purchase(uuid,text,numeric,text,text);
drop function public.forecast_inventory(uuid,integer,integer,text);
drop function public.record_inventory_movement(uuid,text,numeric,text,text);
drop table public.inventory_purchase_reviews;
drop table public.inventory_forecasts;
drop table public.inventory_stock_movements;
drop function public.inventory_human_authorized(uuid);
commit;
