// deno test supabase/functions/telegram-expense/notice-args.test.ts - SPEC-41: the /brownout parser and the blocked-date Brownout follow-up.
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { feederFor, parseBrownoutReply, parseNoticeArgs, resolveDateOn } from './notice-args.ts';

const TODAY = '2026-10-05';

Deno.test('SPEC-41: the Brownout answer "10-11 8am 8h NGCP" is date 2026-10-11, 08:00, 8 h, feeder NGCP grid, source ngcp', () => {
  assertEquals(parseBrownoutReply('10-11 8am 8h NGCP', TODAY), {
    effectiveDate: '2026-10-11', effectiveTime: '08:00:00', durationHours: 8, title: 'NGCP', feeder: 'NGCP grid', source: 'ngcp',
  });
  assertEquals(parseBrownoutReply('10-11 8 am 8h NGCP grid interruption', TODAY)?.title, 'NGCP grid interruption', '"8 am" is joined');
  assertEquals(parseBrownoutReply('tomorrow 13:00 2 SOCOTECO maintenance', TODAY)?.effectiveDate, '2026-10-06');
});

Deno.test('SPEC-41: a plain /brownout ... SOCOTECO keeps Feeder 14-3; a title with no provider is a staff notice on Feeder 14-3 as before', () => {
  const s = parseBrownoutReply('10-15 6am 11h SOCOTECO substation maintenance', TODAY)!;
  assertEquals([s.feeder, s.source], ['Feeder 14-3', 'socoteco']);
  const w = parseBrownoutReply('10-15 8am 4h Water tank cleaning', TODAY)!;
  assertEquals([w.feeder, w.source], ['Feeder 14-3', 'staff']);
  assertEquals(feederFor('ngcp line trip'), 'NGCP grid');
  assertEquals(feederFor('NGCPX'), 'Feeder 14-3', 'a whole word only');
});

Deno.test('SPEC-41: a reply that names no day, or says nobody announced it, is not an answer (the question stays open)', () => {
  assertEquals(parseBrownoutReply('8am 8h NGCP', TODAY), null, 'no day: it would silently become a notice for today');
  assertEquals(parseBrownoutReply('10-11 8am 8h', TODAY), null, 'no title');
  assertEquals(parseBrownoutReply('   ', TODAY), null);
  assertEquals(parseBrownoutReply('not sure', TODAY), null);
});

Deno.test('the /brownout parser reads what it read before the move (index.ts handleOpsNoticeCommand)', () => {
  assertEquals(parseNoticeArgs('brownout', ['tomorrow', '8am', '4h', 'SOCOTECO', 'maintenance'], TODAY),
    { effectiveDate: '2026-10-06', effectiveTime: '08:00:00', durationHours: 4, title: 'SOCOTECO maintenance', dateGiven: true });
  assertEquals(parseNoticeArgs('brownout', ['SOCOTECO'], TODAY).effectiveDate, TODAY, 'no date: today, as the command always did');
  assertEquals(parseNoticeArgs('holiday', ['06-12', 'Independence', 'Day'], TODAY),
    { effectiveDate: '2026-06-12', effectiveTime: null, durationHours: null, title: 'Independence Day', dateGiven: true }, 'time and hours are brownout-only');
  assertEquals(parseNoticeArgs('brownout', ['2026-10-11', '14:30', '1.5h', 'x'], TODAY).durationHours, 1.5);
  assertEquals(parseNoticeArgs('brownout', ['today', '25:00', 'x'], TODAY).effectiveTime, null, 'not a time');
  assertEquals(resolveDateOn('yesterday', TODAY), '2026-10-04');
  assertEquals(resolveDateOn(undefined, TODAY), TODAY);
});
