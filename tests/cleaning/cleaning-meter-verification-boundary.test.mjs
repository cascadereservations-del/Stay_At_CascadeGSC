import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
const sql=readFileSync(fileURLToPath(new URL('../../supabase/migrations/20260905050000_cleaning_meter_verification.sql',import.meta.url)),'utf8');
test('Wave 3 keeps evidence private and advisory',()=>{
 assert.match(sql,/advisory_result[\s\S]*uncertain[\s\S]*unavailable/i);
 assert.match(sql,/revoke all on public\.cleaning_verification_evidence[\s\S]*service_role/i);
 assert.doesNotMatch(sql,/guest_email|guest_phone|total_amount|deposit_amount|bank|receipt/i);
});
test('named humans own submission review and override',()=>{
 assert.match(sql,/submitted_by_user_id is distinct from auth\.uid\(\)/i);
 assert.match(sql,/reviewer_user_id,?outcome/i);
 assert.match(sql,/p_outcome='overridden'[\s\S]*manage_operations/i);
 assert.doesNotMatch(sql,/automation_outbox|fetch\s*\(/i);
});
