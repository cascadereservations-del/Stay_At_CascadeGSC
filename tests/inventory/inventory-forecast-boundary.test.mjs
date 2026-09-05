import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const read = path => readFileSync(new URL(path,import.meta.url),'utf8');
const sql=read('../../supabase/migrations/20260905060000_inventory_forecast_purchase_review.sql');
test('purchase authority is named, property scoped, MFA-backed owner/admin',()=>{
 assert.match(sql,/p\.user_id=auth\.uid\(\)[\s\S]*p\.role in \('owner','admin'\)[\s\S]*auth\.jwt\(\)->>'aal'='aal2'/);
 assert.match(sql,/sessions_revoked_after[\s\S]*staff_property_access[\s\S]*s\.property_id=p_property_id/);
 assert.match(sql,/reviewer_user_id[\s\S]*references auth.users/);
 assert.match(sql,/revoke all on function public.review_inventory_purchase[^;]*from public,anon,service_role/);
});
test('private tables have no direct mutation or service grants',()=>{
 for(const name of ['inventory_stock_movements','inventory_forecasts','inventory_purchase_reviews']) {
 assert.match(sql,new RegExp(`alter table public.${name} enable row level security`));
 assert.match(sql,new RegExp(`on public.${name} for select to authenticated using\\(public.inventory_human_authorized`));
 }
 assert.match(sql,/revoke all on public.inventory_stock_movements[^;]*authenticated,service_role/);
 assert.doesNotMatch(sql,/grant (?:all|insert|update|delete)/i);
});
test('advisory review cannot execute orders or financial state changes',()=>{
 assert.match(sql,/advisory_only boolean not null default true check\(advisory_only\)/);
 assert.match(sql,/order_authorized boolean not null default false check\(not order_authorized\)/);
 assert.doesNotMatch(sql,/automation_outbox|net\.http|http_post|fetch\s*\(|\b(?:insert into|update) public\.(?:transactions|inventory_purchases|booking_inquiries)/i);
});
test('reconciliation and review serialize on canonical item and reject drift',()=>{
 assert.equal((sql.match(/from public.inventory_items where id=.*for update/g)||[]).length,3);
 assert.match(sql,/stock reconciliation required/);
 assert.match(sql,/v_movement is distinct from f.movement_id/);
 assert.match(sql,/interval '24 hours'/);
 assert.match(sql,/idempotency conflict/);
 assert.match(sql,/review conflict/);
 assert.match(sql,/p_quantity <> round\(p_quantity,2\)/);
 assert.equal((sql.match(/idempotency_key text not null unique/g)||[]).length,3);
});
test('rollback removes only Wave 4 objects without cascade',()=>{
 const rollback=read('../../supabase/rollbacks/20260905060000_inventory_forecast_purchase_review.sql');
 assert.doesNotMatch(rollback,/\bcascade\b|drop table.*public.inventory_items/i);
 for(const name of ['inventory_stock_movements','inventory_forecasts','inventory_purchase_reviews']) assert.match(rollback,new RegExp(`drop table public.${name}`));
});
