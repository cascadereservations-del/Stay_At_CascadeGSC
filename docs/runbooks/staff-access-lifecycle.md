# Staff access lifecycle

Create one named Supabase Auth account per person. Assign a `staff_access_profiles` record with the least-privilege role and property scope. Do not issue shared permanent PINs or shared logins.

Owner, admin and finance users must enroll MFA before any production payment or staff-management action is enabled. Disable a departing staff member immediately, revoke sessions, record the reason in `staff_access_audit`, and rotate any external credential they could access.

This migration is not deployed until the staff-access Edge Function and cleaner compatibility path are complete; direct application of it does not authorize any role assignment or account creation.
