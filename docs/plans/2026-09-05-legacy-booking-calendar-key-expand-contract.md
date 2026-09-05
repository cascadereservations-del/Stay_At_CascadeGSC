# Legacy booking/calendar key expand-contract release

Module E keeps `booking_inquiries.id` and `calendar_events.id` as logical references because the deployed legacy schema cannot yet prove that either column is a usable primary or unique key in every environment. The lifecycle release must not add opportunistic foreign keys or rewrite those identifiers.

The separate foundational release follows this order:

1. Inventory duplicates, nulls, dependent views, RPCs, triggers, policies, and foreign-key candidates in a production read-only report.
2. Add non-blocking unique indexes where the inventory proves they are safe. Stop if any duplicate or null exists; preserve the evidence and repair rows through a reviewed data-change plan.
3. Add new foreign keys from lifecycle tables as `NOT VALID`, verify application compatibility, then validate each constraint separately.
4. Update RPCs to rely on the validated keys while accepting the existing identifiers throughout the compatibility window.
5. Remove logical-reference comments and temporary compatibility checks only after backup/restore proof and rollback rehearsal pass.

Rollback drops only unvalidated constraints and newly added indexes. It never changes booking, calendar, payment, or audit rows. Production execution requires the Module A backup/restore and coordinated-access gates plus owner approval.
