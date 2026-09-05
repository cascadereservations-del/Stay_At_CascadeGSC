# Wave 3 cleaning/meter local candidate — 2026-09-05

Wave 3 now has private, property-scoped cleaning and meter evidence with named review. Cleaner submissions are bound to the authenticated session owner; meter photos must reference the same session/property reading; content and object paths are stored as hashes. Deterministic or model-derived results remain advisory. Inspectors may accept, request correction, or require inspection; only an authorized operations manager may override. Reviews never rewrite meter facts or create Finance rows.

Validation passed: 2/2 Node boundary tests and 21/21 rollback-only pgTAP assertions. No production change, provider call, or workflow activation occurred.
