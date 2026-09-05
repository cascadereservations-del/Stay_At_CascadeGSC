import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const read = path => readFileSync(new URL(path,import.meta.url),'utf8');
const sql=read('../../supabase/migrations/20260905070000_finance_reconciliation_analytics.sql');

test('Finance candidates are advisory and named AAL2 review creates facts',()=>{
  assert.match(sql,/current_staff_authorized\('read_finance',p_property_id\)/);
  assert.match(sql,/advisory_only boolean not null default true check\(advisory_only\)/);
  assert.match(sql,/reviewer_user_id uuid not null references auth.users/);
  assert.match(sql,/if p_outcome='approved'[\s\S]*insert into public.finance_reconciled_facts/);
  assert.match(sql,/comparison_outcome in \('missing_fields','duplicate_source'\)/);
});

test('OPS and integrations cannot browse or mutate Finance facts',()=>{
  assert.match(sql,/revoke all on public.finance_reconciliation_candidates[\s\S]*authenticated,service_role/);
  assert.match(sql,/create policy finance_facts_read[\s\S]*finance_human_authorized\(property_id\)/);
  assert.doesNotMatch(sql,/grant (?:all|insert|update|delete)/i);
  assert.match(sql,/revoke all on function public.review_finance_reconciliation[^;]*service_role/);
  assert.doesNotMatch(sql,/guest_email|guest_phone|receipt_image_path|bank_account/i);
});

test('management formulas use reconciled facts and disclose their limits',()=>{
  assert.match(sql,/from public.finance_reconciled_facts/);
  for(const formula of ['operating_profit','cost_per_available_night','cost_per_occupied_night','adr','revpar','occupancy_pct']) assert.match(sql,new RegExp(`'${formula}'`));
  assert.match(sql,/'internal_management_only',true,'statutory_or_tax_compliance',false/);
  assert.match(sql,/tax','owner_drawings','depreciation','debt/);
  assert.match(sql,/'data_freshness',v_fresh,'targets',v_targets/);
});

test('targets are effective-dated, owner-approved, serialized, and idempotent',()=>{
  assert.match(sql,/p\.role='owner'[\s\S]*auth\.jwt\(\)->>'aal'='aal2'/);
  assert.match(sql,/target effective dates overlap/);
  assert.match(sql,/pg_advisory_xact_lock\(hashtextextended\('cascade-management-target:/);
  assert.match(sql,/target idempotency conflict/);
});

test('rollback is bounded to Wave 5 objects',()=>{
  const rollback=read('../../supabase/rollbacks/20260905070000_finance_reconciliation_analytics.sql');
  assert.doesNotMatch(rollback,/\bcascade\b|drop table public\.transactions|drop table public\.booking/i);
  for(const name of ['finance_reconciliation_candidates','finance_reconciliation_reviews','finance_reconciled_facts','management_target_versions']) assert.match(rollback,new RegExp(`drop table public.${name}`));
});
