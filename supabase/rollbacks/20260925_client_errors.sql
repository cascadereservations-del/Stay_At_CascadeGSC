-- Rollback for release client_errors_20260925: drops the function and the table (the reported errors go with it).
-- The client-error Edge Function then answers 500 to the pages, which ignore it.
begin;
drop function if exists public.record_client_error_v1(text, text, text, text, jsonb, boolean);
drop table if exists public.client_errors;
commit;
