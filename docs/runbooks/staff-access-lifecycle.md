# Staff access lifecycle

Create one named Supabase Auth account per person. Assign a `staff_access_profiles` record with the least-privilege role and property scope. Do not issue shared permanent PINs or shared logins.

Owner, admin and finance users must enroll MFA before any production payment or staff-management action is enabled. Disable a departing staff member immediately, revoke sessions, record the reason in `staff_access_audit`, and rotate any external credential they could access.

## Deployment gate

Do not deploy `20260828000200_operational_rls_lockdown.sql`,
`20260828000400_staff_roles_and_sessions.sql`,
`20260828000500_db_backed_operational_authorization.sql`, or the `staff-access`
Edge Function in isolation. Production activation requires all of the following
in one reviewed cutover:

1. Apply the three migrations in version order. The final migration replaces
   JWT-claim-only operational policies with database-owned role, property,
   disabled-account and session-revocation checks.
2. Replace every privileged dashboard and Edge Function check with `current_staff_authorized(action, property_id)` or the guarded `manage_staff_access` RPC. A Supabase session by itself is not authorization.
3. Move cleaner submissions and uploads to named, property-scoped accounts; the current shared-code compatibility path must be removed or explicitly time-boxed.
4. Configure the `staff-access` deployment with platform JWT verification enabled. It uses the anon key plus the caller's bearer token and must never receive the service-role key.
5. Run the pgTAP staff-access and operational RLS suites plus the static security tests against the release candidate. The local Docker baseline on 2026-08-29 passed 21 staff tests and 24 operational RLS tests, including poisoned JWT claims and immediate disabled-user loss of access.
6. Bootstrap the first owner from a database-owner session, then enroll that account in MFA and issue a fresh session before staff management.

The one-time bootstrap is intentionally unavailable to `anon`, `authenticated`, and `service_role`:

```sql
select public.bootstrap_cascade_owner(
  '<existing-auth-user-uuid>'::uuid,
  array['<cascade-property-uuid>'::uuid],
  'Initial named Cascade owner'
);
```

Never paste real identifiers or credentials into this repository. Resolve them at deployment time from the approved Supabase project.

## Offboarding and role changes

Use `staff-access` with action `disable`, `revoke_sessions`, `enable`, or `upsert`; do not edit role tables from a browser client. The RPC derives the actor from `auth.uid()` and the verified JWT, requires AAL2 for management, prevents self-management, limits administrators to their property scope, updates immutable app metadata, and writes an append-only audit event in the same database transaction.

`sessions_revoked_after` is the authoritative Cascade gate. A role change or revocation makes older JWTs fail wherever `current_staff_authorized` is used. It does not by itself delete Supabase refresh tokens, so production remains blocked until every critical path uses the gate; after cutover, the operator should also use the supported Supabase Auth session-termination control and verify the former account cannot refresh or call a privileged path.

For a departing staff member:

1. Disable the named profile with a specific reason.
2. End the user's Auth sessions through the supported Supabase administration control.
3. Rotate external credentials the user could access, including any n8n credential if separation was not enforced.
4. Confirm a stale token receives `staff_access_denied` on a privileged path.
5. Review the audit row and record the verification in the change ticket.
