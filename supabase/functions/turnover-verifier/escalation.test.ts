import { assertEquals } from 'jsr:@std/assert@1';
import { escalationStep, onlyMissingReport } from './escalation.ts';

Deno.test('a late report resolves the turnover, escalated or not', () => {
  assertEquals(escalationStep(true, false), 'resolve');
  assertEquals(escalationStep(true, true), 'resolve');
});

Deno.test('no report: escalate once, then it is a task and never a second message', () => {
  assertEquals(escalationStep(false, false), 'escalate');
  assertEquals(escalationStep(false, true), 'task');
});

Deno.test('SPEC-29: a missing report alone is missed-cleaning-alert job; any other issue still speaks', () => {
  assertEquals(onlyMissingReport(['no_session_found']), true);
  assertEquals(onlyMissingReport(['no_session_found', 'photos_missing']), false);
  assertEquals(onlyMissingReport(['photos_missing']), false);
  assertEquals(onlyMissingReport([]), false);
  assertEquals(onlyMissingReport(null), false);
});
