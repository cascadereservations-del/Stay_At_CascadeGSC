import { assertEquals } from 'jsr:@std/assert@1';
import { escalationStep } from './escalation.ts';

Deno.test('a late report resolves the turnover, escalated or not', () => {
  assertEquals(escalationStep(true, false), 'resolve');
  assertEquals(escalationStep(true, true), 'resolve');
});

Deno.test('no report: escalate once, then it is a task and never a second message', () => {
  assertEquals(escalationStep(false, false), 'escalate');
  assertEquals(escalationStep(false, true), 'task');
});
