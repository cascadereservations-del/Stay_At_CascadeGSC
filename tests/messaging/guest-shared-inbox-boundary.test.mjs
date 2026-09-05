import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const sql = readFileSync(fileURLToPath(new URL('../../supabase/migrations/20260905040000_guest_shared_inbox.sql',import.meta.url)),'utf8');

test('Wave 2 stores encrypted bodies and redacted previews',()=>{
  assert.match(sql,/body_ciphertext text not null/i);
  assert.match(sql,/preview_redacted[\s\S]*!~\*/i);
  assert.doesNotMatch(sql,/\bbody_plaintext\b|\bguest_email\b|\bguest_phone\b/i);
});

test('all risky topics deterministically escalate',()=>{
  for(const risk of ['payment','refund','cancellation','complaint','safety','access','policy_exception','uncertain']) {
    assert.match(sql,new RegExp(`'${risk}'`));
  }
  assert.match(sql,/p_risk_code<>'routine'[\s\S]*status='escalated'/i);
});

test('assistant output remains a draft and human review never sends',()=>{
  assert.match(sql,/proposed_by text not null check\(proposed_by in \('assistant','staff'\)\)/i);
  assert.match(sql,/send_authorized',false/i);
  assert.doesNotMatch(sql,/insert into public\.automation_outbox|fetch\s*\(|provider_message_id|send_message/i);
});

test('OPS and service identities cannot approve or read the inbox',()=>{
  const cleaner = sql.match(/when p_role='cleaner'[\s\S]*?when p_role='maintenance'/i)?.[0] ?? '';
  assert.doesNotMatch(cleaner,/manage_guest_inbox|read_finance/i);
  assert.match(sql,/revoke all on public\.guest_conversations[\s\S]*service_role/i);
  assert.match(sql,/review_guest_reply_draft[\s\S]*revoke all[\s\S]*service_role/i);
});
