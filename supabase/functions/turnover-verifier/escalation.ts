// D-218 (Lloyd 2026-09-23): a turnover escalation is said ONCE. It used to repeat every morning a guest
// was due, for as long as turnover_verification.resolved_at stayed empty - and nothing ever wrote it, so a
// report filed a day late (14, 17 and 18 Sep) kept escalating forever.
export type EscalationStep = 'resolve' | 'escalate' | 'task';

/** What pass 2 does with one still-open turnover: a cleaning report now on file resolves it; otherwise the
 *  first time it is escalated to OPS, and every later day it lives as one Follow-ups task, never a message. */
export function escalationStep(reportNowOnFile: boolean, alreadyEscalated: boolean): EscalationStep {
  if (reportNowOnFile) return 'resolve';
  return alreadyEscalated ? 'task' : 'escalate';
}
