import type { StaffRole } from './logic.ts';

export type StaffManagementAction = 'upsert' | 'disable' | 'enable' | 'revoke_sessions';

export type StaffManagementRequest = {
  target_user_id: string;
  action: StaffManagementAction;
  role: StaffRole | null;
  property_ids: string[] | null;
  reason: string;
};

export type ParseResult =
  | { ok: true; value: StaffManagementRequest }
  | { ok: false; error: 'invalid_request' };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACTIONS = new Set<StaffManagementAction>(['upsert', 'disable', 'enable', 'revoke_sessions']);
const ROLES = new Set<StaffRole>(['owner', 'admin', 'finance', 'inspector', 'cleaner', 'maintenance']);

export function parseManagementRequest(input: unknown): ParseResult {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return { ok: false, error: 'invalid_request' };
  const value = input as Record<string, unknown>;
  const target = typeof value.target_user_id === 'string' ? value.target_user_id.trim() : '';
  const action = typeof value.action === 'string' ? value.action : '';
  const reason = typeof value.reason === 'string' ? value.reason.trim() : '';
  if (!UUID.test(target) || !ACTIONS.has(action as StaffManagementAction) || reason.length < 3 || reason.length > 500) {
    return { ok: false, error: 'invalid_request' };
  }

  if (action !== 'upsert') {
    return { ok: true, value: { target_user_id: target, action: action as StaffManagementAction, role: null, property_ids: null, reason } };
  }

  const role = typeof value.role === 'string' ? value.role : '';
  if (!ROLES.has(role as StaffRole) || !Array.isArray(value.property_ids) || value.property_ids.length > 20) {
    return { ok: false, error: 'invalid_request' };
  }
  const properties = [...new Set(value.property_ids.map((id) => typeof id === 'string' ? id.trim() : ''))];
  if (properties.some((id) => !UUID.test(id)) || (role !== 'owner' && properties.length === 0)) {
    return { ok: false, error: 'invalid_request' };
  }
  return {
    ok: true,
    value: {
      target_user_id: target,
      action: 'upsert',
      role: role as StaffRole,
      property_ids: properties,
      reason,
    },
  };
}
