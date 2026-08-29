import {
  managementDecision,
  mayManageTarget,
  propertyScopeAllowed,
  sessionIsCurrent,
  staffActionAllowed,
  type StaffProfile,
} from './logic.ts';
import { parseManagementRequest } from './validation.ts';
import { handleStaffAccessRequest, type StaffAccessDependencies } from './handler.ts';

function equal(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`);
}

Deno.test('disabled cleaner cannot submit a cleaning report', () => {
  equal(staffActionAllowed('cleaner', 'submit_cleaning', '2026-08-28T00:00:00Z', 'aal1'), false, 'disabled cleaner');
});

Deno.test('inspector cannot approve payment and finance cannot manage staff', () => {
  equal(staffActionAllowed('inspector', 'approve_payment', null, 'aal2'), false, 'inspector payment');
  equal(staffActionAllowed('finance', 'manage_staff', null, 'aal2'), false, 'finance role management');
});

Deno.test('payment approval requires MFA and an authorized role', () => {
  equal(staffActionAllowed('admin', 'approve_payment', null, null), false, 'missing assurance level');
  equal(staffActionAllowed('admin', 'approve_payment', null, 'aal1'), false, 'MFA required');
  equal(staffActionAllowed('admin', 'approve_payment', null, 'aal2'), true, 'admin with MFA');
});

Deno.test('non-owner actions require an explicit property within staff scope', () => {
  equal(propertyScopeAllowed('finance', 'read_finance', ['property-a'], null), false, 'missing property context');
  equal(propertyScopeAllowed('cleaner', 'submit_cleaning', ['property-a'], 'property-b'), false, 'out-of-scope property');
  equal(propertyScopeAllowed('cleaner', 'submit_cleaning', ['property-a'], 'property-a'), true, 'assigned property');
  equal(propertyScopeAllowed('owner', 'read_finance', [], null), true, 'owner global access');
});

Deno.test('admin cannot manage owner access', () => {
  equal(mayManageTarget('admin', 'owner'), false, 'admin owner boundary');
  equal(mayManageTarget('owner', 'admin'), true, 'owner admin management');
});

const actor = (overrides: Partial<StaffProfile> = {}): StaffProfile => ({
  user_id: 'actor',
  role: 'admin',
  property_ids: ['property-a'],
  disabled_at: null,
  sessions_revoked_after: null,
  ...overrides,
});

Deno.test('tokens issued before session revocation are rejected', () => {
  equal(sessionIsCurrent(100, '1970-01-01T00:02:00.000Z'), false, 'stale token');
  equal(sessionIsCurrent(121, '1970-01-01T00:02:00.000Z'), true, 'fresh token');
});

Deno.test('admin cannot grant a property outside their own scope', () => {
  const result = managementDecision(actor(), 'target', 'cleaner', ['property-b'], 'aal2', 200);
  equal(result.ok, false, 'out-of-scope grant');
  equal(result.error, 'property_scope_denied', 'error code');
});

Deno.test('privileged management requires MFA and a current session', () => {
  equal(managementDecision(actor(), 'target', 'cleaner', ['property-a'], 'aal1', 200).error, 'mfa_required', 'MFA');
  equal(managementDecision(actor({ sessions_revoked_after: '1970-01-01T00:05:00Z' }), 'target', 'cleaner', ['property-a'], 'aal2', 200).error, 'session_revoked', 'revocation');
});

Deno.test('staff cannot disable or change their own authority', () => {
  equal(managementDecision(actor(), 'actor', 'admin', ['property-a'], 'aal2', 200).error, 'self_management_denied', 'self management');
});

Deno.test('owner may grant a scoped role with MFA', () => {
  const result = managementDecision(actor({ role: 'owner', property_ids: [] }), 'target', 'finance', ['property-b'], 'aal2', 200);
  equal(result.ok, true, 'owner decision');
});

Deno.test('staff management request accepts a complete scoped upsert', () => {
  const parsed = parseManagementRequest({
    target_user_id: '11111111-1111-4111-8111-111111111111',
    action: 'upsert',
    role: 'cleaner',
    property_ids: ['22222222-2222-4222-8222-222222222222'],
    reason: 'New cleaner onboarding',
  });
  equal(parsed.ok, true, 'valid request');
  if (parsed.ok) equal(parsed.value.reason, 'New cleaner onboarding', 'trimmed reason');
});

Deno.test('staff management request rejects invalid identifiers and actions', () => {
  equal(parseManagementRequest({ target_user_id: 'not-a-uuid', action: 'disable', reason: 'Offboarding' }).ok, false, 'target UUID');
  equal(parseManagementRequest({ target_user_id: '11111111-1111-4111-8111-111111111111', action: 'delete', reason: 'Offboarding' }).ok, false, 'action allowlist');
});

Deno.test('upsert requires a valid role and property scope', () => {
  const target = '11111111-1111-4111-8111-111111111111';
  equal(parseManagementRequest({ target_user_id: target, action: 'upsert', role: 'superuser', property_ids: [], reason: 'Role change' }).ok, false, 'role allowlist');
  equal(parseManagementRequest({ target_user_id: target, action: 'upsert', role: 'cleaner', property_ids: [], reason: 'Role change' }).ok, false, 'property scope');
});

Deno.test('staff management reason is required and bounded', () => {
  const target = '11111111-1111-4111-8111-111111111111';
  equal(parseManagementRequest({ target_user_id: target, action: 'disable', reason: '  ' }).ok, false, 'blank reason');
  equal(parseManagementRequest({ target_user_id: target, action: 'disable', reason: 'x'.repeat(501) }).ok, false, 'long reason');
});

const dependencies = (overrides: Partial<StaffAccessDependencies> = {}): StaffAccessDependencies => ({
  verifyUser: async () => true,
  currentAccess: async () => ({ data: { role: 'owner', property_ids: [], disabled: false, session_current: true }, errorCode: null }),
  manageAccess: async () => ({ data: { ok: true }, errorCode: null }),
  ...overrides,
});

Deno.test('staff endpoint rejects a missing or invalid bearer session', async () => {
  const missing = await handleStaffAccessRequest(new Request('https://example.test/staff-access'), dependencies());
  equal(missing.status, 401, 'missing bearer');
  const invalid = await handleStaffAccessRequest(
    new Request('https://example.test/staff-access', { headers: { authorization: 'Bearer invalid' } }),
    dependencies({ verifyUser: async () => false }),
  );
  equal(invalid.status, 401, 'invalid bearer');
});

Deno.test('staff endpoint forwards only validated management parameters', async () => {
  let received: unknown = null;
  const response = await handleStaffAccessRequest(new Request('https://example.test/staff-access', {
    method: 'POST',
    headers: { authorization: 'Bearer verified', 'content-type': 'application/json' },
    body: JSON.stringify({
      target_user_id: '11111111-1111-4111-8111-111111111111',
      action: 'disable',
      role: 'owner',
      property_ids: ['22222222-2222-4222-8222-222222222222'],
      reason: ' Staff offboarding ',
      actor_user_id: '33333333-3333-4333-8333-333333333333',
    }),
  }), dependencies({ manageAccess: async (params) => { received = params; return { data: { ok: true }, errorCode: null }; } }));
  equal(response.status, 200, 'management success');
  equal(JSON.stringify(received), JSON.stringify({
    p_target_user_id: '11111111-1111-4111-8111-111111111111',
    p_action: 'disable',
    p_role: null,
    p_property_ids: null,
    p_reason: 'Staff offboarding',
  }), 'closed RPC payload');
});

Deno.test('staff endpoint returns generic errors for authorization and database failures', async () => {
  const denied = await handleStaffAccessRequest(
    new Request('https://example.test/staff-access', { method: 'POST', headers: { authorization: 'Bearer verified' }, body: '{}' }),
    dependencies(),
  );
  equal(denied.status, 400, 'invalid request');
  const databaseFailure = await handleStaffAccessRequest(
    new Request('https://example.test/staff-access', { headers: { authorization: 'Bearer verified' } }),
    dependencies({ currentAccess: async () => ({ data: null, errorCode: 'unexpected_internal_detail' }) }),
  );
  equal(databaseFailure.status, 503, 'generic database failure');
  equal(await databaseFailure.text(), '{"error":"staff_access_unavailable"}', 'safe response');
  const thrownFailure = await handleStaffAccessRequest(
    new Request('https://example.test/staff-access', { headers: { authorization: 'Bearer verified' } }),
    dependencies({ currentAccess: async () => { throw new Error('sensitive database detail'); } }),
  );
  equal(thrownFailure.status, 503, 'thrown database failure');
  equal(await thrownFailure.text(), '{"error":"staff_access_unavailable"}', 'safe thrown response');
});
