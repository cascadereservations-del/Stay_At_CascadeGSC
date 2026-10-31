-- Rollback for s108_option_requests_20261111: drops the four RPCs, the three internal functions and the requests table.
-- Not undone: options added, edited or deleted through the RPCs (approved requests) stay as applied; open option_request follow-up tasks stay (close them by hand).
drop function if exists public.inventory_option_request_v1(uuid, text, uuid, jsonb, text, text);
drop function if exists public.inventory_option_requests_v1(uuid, text);
drop function if exists public.inventory_option_request_decide_v1(uuid, text, jsonb, text);
drop function if exists public.inventory_option_request_cancel_v1(uuid);
drop function if exists public.s_inventory_option_request_task_v1(uuid, uuid);
drop function if exists public.s_inventory_option_apply_v1(uuid, uuid, text, uuid, jsonb, uuid);
drop function if exists public.s_inventory_option_payload_v1(uuid, jsonb, boolean);
drop table if exists public.inventory_option_requests;
