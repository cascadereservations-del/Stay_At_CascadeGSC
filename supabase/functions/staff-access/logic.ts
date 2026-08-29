export type StaffRole = 'owner' | 'admin' | 'finance' | 'inspector' | 'cleaner' | 'maintenance';
export type StaffAction = 'manage_staff' | 'approve_payment' | 'read_finance' | 'inspect_cleaning' | 'submit_cleaning' | 'manage_maintenance';

export type StaffProfile = {
  user_id: string;
  role: StaffRole;
  property_ids: string[];
  disabled_at: string | null;
  sessions_revoked_after: string | null;
};

export type ManagementError = 'staff_disabled' | 'session_revoked' | 'mfa_required' | 'role_denied' | 'self_management_denied' | 'target_role_denied' | 'property_scope_denied';
export type ManagementDecision = { ok: boolean; error: ManagementError | null };

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

export function propertyScopeAllowed(
  role: StaffRole,
  action: StaffAction,
  assignedPropertyIds: string[],
  requestedPropertyId: string | null,
): boolean {
  if (role === 'owner') return true;
  if (action === 'manage_staff') return true;
  return requestedPropertyId !== null && assignedPropertyIds.includes(requestedPropertyId);
}

export function sessionIsCurrent(issuedAtSeconds: number | null, revokedAfter: string | null): boolean {
  if (!revokedAfter) return true;
  if (!Number.isFinite(issuedAtSeconds)) return false;
  const revokedAtMs = Date.parse(revokedAfter);
  return Number.isFinite(revokedAtMs) && Number(issuedAtSeconds) * 1000 > revokedAtMs;
}

export function managementDecision(
  actor: StaffProfile,
  targetUserId: string,
  targetRole: StaffRole,
  requestedPropertyIds: string[],
  assuranceLevel: string | null,
  issuedAtSeconds: number | null,
): ManagementDecision {
  if (actor.disabled_at) return { ok: false, error: 'staff_disabled' };
  if (!sessionIsCurrent(issuedAtSeconds, actor.sessions_revoked_after)) return { ok: false, error: 'session_revoked' };
  if (assuranceLevel !== 'aal2') return { ok: false, error: 'mfa_required' };
  if (actor.role !== 'owner' && actor.role !== 'admin') return { ok: false, error: 'role_denied' };
  if (actor.user_id === targetUserId) return { ok: false, error: 'self_management_denied' };
  if (!mayManageTarget(actor.role, targetRole)) return { ok: false, error: 'target_role_denied' };
  if (actor.role === 'admin' && requestedPropertyIds.some((id) => !actor.property_ids.includes(id))) {
    return { ok: false, error: 'property_scope_denied' };
  }
  return { ok: true, error: null };
}
