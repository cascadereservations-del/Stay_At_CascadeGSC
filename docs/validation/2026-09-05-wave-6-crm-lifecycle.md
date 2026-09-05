# Wave 6 CRM, consent, retention, and guest lifecycle — 2026-09-05

Status: local candidate verified. Not deployed.

Private CRM profiles link canonical guests through property-scoped SHA-256 identity keys; raw email and phone are not duplicated. Exact hashes resolve deterministically and conflicting guest linkage fails closed. Named AAL2 owner/admin staff record append-only, purpose-specific consent, hashed preferences, stay events, service recovery, and retention decisions.

Operational and service-recovery consent never imply marketing permission. Deterministic marketing eligibility requires the latest marketing consent to be granted, no open service recovery, and no restrict, delete-due, or legal-hold decision. Eligibility does not authorize targeting, drafting, sending, or publication. Retention decisions record action due; no function deletes guest data automatically.

Validation passed: 5/5 source checks, 31/31 rollback-only pgTAP assertions, the compensating rollback in a disposable restored database, 37/37 platform-safety checks, 13/13 inactive workflow checks, the secret scan, and the whitespace check. No production or provider action occurred.
