import {
  NotificationRouteError,
  assertRoutePayloadSafe,
  createNotification,
} from './notifications.ts';

function equal(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`);
}

function includes(value: string, expected: string, message: string): void {
  if (!value.includes(expected)) throw new Error(`${message}: ${value}`);
}

function rejects(action: () => unknown, reason: string): void {
  try {
    action();
  } catch (error) {
    if (error instanceof NotificationRouteError && error.reason === reason) return;
    throw error;
  }
  throw new Error(`Expected NotificationRouteError(${reason})`);
}

Deno.test('renders a safe OPS arrival advisory from a closed template', () => {
  const notification = createNotification({
    route: 'ops',
    template: 'ops.arrival_advisory',
    fields: {
      booking_ref: 'ABC12345',
      unit_name: 'Cascade Hideaway',
      guest_name: 'Test Guest',
      checkin_date: '2026-09-01',
      checkout_date: '2026-09-03',
      pax: 2,
    },
  });

  equal(notification.route, 'ops', 'route');
  includes(notification.text, 'ABC12345', 'booking reference is rendered');
  includes(notification.text, '2026-09-01', 'check-in is rendered');
});

Deno.test('rejects nested financial keys on OPS payloads', () => {
  rejects(
    () => assertRoutePayloadSafe('ops', { metadata: { settlement: { amount: 1780, currency: 'PHP' } } }),
    'ops_financial_field',
  );
});

Deno.test('rejects financial detail hidden in OPS free text', () => {
  rejects(
    () => assertRoutePayloadSafe('ops', { notes: 'guest paid PHP 1780 through the bank' }),
    'ops_financial_text',
  );
});

Deno.test('rejects arbitrary prose and unknown fields from closed OPS templates', () => {
  rejects(
    () => createNotification({
      route: 'ops',
      template: 'ops.arrival_advisory',
      fields: {
        booking_ref: 'ABC12345',
        unit_name: 'Cascade Hideaway',
        guest_name: 'Test Guest',
        checkin_date: '2026-09-01',
        checkout_date: '2026-09-03',
        pax: 2,
        message: 'AI generated arbitrary content',
      },
    }),
    'unknown_template_field',
  );
});

Deno.test('Finance template may render reviewed payment amounts', () => {
  const notification = createNotification({
    route: 'finance',
    template: 'finance.payment_review',
    fields: {
      booking_ref: 'ABC12345',
      expected_amount: 1780,
      currency: 'PHP',
      match_status: 'partial_match',
    },
  });

  includes(notification.text, 'PHP 1,780.00', 'review amount is rendered');
  includes(notification.text, 'partial_match', 'match status is rendered');
});

Deno.test('OPS rendered text is checked after interpolation', () => {
  rejects(
    () => createNotification({
      route: 'ops',
      template: 'ops.arrival_advisory',
      fields: {
        booking_ref: 'ABC12345',
        unit_name: 'Cascade Hideaway',
        guest_name: 'Guest paid PHP 1780',
        checkin_date: '2026-09-01',
        checkout_date: '2026-09-03',
        pax: 2,
      },
    }),
    'ops_financial_text',
  );
});
