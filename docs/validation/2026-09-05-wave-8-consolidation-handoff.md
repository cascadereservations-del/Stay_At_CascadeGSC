# Wave 8 consolidation and operational handoff — 2026-09-05

Status: local candidate verified. Production and infrastructure remain unchanged.

The machine-checkable authority inventory maps eight completed business domains to one canonical Supabase decision boundary each, with property scope, named-human authority, advisory inputs, prohibited effects, source, and validation evidence. Legacy consent columns, the private booking engine overload, and the inactive automation outbox are explicitly classified so they cannot be mistaken for competing authority.

The operating handoff covers named decisions, access review, recovery and incident drills, evidence handling, production stops, and the gated Hetzner transition. ADR-002 accepts a dedicated Hetzner automation plane as the future direction while keeping Supabase canonical and the current live state unchanged. The existing two-service Compose candidate rendered successfully with its example environment; no container was started by that render.

Disposable recovery evidence:

- n8n 2.34.6 imported and re-exported all 13 source workflows inactive with matching semantic hash prefix `d3077384d1bc`; no persistent container was started.
- Supabase CLI 2.116.0 rebuilt an isolated `cascade-recovery-*` project, applied 38 migrations through `20260905090000`, ran 26 database test files, verified the active local database identity was unchanged, used no production connection, and cleaned up the disposable project.

Validation passed: 6/6 consolidation checks, 6/6 handoff/status checks, 36/36 content and link checks, 37/37 platform-safety checks, 13/13 inactive workflow checks, the secret scan, and the whitespace check. The production backup/restore, real Auth/staff smoke, monitoring, shared-runtime recovery, and Hetzner preflight gates remain open.
