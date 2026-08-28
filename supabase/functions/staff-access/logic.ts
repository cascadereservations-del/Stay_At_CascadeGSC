export type StaffRole = 'owner' | 'admin' | 'finance' | 'inspector' | 'cleaner' | 'maintenance';
export type StaffAction = 'manage_staff' | 'approve_payment' | 'read_finance' | 'inspect_cleaning' | 'submit_cleaning' | 'manage_maintenance';

const PERMISSIONS: Record<StaffRole, readonly StaffAction[]> = {
  owner: ['manage_staff', 'approve_payment', 'read_finance', 'inspect_cleaning', 'submit_cleaning', 'manage_maintenance'],
  admin: ['manage_staff', 'approve_payment', 'read_finance', 'inspect_cleaning', 'submit_cleaning', 'manage_maintenance'],
  finance: ['approve_payment', 'read_finance'],
  inspector: ['inspect_cleaning'],
  cleaner: ['submit_cleaning'],
  maintenance: ['manage_maintenance'],
};

const MFA_REQUIRED: readonly StaffAction[] = ['manage_staff', 'approve_payment', 'read_finance'];

export function staffActionAllowed(
  role: StaffRole,
  action: StaffAction,
  disabledAt: string | null,
  assuranceLevel: string | null,
): boolean {
  if (disabledAt) return false;
  if (!PERMISSIONS[role].includes(action)) return false;
  return !MFA_REQUIRED.includes(action) || assuranceLevel === 'aal2';
}

export function mayManageTarget(actor: StaffRole, target: StaffRole): boolean {
  return (actor === 'owner' || actor === 'admin')
    && !(actor === 'admin' && target === 'owner');
}
