import { mayManageTarget, staffActionAllowed } from './logic.ts';

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
  equal(staffActionAllowed('admin', 'approve_payment', null, 'aal1'), false, 'MFA required');
  equal(staffActionAllowed('admin', 'approve_payment', null, 'aal2'), true, 'admin with MFA');
});

Deno.test('admin cannot manage owner access', () => {
  equal(mayManageTarget('admin', 'owner'), false, 'admin owner boundary');
  equal(mayManageTarget('owner', 'admin'), true, 'owner admin management');
});
