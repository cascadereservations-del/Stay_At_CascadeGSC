begin;

select plan(18);

select ok(not has_table_privilege('anon', 'public.airbnb_reservations', 'select'), 'anon cannot read Airbnb reservations');
select ok(not has_table_privilege('authenticated', 'public.airbnb_reservations', 'select'), 'authenticated cannot read Airbnb reservations');
select ok(not has_table_privilege('anon', 'public.calendar_events', 'select'), 'anon cannot read calendar events');
select ok(not has_table_privilege('authenticated', 'public.calendar_events', 'select'), 'authenticated cannot read calendar events');
select ok(not has_table_privilege('anon', 'public.calendar_sync_log', 'select'), 'anon cannot read calendar sync logs');
select ok(not has_table_privilege('authenticated', 'public.calendar_sync_log', 'select'), 'authenticated cannot read calendar sync logs');
select ok(not has_table_privilege('anon', 'public.booking_inquiries', 'select'), 'anon cannot read booking inquiries');
select ok(not has_table_privilege('authenticated', 'public.booking_inquiries', 'select'), 'authenticated cannot read booking inquiries');

select ok(has_table_privilege('service_role', 'public.airbnb_reservations', 'select'), 'service role can read Airbnb reservations');
select ok(has_table_privilege('service_role', 'public.calendar_events', 'select'), 'service role can read calendar events');
select ok(has_table_privilege('service_role', 'public.calendar_sync_log', 'select'), 'service role can read calendar sync logs');
select ok(has_table_privilege('service_role', 'public.booking_inquiries', 'select'), 'service role can read booking inquiries');

select ok(not has_function_privilege('anon', 'public.get_guest_history(text, uuid)', 'execute'), 'anon cannot execute name-based guest history');
select ok(not has_function_privilege('authenticated', 'public.get_guest_history(text, uuid)', 'execute'), 'authenticated cannot execute name-based guest history');
select ok(not has_function_privilege('anon', 'public.log_returning_guest_alert(text, date, date, integer, integer, integer, date, date, uuid)', 'execute'), 'anon cannot trigger guest alert');
select ok(not has_function_privilege('authenticated', 'public.log_returning_guest_alert(text, date, date, integer, integer, integer, date, date, uuid)', 'execute'), 'authenticated cannot trigger guest alert');
select ok(has_function_privilege('service_role', 'public.get_guest_history(text, uuid)', 'execute'), 'service role can execute guest history');
select ok(has_function_privilege('service_role', 'public.log_returning_guest_alert(text, date, date, integer, integer, integer, date, date, uuid)', 'execute'), 'service role can execute guest alert');

select * from finish();

rollback;
