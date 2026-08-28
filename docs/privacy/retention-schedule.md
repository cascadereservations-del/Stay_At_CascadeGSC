# Cascade retention schedule

Retention starts only after the record is no longer operationally active. A legal, dispute, chargeback, safety, tax/accounting, or unresolved payment hold pauses disposal. Automated deletion is not enabled until the SOL-reviewed privacy migration and a reversible staging test exist.

| Record | Default period | Disposal approach |
|---|---:|---|
| Completed booking/guest identity | 5 years | Anonymize guest-facing identifiers while preserving non-identifying audit/ledger links. |
| Payment evidence and bank metadata | 5 years | Delete private receipt object after verified schedule; retain minimal audit reference only if required. |
| Cleaning photos/meter evidence | 2 years | Delete private objects and evidence metadata unless linked to an open incident. |
| Staff access/session audit | Employment + 2 years | Remove personal contact fields; preserve access-event audit only where required. |
| Telegram delivery log | 1 year | Delete message-related metadata; do not retain raw message bodies. |
| Analytics funnel events | 13 months | Aggregate or delete. |
| Security incident/dispute/legal hold | Until hold release + applicable period | Human release only, audited. |

No BIR/tax filing or statutory-retention assertion is made while Cascade is unregistered. Confirm periods with an accountant/privacy adviser before enforcement.
