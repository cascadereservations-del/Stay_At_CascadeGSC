-- Session 49: release client_errors_20260925 (D-240). One row per distinct error, one alert a day, service_role only.
begin;
select plan(9);
delete from public.client_errors where fingerprint like 'synthetic%';

select is(public.record_client_error_v1('synthetic-fp-0001', 'checklist', 'http', 'submit-cleaning 400 invalid_photo_scope', '{"status":400}', true)->>'alert', 'true',
  'a new error alerts');
select is(public.record_client_error_v1('synthetic-fp-0001', 'checklist', 'http', 'submit-cleaning 400 invalid_photo_scope', '{"status":400}', true)->>'alert', 'false',
  'the same error again inside a day does not');
select is((select count from public.client_errors where fingerprint = 'synthetic-fp-0001'), 2, 'but it is counted');
update public.client_errors set last_alerted_at = now() - interval '25 hours' where fingerprint = 'synthetic-fp-0001';
select is(public.record_client_error_v1('synthetic-fp-0001', 'checklist', 'http', 'x', '{}', true)->>'alert', 'true',
  'still happening a day later: one more alert');
select is(public.record_client_error_v1('synthetic-fp-0002', 'booking_site', 'http', 'submit-booking 409 dates_unavailable', '{}', false)->>'alert', 'false',
  'an expected refusal is recorded without an alert');
select is((select count(*) from public.client_errors where fingerprint = 'synthetic-fp-0002'), 1::bigint, 'and it is recorded');
select throws_ok($$select public.record_client_error_v1('synthetic-fp-0003', 'somewhere_else', 'http', 'x', '{}', true)$$, '23514', null,
  'only the two apps are accepted');
select ok(has_function_privilege('service_role', 'public.record_client_error_v1(text, text, text, text, jsonb, boolean)', 'execute')
      and not has_function_privilege('anon', 'public.record_client_error_v1(text, text, text, text, jsonb, boolean)', 'execute')
      and not has_function_privilege('authenticated', 'public.record_client_error_v1(text, text, text, text, jsonb, boolean)', 'execute'),
  'only the client-error function writes');
select ok(not has_table_privilege('anon', 'public.client_errors', 'select') and not has_table_privilege('authenticated', 'public.client_errors', 'insert'),
  'nobody writes the table directly, anon cannot read it');
select * from finish();
rollback;
